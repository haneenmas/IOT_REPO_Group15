#include <Arduino.h>
#include <strings.h>

#include "esp_http_server.h"
#include "esp_timer.h"
#include "esp_camera.h"
#include "img_converters.h"
#include "esp32-hal-ledc.h"

#include "FS.h"
#include "LittleFS.h"

#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <freertos/queue.h>

#include "driver/i2s.h"

// =======================
// MIC (INMP441) SETTINGS
// =======================
#define MIC_I2S_PORT     I2S_NUM_1
#define MIC_BCLK         39
#define MIC_WS           40
#define MIC_SD           38
#define MIC_SAMPLE_RATE  16000
#define AUDIO_FRAME_SAMPLES 320  // 20ms @ 16kHz

// ==========================
// SPEAKER (MAX98357A) PINS
// ==========================
#define SPK_I2S_PORT       I2S_NUM_0
#define SPK_BCLK           36
#define SPK_LRC            35
#define SPK_DOUT           37
#define SPK_SAMPLE_RATE    16000

// ========= Speaker streaming (Phone -> ESP32) =========
typedef struct { uint8_t* data; size_t len; } spk_chunk_t;
static QueueHandle_t spk_queue = NULL;
static volatile bool spk_ws_active = false;

static void spk_init_once() {
  static bool inited = false;
  if (inited) return;
  inited = true;

  i2s_config_t cfg = {};
  cfg.mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_TX);
  cfg.sample_rate = SPK_SAMPLE_RATE;
  cfg.bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT;
  cfg.channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT;     // stereo
  cfg.communication_format = I2S_COMM_FORMAT_STAND_I2S;
  cfg.intr_alloc_flags = ESP_INTR_FLAG_LEVEL1;
  cfg.dma_buf_count = 8;
  cfg.dma_buf_len = 256;
  cfg.use_apll = false;
  cfg.tx_desc_auto_clear = true;
  cfg.fixed_mclk = 0;

  i2s_pin_config_t pins = {};
  pins.bck_io_num = SPK_BCLK;
  pins.ws_io_num = SPK_LRC;
  pins.data_out_num = SPK_DOUT;
  pins.data_in_num = -1;

  esp_err_t a = i2s_driver_install(SPK_I2S_PORT, &cfg, 0, NULL);
  if (a != ESP_OK && a != ESP_ERR_INVALID_STATE) {
    Serial.print("[SPK] i2s_driver_install failed: "); Serial.println((int)a);
  }

  esp_err_t b = i2s_set_pin(SPK_I2S_PORT, &pins);
  if (b != ESP_OK) {
    Serial.print("[SPK] i2s_set_pin failed: "); Serial.println((int)b);
  }

  i2s_set_clk(SPK_I2S_PORT, SPK_SAMPLE_RATE, I2S_BITS_PER_SAMPLE_16BIT, I2S_CHANNEL_STEREO);
  i2s_zero_dma_buffer(SPK_I2S_PORT);

  Serial.println("[SPK] init done");
}

static void spk_task(void* arg) {
  (void)arg;
  spk_init_once();

  for (;;) {
    spk_chunk_t c{};
    if (xQueueReceive(spk_queue, &c, 200 / portTICK_PERIOD_MS) != pdTRUE) {
      continue;
    }

    if (!spk_ws_active) {
      if (c.data) free(c.data);
      continue;
    }

    const int16_t* in = (const int16_t*)c.data;
    int samples = (int)(c.len / sizeof(int16_t));
    if (samples <= 0) { if (c.data) free(c.data); continue; }
    if (samples > 1024) samples = 1024;

    static int16_t out[2048];
    int outIdx = 0;
    for (int i = 0; i < samples; i++) {
      int16_t s = in[i];
      out[outIdx++] = s;
      out[outIdx++] = s;
    }

    size_t written = 0;
    i2s_write(SPK_I2S_PORT, (const char*)out, outIdx * sizeof(int16_t), &written, portMAX_DELAY);

    free(c.data);
  }
}

