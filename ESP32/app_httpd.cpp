#include <Arduino.h>
#include "esp_http_server.h"
#include "esp_timer.h"
#include "esp_camera.h"
#include "img_converters.h"
#include "esp32-hal-ledc.h"

// =======================
// MJPEG stream constants
// =======================
#define PART_BOUNDARY "123456789000000000000987654321"

static const char* STREAM_CONTENT_TYPE = "multipart/x-mixed-replace;boundary=" PART_BOUNDARY;
static const char* STREAM_BOUNDARY     = "\r\n--" PART_BOUNDARY "\r\n";
static const char* STREAM_PART         = "Content-Type: image/jpeg\r\nContent-Length: %u\r\n\r\n";

typedef struct {
  httpd_req_t* req;
  size_t len;
} jpg_chunking_t;

static httpd_handle_t camera_httpd = NULL;
static httpd_handle_t stream_httpd = NULL;

// =======================
// Optional flash LED
// =======================
static int g_flash_pin = -1;
static int g_led_duty = 0;
static bool g_streaming = false;

#define LED_LEDC_CHANNEL 2
#define LEDC_FREQ_HZ     5000
#define LEDC_RES_BITS    8

static void enableFlash(bool on) {
  if (g_flash_pin < 0) return;
  int duty = on ? g_led_duty : 0;
  ledcWrite(LED_LEDC_CHANNEL, duty);
}

// Call this from your .ino if you have a flash LED pin
void setupLedFlash(int pin, int intensity /*0..255*/) {
  g_flash_pin = pin;
  g_led_duty = constrain(intensity, 0, 255);

  ledcSetup(LED_LEDC_CHANNEL, LEDC_FREQ_HZ, LEDC_RES_BITS);
  ledcAttachPin(g_flash_pin, LED_LEDC_CHANNEL);

  enableFlash(false);
}

// =======================
// JPEG chunk writer
// =======================
static size_t jpg_encode_stream(void* arg, size_t index, const void* data, size_t len) {
  jpg_chunking_t* j = (jpg_chunking_t*)arg;
  if (!index) j->len = 0;

  if (httpd_resp_send_chunk(j->req, (const char*)data, len) != ESP_OK) return 0;

  j->len += len;
  return len;
}

// =======================
// /capture handler
// =======================
static esp_err_t capture_handler(httpd_req_t* req) {
  camera_fb_t* fb = NULL;
  esp_err_t res = ESP_OK;

  // (optional) flash for snapshot
  enableFlash(true);
  vTaskDelay(120 / portTICK_PERIOD_MS);

  fb = esp_camera_fb_get();

  enableFlash(false);

  if (!fb) {
    httpd_resp_send_500(req);
    return ESP_FAIL;
  }

  httpd_resp_set_type(req, "image/jpeg");
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");

  if (fb->format == PIXFORMAT_JPEG) {
    res = httpd_resp_send(req, (const char*)fb->buf, fb->len);
    esp_camera_fb_return(fb);
    return res;
  }

  // If not JPEG, convert to JPEG
  jpg_chunking_t jchunk = { req, 0 };
  bool ok = frame2jpg_cb(fb, 80, jpg_encode_stream, &jchunk);
  esp_camera_fb_return(fb);

  if (!ok) {
    httpd_resp_send_500(req);
    return ESP_FAIL;
  }

  // end chunks
  httpd_resp_send_chunk(req, NULL, 0);
  return ESP_OK;
}

// =======================
// /stream handler (MJPEG)
// =======================
static esp_err_t stream_handler(httpd_req_t* req) {
  esp_err_t res = httpd_resp_set_type(req, STREAM_CONTENT_TYPE);
  if (res != ESP_OK) return res;

  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");

  g_streaming = true;

  while (true) {
    camera_fb_t* fb = esp_camera_fb_get();
    if (!fb) {
      res = ESP_FAIL;
      break;
    }

    uint8_t* jpg_buf = NULL;
    size_t jpg_len = 0;

    if (fb->format == PIXFORMAT_JPEG) {
      jpg_buf = fb->buf;
      jpg_len = fb->len;
    } else {
      // Convert to jpeg
      bool ok = frame2jpg(fb, 80, &jpg_buf, &jpg_len);
      if (!ok) {
        esp_camera_fb_return(fb);
        res = ESP_FAIL;
        break;
      }
    }

    // boundary
    res = httpd_resp_send_chunk(req, STREAM_BOUNDARY, strlen(STREAM_BOUNDARY));
    if (res != ESP_OK) {
      if (fb->format != PIXFORMAT_JPEG && jpg_buf) free(jpg_buf);
      esp_camera_fb_return(fb);
      break;
    }

    // header
    char part[128];
    int hlen = snprintf(part, sizeof(part), STREAM_PART, (unsigned)jpg_len);
    res = httpd_resp_send_chunk(req, part, hlen);
    if (res != ESP_OK) {
      if (fb->format != PIXFORMAT_JPEG && jpg_buf) free(jpg_buf);
      esp_camera_fb_return(fb);
      break;
    }

    // jpeg data
    res = httpd_resp_send_chunk(req, (const char*)jpg_buf, jpg_len);
    if (fb->format != PIXFORMAT_JPEG && jpg_buf) {
      free(jpg_buf);
      jpg_buf = NULL;
    }
    esp_camera_fb_return(fb);

    if (res != ESP_OK) break;

    // small pacing so WiFi + Firebase don’t starve
    vTaskDelay(1);
  }

  g_streaming = false;
  return res;
}

// =======================
// startCameraServer()
// =======================
void startCameraServer() {
  // Server on port 80: /capture
  httpd_config_t config = HTTPD_DEFAULT_CONFIG();
  config.server_port = 80;
  config.max_uri_handlers = 8;

  httpd_uri_t capture_uri = {
    .uri = "/capture",
    .method = HTTP_GET,
    .handler = capture_handler,
    .user_ctx = NULL
  };

  if (httpd_start(&camera_httpd, &config) == ESP_OK) {
    httpd_register_uri_handler(camera_httpd, &capture_uri);
  }

  // Stream server on port 81: /stream
  httpd_config_t config_stream = HTTPD_DEFAULT_CONFIG();
  config_stream.server_port = 81;
  config_stream.ctrl_port = 32769; // must differ from port 80 server ctrl port
  config_stream.max_uri_handlers = 8;

  httpd_uri_t stream_uri = {
    .uri = "/stream",
    .method = HTTP_GET,
    .handler = stream_handler,
    .user_ctx = NULL
  };

  if (httpd_start(&stream_httpd, &config_stream) == ESP_OK) {
    httpd_register_uri_handler(stream_httpd, &stream_uri);
  }
}
