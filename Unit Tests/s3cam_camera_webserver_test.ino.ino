#include "esp_camera.h"
#include <WiFi.h>
#include "camera_pins.h"   // from the Freenove / Camera example

// -------------------- Wi-Fi settings --------------------
const char* ssid     = "Haneen's iphone";   // your hotspot / Wi-Fi
const char* password = "qqqqqqqq";          // its password

// Implemented in app_httpd.cpp from the Camera example:
void startCameraServer();

void printResetReason() {
  esp_reset_reason_t reason = esp_reset_reason();
  Serial.print("Reset reason: ");
  Serial.println((int)reason);
}

// -------------------- Camera init -----------------------
bool initCamera() {
  camera_config_t config;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer   = LEDC_TIMER_0;
  config.pin_d0       = Y2_GPIO_NUM;
  config.pin_d1       = Y3_GPIO_NUM;
  config.pin_d2       = Y4_GPIO_NUM;
  config.pin_d3       = Y5_GPIO_NUM;
  config.pin_d4       = Y6_GPIO_NUM;
  config.pin_d5       = Y7_GPIO_NUM;
  config.pin_d6       = Y8_GPIO_NUM;
  config.pin_d7       = Y9_GPIO_NUM;
  config.pin_xclk     = XCLK_GPIO_NUM;
  config.pin_pclk     = PCLK_GPIO_NUM;
  config.pin_vsync    = VSYNC_GPIO_NUM;
  config.pin_href     = HREF_GPIO_NUM;
  config.pin_sccb_sda = SIOD_GPIO_NUM;
  config.pin_sccb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn     = PWDN_GPIO_NUM;
  config.pin_reset    = RESET_GPIO_NUM;
  config.xclk_freq_hz = 20000000;
  config.pixel_format = PIXFORMAT_JPEG;

  if (psramFound()) {
    config.frame_size   = FRAMESIZE_VGA; // 640x480
    config.jpeg_quality = 10;
    config.fb_count     = 2;
  } else {
    config.frame_size   = FRAMESIZE_QVGA; // 320x240
    config.jpeg_quality = 12;
    config.fb_count     = 1;
  }

  Serial.println("Initializing camera...");
  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK) {
    Serial.printf("Camera init failed with error 0x%x\n", err);
    return false;
  }
  Serial.println("Camera init OK");
  return true;
}

// -------------------- Wi-Fi connect ---------------------
bool connectWiFi() {
  Serial.printf("Connecting to WiFi \"%s\"...\n", ssid);
  WiFi.mode(WIFI_STA);
  WiFi.begin(ssid, password);

  int retries = 0;
  while (WiFi.status() != WL_CONNECTED && retries < 30) {
    delay(500);
    Serial.print(".");
    retries++;
  }
  Serial.println();

  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("WiFi connection FAILED");
    return false;
  }

  Serial.print("WiFi connected. IP address: ");
  Serial.println(WiFi.localIP());
  return true;
}

// -------------------- setup / loop ----------------------
void setup() {
  Serial.begin(115200);
  Serial.setDebugOutput(true);
  Serial.println();
  Serial.println("===== ESP32-S3-CAM UNIT TEST =====");
  printResetReason();

  if (!initCamera()) {
    Serial.println("TEST RESULT: Camera init FAILED");
    return;
  }

  if (!connectWiFi()) {
    Serial.println("TEST RESULT: WiFi FAILED (check SSID/password or hotspot)");
    return;
  }

  Serial.println("Starting camera web server...");
  startCameraServer();

  Serial.print("TEST RESULT: OK. Open in browser: http://");
  Serial.println(WiFi.localIP());
}

void loop() {
  // Nothing here – HTTP server runs in background
  delay(1000);
}