static esp_err_t ws_spk_handler(httpd_req_t* req) {
  if (req->method == HTTP_GET) {
    Serial.println("[SPK] ws client connected");
    spk_init_once();
    i2s_zero_dma_buffer(SPK_I2S_PORT);
    spk_ws_active = true;
    return ESP_OK;
  }

  httpd_ws_frame_t frame = {};
  frame.type = HTTPD_WS_TYPE_BINARY;

  esp_err_t ret = httpd_ws_recv_frame(req, &frame, 0);
  if (ret != ESP_OK) return ret;
  if (frame.len == 0) return ESP_OK;

  uint8_t* buf = (uint8_t*)malloc(frame.len);
  if (!buf) return ESP_FAIL;

  frame.payload = buf;
  ret = httpd_ws_recv_frame(req, &frame, frame.len);
  if (ret != ESP_OK) { free(buf); return ret; }

  spk_chunk_t c{ .data = buf, .len = frame.len };
  if (xQueueSend(spk_queue, &c, 0) != pdTRUE) {
    free(buf);
  }
  return ESP_OK;
}

// ======================= Camera stream helpers =======================
#define PART_BOUNDARY "123456789000000000000987654321"
static const char* STREAM_CONTENT_TYPE = "multipart/x-mixed-replace;boundary=" PART_BOUNDARY;
static const char* STREAM_BOUNDARY     = "\r\n--" PART_BOUNDARY "\r\n";
static const char* STREAM_PART         = "Content-Type: image/jpeg\r\nContent-Length: %u\r\n\r\n";

typedef struct { httpd_req_t* req; size_t len; } jpg_chunking_t;
static httpd_handle_t camera_httpd = NULL;
static httpd_handle_t stream_httpd = NULL;

// Optional flash LED
static int g_flash_pin = -1;
static int g_led_duty = 0;
#define LED_LEDC_CHANNEL 2
#define LEDC_FREQ_HZ     5000
#define LEDC_RES_BITS    8

static void enableFlash(bool on) {
  if (g_flash_pin < 0) return;
  ledcWrite(LED_LEDC_CHANNEL, on ? g_led_duty : 0);
}
void setupLedFlash(int pin, int intensity /*0..255*/) {
  g_flash_pin = pin;
  g_led_duty = constrain(intensity, 0, 255);
  ledcSetup(LED_LEDC_CHANNEL, LEDC_FREQ_HZ, LEDC_RES_BITS);
  ledcAttachPin(g_flash_pin, LED_LEDC_CHANNEL);
  enableFlash(false);
}

// ======================= MIC I2S init =======================
static bool g_mic_ready = false;
static void mic_init_once() {
  if (g_mic_ready) return;

  i2s_driver_uninstall(MIC_I2S_PORT);

  i2s_config_t cfg = {
    .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
    .sample_rate = MIC_SAMPLE_RATE,
    .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
    .channel_format = I2S_CHANNEL_FMT_ONLY_LEFT,
    .communication_format = I2S_COMM_FORMAT_STAND_I2S,
    .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
    .dma_buf_count = 12,
    .dma_buf_len = 240,
    .use_apll = true,
    .tx_desc_auto_clear = false,
    .fixed_mclk = 0
  };

  i2s_pin_config_t pins = {
    .bck_io_num = MIC_BCLK,
    .ws_io_num = MIC_WS,
    .data_out_num = -1,
    .data_in_num = MIC_SD
  };

  esp_err_t a = i2s_driver_install(MIC_I2S_PORT, &cfg, 0, NULL);
  esp_err_t b = i2s_set_pin(MIC_I2S_PORT, &pins);
  i2s_zero_dma_buffer(MIC_I2S_PORT);

  Serial.print("[AUDIO] mic init install="); Serial.print((int)a);
  Serial.print(" set_pin="); Serial.println((int)b);

  g_mic_ready = (a == ESP_OK && b == ESP_OK);
}

// ======================= LittleFS file handler =======================
static const char* content_type_from_path(const char* path) {
  const char* ext = strrchr(path, '.');
  if (!ext) return "text/plain";
  if (!strcasecmp(ext, ".html")) return "text/html";
  if (!strcasecmp(ext, ".js"))   return "application/javascript";
  if (!strcasecmp(ext, ".css"))  return "text/css";
  if (!strcasecmp(ext, ".png"))  return "image/png";
  if (!strcasecmp(ext, ".jpg") || !strcasecmp(ext, ".jpeg")) return "image/jpeg";
  if (!strcasecmp(ext, ".svg"))  return "image/svg+xml";
  return "application/octet-stream";
}

static esp_err_t file_get_handler(httpd_req_t *req) {
  const char* path = (const char*)req->user_ctx;
  File f = LittleFS.open(path, "r");
  if (!f) { httpd_resp_send_err(req, HTTPD_404_NOT_FOUND, "File not found"); return ESP_FAIL; }

  httpd_resp_set_type(req, content_type_from_path(path));
  httpd_resp_set_hdr(req, "Cache-Control", "no-store");

  char buf[1024];
  while (f.available()) {
    size_t n = f.readBytes(buf, sizeof(buf));
    if (n == 0) break;
    if (httpd_resp_send_chunk(req, buf, n) != ESP_OK) { f.close(); httpd_resp_sendstr_chunk(req, NULL); return ESP_FAIL; }
  }
  f.close();
  httpd_resp_send_chunk(req, NULL, 0);
  return ESP_OK;
}

// ======================= Camera stream handler =======================
static esp_err_t stream_handler(httpd_req_t* req) {
  esp_err_t res = httpd_resp_set_type(req, STREAM_CONTENT_TYPE);
  if (res != ESP_OK) return res;
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");

  while (true) {
    camera_fb_t* fb = esp_camera_fb_get();
    if (!fb) return ESP_FAIL;

    uint8_t* jpg_buf = NULL;
    size_t jpg_len = 0;

    if (fb->format == PIXFORMAT_JPEG) {
      jpg_buf = fb->buf; jpg_len = fb->len;
    } else {
      bool ok = frame2jpg(fb, 80, &jpg_buf, &jpg_len);
      if (!ok) { esp_camera_fb_return(fb); return ESP_FAIL; }
    }

    res = httpd_resp_send_chunk(req, STREAM_BOUNDARY, strlen(STREAM_BOUNDARY));
    if (res != ESP_OK) { if (fb->format != PIXFORMAT_JPEG && jpg_buf) free(jpg_buf); esp_camera_fb_return(fb); break; }

    char part[128];
    int hlen = snprintf(part, sizeof(part), STREAM_PART, (unsigned)jpg_len);
    res = httpd_resp_send_chunk(req, part, hlen);
    if (res != ESP_OK) { if (fb->format != PIXFORMAT_JPEG && jpg_buf) free(jpg_buf); esp_camera_fb_return(fb); break; }

    res = httpd_resp_send_chunk(req, (const char*)jpg_buf, jpg_len);
    if (fb->format != PIXFORMAT_JPEG && jpg_buf) free(jpg_buf);
    esp_camera_fb_return(fb);

    if (res != ESP_OK) break;
    vTaskDelay(1);
  }
  return res;
}

// ======================= WebSocket audio (ESP32 mic -> phone) =======================
typedef struct { httpd_handle_t hd; int fd; } ws_audio_client_t;

static void ws_audio_task(void* arg) {
  ws_audio_client_t* c = (ws_audio_client_t*)arg;

  mic_init_once();
  if (!g_mic_ready) { Serial.println("[AUDIO] mic not ready; closing ws"); free(c); vTaskDelete(NULL); return; }

  int32_t raw[AUDIO_FRAME_SAMPLES];
  int16_t pcm[AUDIO_FRAME_SAMPLES];

  while (true) {
    size_t bytesRead = 0;
    esp_err_t r = i2s_read(MIC_I2S_PORT, raw, sizeof(raw), &bytesRead, portMAX_DELAY);
    if (r != ESP_OK || bytesRead == 0) { Serial.println("[AUDIO] i2s_read failed"); break; }

    int n = (int)(bytesRead / 4);
    if (n > AUDIO_FRAME_SAMPLES) n = AUDIO_FRAME_SAMPLES;

    for (int i = 0; i < n; i++) {
      int32_t x = raw[i] >> 14;
      if (x > 15000) x = 15000;
      if (x < -15000) x = -15000;
      pcm[i] = (int16_t)x;
    }

    httpd_ws_frame_t frame = {};
    frame.type = HTTPD_WS_TYPE_BINARY;
    frame.payload = (uint8_t*)pcm;
    frame.len = n * sizeof(int16_t);

    esp_err_t sendr = httpd_ws_send_frame_async(c->hd, c->fd, &frame);
    if (sendr != ESP_OK) { Serial.println("[AUDIO] ws send failed"); break; }

    vTaskDelay(1);
  }

  free(c);
  vTaskDelete(NULL);
}

static esp_err_t ws_audio_handler(httpd_req_t* req) {
  if (req->method == HTTP_GET) {
    Serial.println("[AUDIO] ws client connected");
    ws_audio_client_t* c = (ws_audio_client_t*)malloc(sizeof(ws_audio_client_t));
    if (!c) return ESP_FAIL;
    c->hd = req->handle;
    c->fd = httpd_req_to_sockfd(req);
    xTaskCreatePinnedToCore(ws_audio_task, "ws_audio", 4096, c, 2, NULL, 1);
    return ESP_OK;
  }
  httpd_ws_frame_t frame = {};
  frame.type = HTTPD_WS_TYPE_TEXT;
  esp_err_t ret = httpd_ws_recv_frame(req, &frame, 0);
  if (ret != ESP_OK) return ret;
  if (frame.len) {
    uint8_t* buf = (uint8_t*)malloc(frame.len + 1);
    if (!buf) return ESP_FAIL;
    frame.payload = buf;
    ret = httpd_ws_recv_frame(req, &frame, frame.len);
    free(buf);
  }
  return ret;
}

// ======================= startCameraServer =======================
void startCameraServer() {
  httpd_config_t config = HTTPD_DEFAULT_CONFIG();
  config.server_port = 80;

  // you may have your own handlers on port 80; keep minimal here
  if (httpd_start(&camera_httpd, &config) == ESP_OK) {
    // no handlers needed on port 80 for this feature
  }

  httpd_config_t config_stream = HTTPD_DEFAULT_CONFIG();
  config_stream.server_port = 81;
  config_stream.ctrl_port = 32769;
  // IMPORTANT: increase handlers so ws_speak registration never fails silently
  config_stream.max_uri_handlers = 24;

  httpd_uri_t stream_uri = { .uri="/stream", .method=HTTP_GET, .handler=stream_handler, .user_ctx=NULL };

  if (httpd_start(&stream_httpd, &config_stream) == ESP_OK) {
    esp_err_t r;

    r = httpd_register_uri_handler(stream_httpd, &stream_uri);
    Serial.print("[HTTP] register /stream: "); Serial.println((int)r);

    // Existing talk page (ESP32 mic -> phone)
    httpd_uri_t talk_html_uri = { .uri="/talk.html", .method=HTTP_GET, .handler=file_get_handler, .user_ctx=(void*)"/talk.html" };
    httpd_uri_t talk_uri      = { .uri="/talk",      .method=HTTP_GET, .handler=file_get_handler, .user_ctx=(void*)"/talk.html" };
    httpd_uri_t root_uri      = { .uri="/",          .method=HTTP_GET, .handler=file_get_handler, .user_ctx=(void*)"/talk.html" };
    httpd_uri_t ws_audio_uri  = { .uri="/ws_audio",  .method=HTTP_GET, .handler=ws_audio_handler, .user_ctx=NULL, .is_websocket=true };

    Serial.print("[HTTP] register /talk.html: "); Serial.println((int)httpd_register_uri_handler(stream_httpd, &talk_html_uri));
    Serial.print("[HTTP] register /talk: ");      Serial.println((int)httpd_register_uri_handler(stream_httpd, &talk_uri));
    Serial.print("[HTTP] register /: ");         Serial.println((int)httpd_register_uri_handler(stream_httpd, &root_uri));
    Serial.print("[HTTP] register /ws_audio: "); Serial.println((int)httpd_register_uri_handler(stream_httpd, &ws_audio_uri));

    // NEW speak (phone -> ESP32 speaker)
    if (!spk_queue) {
      spk_queue = xQueueCreate(16, sizeof(spk_chunk_t));
      if (spk_queue) {
        xTaskCreatePinnedToCore(spk_task, "spk_task", 4096, NULL, 2, NULL, 1);
      } else {
        Serial.println("[SPK] failed to create queue");
      }
    }

    httpd_uri_t speak_html_uri = { .uri="/speak.html", .method=HTTP_GET, .handler=file_get_handler, .user_ctx=(void*)"/speak.html" };
    httpd_uri_t speak_uri      = { .uri="/speak",      .method=HTTP_GET, .handler=file_get_handler, .user_ctx=(void*)"/speak.html" };
    httpd_uri_t ws_speak_uri   = { .uri="/ws_speak",   .method=HTTP_GET, .handler=ws_spk_handler,  .user_ctx=NULL, .is_websocket=true };

    Serial.print("[HTTP] register /speak.html: "); Serial.println((int)httpd_register_uri_handler(stream_httpd, &speak_html_uri));
    Serial.print("[HTTP] register /speak: ");      Serial.println((int)httpd_register_uri_handler(stream_httpd, &speak_uri));
    Serial.print("[HTTP] register /ws_speak: ");   Serial.println((int)httpd_register_uri_handler(stream_httpd, &ws_speak_uri));

    mic_init_once();
  } else {
    Serial.println("[HTTP] failed to start stream_httpd");
  }
}
