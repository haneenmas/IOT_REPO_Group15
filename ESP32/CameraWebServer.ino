#include "esp_camera.h"
#include <WiFi.h>

#include <Firebase_ESP_Client.h>
#include <Keypad.h>
#include "addons/TokenHelper.h"
#include "addons/RTDBHelper.h"
#include "mbedtls/base64.h"

#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <freertos/queue.h>
#include <freertos/semphr.h>

// ===================
// Select camera model
// ===================
#define CAMERA_MODEL_ESP32S3_EYE
#include "camera_pins.h"

// ===========================
// WiFi credentials
// ===========================
const char* ssid = "HOTBOX-7F46";
const char* password = "wifiwifi";

// ===========================
// Firebase credentials
// ===========================
#define API_KEY "AIzaSyAZZFAOF2lEXONTwvi1iNaMZvJiPETzlpE"
#define DATABASE_URL "iot15-46c28-default-rtdb.firebaseio.com"

// ===========================
// Keypad setup
// ===========================
#define ROWS 3
#define COLS 4
char keys[ROWS][COLS] = {
  {'9','6','3','#'},
  {'8','5','2','0'},
  {'7','4','1','*'},
};

byte rowPins[ROWS] = {1, 2, 3};
byte colPins[COLS] = {21, 47, 48, 14};
Keypad keypad = Keypad(makeKeymap(keys), rowPins, colPins, ROWS, COLS);

// ===========================
// Door LED pin
// ===========================
#define LED_PIN 46

// ===========================
// Doorbell Button pin
// ===========================
#define BUTTON_PIN 41

// ===========================
// Door logic
// ===========================
static SemaphoreHandle_t doorMutex;

volatile bool isDoorOpen = false;
volatile unsigned long doorOpenTime = 0;
const unsigned long AUTO_LOCK_DELAY = 60000;

// ===========================
// Firebase objects
// ===========================
FirebaseData fbdo;
FirebaseAuth auth;
FirebaseConfig fconfig;

// ===========================
// Cached access codes
// ===========================
String validCodesJson = "";
volatile unsigned long lastCodesFetchMs = 0;

// Fetch policy
unsigned long lastUserActionMs = 0;
const unsigned long IDLE_BEFORE_FETCH_MS = 2500;
const unsigned long CODES_BACKGROUND_REFRESH_MS = 120000; // 2 minutes
const unsigned long CODES_MAX_AGE_BEFORE_UNLOCK_MS = 10000; // 10s

// ===========================
// Live mode variables (updated by Firebase task)
// ===========================
volatile bool liveActive = false;
volatile int liveFps = 1;
unsigned long lastLiveSnapMs = 0;

// polling periods (in Firebase task)
unsigned long lastCmdPoll = 0;
const unsigned long CMD_POLL_MS = 800;   // was 500ms (less network pressure)
unsigned long lastLivePoll = 0;
const unsigned long LIVE_POLL_MS = 800;  // was 500ms

// ===========================
// Fast button capture (interrupt)
// ===========================
volatile bool btnEdgeSeen = false;
unsigned long lastRingMs = 0;
const unsigned long RING_COOLDOWN_MS = 3000;

// ring request handled in Firebase task
volatile bool ringRequested = false;

// ===========================
// Door command from Firebase (applied in main loop, no blocking)
// ===========================
enum DoorCmd { DC_NONE, DC_LOCK, DC_UNLOCK };
volatile DoorCmd pendingDoorCmd = DC_NONE;

// ===========================
// Unlock event queue (main loop -> Firebase task)
// ===========================
typedef struct {
  char code[12];
  char user[40];
  bool isOtp;
} UnlockEvent;

QueueHandle_t unlockQueue;

// ===========================
// flags for Firebase task
// ===========================
volatile bool doorStatusDirty = false;
volatile bool codesRefreshRequested = false;

// Keep a global sensor pointer (optional)
sensor_t* gSensor = nullptr;

// startCameraServer() is in app_httpd.cpp
void startCameraServer();

// =====================================================
// Button ISR
// =====================================================
void IRAM_ATTR onButtonFalling() {
  btnEdgeSeen = true;
}

// =====================================================
// Small helpers: local door control (NO Firebase inside!)
// =====================================================
void unlockDoorLocal() {
  xSemaphoreTake(doorMutex, portMAX_DELAY);
  digitalWrite(LED_PIN, HIGH);
  isDoorOpen = true;
  doorOpenTime = millis();
  doorStatusDirty = true;
  xSemaphoreGive(doorMutex);
}

void lockDoorLocal() {
  xSemaphoreTake(doorMutex, portMAX_DELAY);
  digitalWrite(LED_PIN, LOW);
  isDoorOpen = false;
  doorStatusDirty = true;
  xSemaphoreGive(doorMutex);
}

void blinkErrorLocal() {
  // short, does not touch Firebase
  for (int i = 0; i < 2; i++) {
    digitalWrite(LED_PIN, HIGH); delay(60);
    digitalWrite(LED_PIN, LOW);  delay(60);
  }
}

// =====================================================
// Firebase helpers (USED ONLY in Firebase task)
// =====================================================
void updateDoorStatusFirebase(const String& status) {
  if (Firebase.ready()) {
    Firebase.RTDB.setString(&fbdo, "/door_status", status);
  }
}

void setDoorCommandNoneFirebase() {
  if (Firebase.ready()) {
    Firebase.RTDB.setString(&fbdo, "/door_command", "NONE");
  }
}

bool pushJsonWithServerTs(const char* path, FirebaseJson& jsonOut, String& pushedKey) {
  if (!Firebase.ready()) return false;

  if (!Firebase.RTDB.pushInt(&fbdo, path, 0)) {
    Serial.println(String("Push failed: ") + fbdo.errorReason());
    return false;
  }

  pushedKey = fbdo.pushName();
  String fullPath = String(path) + "/" + pushedKey;

  if (!Firebase.RTDB.setJSON(&fbdo, fullPath.c_str(), &jsonOut)) {
    Serial.println(String("setJSON failed: ") + fbdo.errorReason());
    return false;
  }

  return true;
}

void fetchAccessCodesFirebase() {
  if (!Firebase.ready()) return;

  Serial.print("Updating codes... ");
  if (Firebase.RTDB.getJSON(&fbdo, "/access_codes")) {
    validCodesJson = fbdo.jsonString();
    lastCodesFetchMs = millis();
    Serial.println("Success! List updated.");
  } else {
    Serial.println("Failed: " + fbdo.errorReason());
  }
}

// =====================================================
// Snapshot -> Base64 (USED ONLY in Firebase task)
// =====================================================
String captureJpegToBase64() {
  camera_fb_t* fb = esp_camera_fb_get();
  if (!fb) {
    Serial.println("Snapshot failed: fb null");
    return "";
  }
  if (fb->format != PIXFORMAT_JPEG) {
    Serial.println("Snapshot not JPEG");
    esp_camera_fb_return(fb);
    return "";
  }

  size_t outLen = 0;
  size_t maxOut = 4 * ((fb->len + 2) / 3) + 1;
  unsigned char* outBuf = (unsigned char*)malloc(maxOut);
  if (!outBuf) {
    Serial.println("malloc failed for base64");
    esp_camera_fb_return(fb);
    return "";
  }

  int ret = mbedtls_base64_encode(outBuf, maxOut, &outLen, fb->buf, fb->len);
  esp_camera_fb_return(fb);

  if (ret != 0) {
    Serial.println("base64 encode failed");
    free(outBuf);
    return "";
  }

  outBuf[outLen] = '\0';
  String b64 = String((char*)outBuf);
  free(outBuf);
  return b64;
}

// =====================================================
// History helpers (Firebase task)
// =====================================================
void pushHistoryEventFirebase(const String& action, const String& by, const String& snapshotKey) {
  if (!Firebase.ready()) return;

  FirebaseJson json;
  json.set("action", action);
  json.set("by", by);
  json.set("ts/.sv", "timestamp");
  if (snapshotKey.length() > 0) json.set("snapshotKey", snapshotKey);

  String histKey;
  if (pushJsonWithServerTs("/history", json, histKey)) {
    Serial.println("History pushed: " + histKey);
  }
}

// =====================================================
// Doorbell press event (Firebase task)
// =====================================================
void handleDoorbellEventFirebase() {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("WiFi not connected -> doorbell event skipped");
    return;
  }

  String b64 = captureJpegToBase64();
  if (b64.isEmpty()) {
    Serial.println("Snapshot base64 empty -> skip event");
    return;
  }

  FirebaseJson snap;
  snap.set("ts/.sv", "timestamp");
  snap.set("format", "jpeg_base64");
  snap.set("image", b64);

  String snapKey;
  if (!pushJsonWithServerTs("/snapshots", snap, snapKey)) {
    Serial.println("Snapshot push failed");
    return;
  }

  Serial.println("Snapshot pushed: " + snapKey);
  Firebase.RTDB.setString(&fbdo, "/last_snapshot_key", snapKey);

  FirebaseJson notif;
  notif.set("type", "ring");
  notif.set("ts/.sv", "timestamp");
  notif.set("snapshotKey", snapKey);

  String notifKey;
  if (pushJsonWithServerTs("/notifications", notif, notifKey)) {
    Serial.println("Notification pushed: " + notifKey);
  }

  pushHistoryEventFirebase("ring", "Visitor", snapKey);
}

// =====================================================
// Live mode snapshot push (Firebase task)
// =====================================================
void pushLiveLatestSnapshotFirebase() {
  if (!Firebase.ready()) return;
  if (WiFi.status() != WL_CONNECTED) return;

  int fpsLocal = liveFps;
  if (fpsLocal < 1) fpsLocal = 1;
  if (fpsLocal > 5) fpsLocal = 5;

  unsigned long intervalMs = 1000UL / (unsigned long)fpsLocal;
  if (millis() - lastLiveSnapMs < intervalMs) return;
  lastLiveSnapMs = millis();

  String b64 = captureJpegToBase64();
  if (b64.isEmpty()) return;

  FirebaseJson live;
  live.set("ts/.sv", "timestamp");
  live.set("format", "jpeg_base64");
  live.set("image", b64);

  if (!Firebase.RTDB.setJSON(&fbdo, "/live/latest", &live)) {
    Serial.println(String("live/latest setJSON failed: ") + fbdo.errorReason());
  }
}

// =====================================================
// Firebase polling (Firebase task)
// =====================================================
void pollRemoteCommandFirebase() {
  if (millis() - lastCmdPoll < CMD_POLL_MS) return;
  lastCmdPoll = millis();
  if (!Firebase.ready()) return;

  if (Firebase.RTDB.getString(&fbdo, "/door_command")) {
    String cmd = fbdo.stringData();
    cmd.trim();

    if (cmd == "LOCK") {
      pendingDoorCmd = DC_LOCK;      // applied in main loop
      setDoorCommandNoneFirebase();  // clear in Firebase
    } else if (cmd == "UNLOCK") {
      pendingDoorCmd = DC_UNLOCK;
      setDoorCommandNoneFirebase();
    }
  }
}

void pollLiveSettingsFirebase() {
  if (millis() - lastLivePoll < LIVE_POLL_MS) return;
  lastLivePoll = millis();
  if (!Firebase.ready()) return;

  // active
  if (Firebase.RTDB.getBool(&fbdo, "/live/active")) {
    liveActive = fbdo.boolData();
  }

  // fps
  if (Firebase.RTDB.getInt(&fbdo, "/live/fps")) {
    int v = fbdo.intData();
    if (v >= 1 && v <= 5) liveFps = v;
  }
}

void maybeFetchAccessCodesSafelyFirebase() {
  if (!Firebase.ready()) return;

  if (codesRefreshRequested) {
    // refresh ASAP when requested (but still avoid while user is typing)
    if (millis() - lastUserActionMs > IDLE_BEFORE_FETCH_MS) {
      codesRefreshRequested = false;
      fetchAccessCodesFirebase();
    }
    return;
  }

  // background refresh (only when idle and old enough)
  if (millis() - lastUserActionMs < IDLE_BEFORE_FETCH_MS) return;
  if (millis() - lastCodesFetchMs > CODES_BACKGROUND_REFRESH_MS) {
    fetchAccessCodesFirebase();
  }
}

// =====================================================
// Firebase Task: all heavy work here
// =====================================================
void firebaseTask(void* pv) {
  (void)pv;

  for (;;) {
    // 1) Ring event
    if (ringRequested) {
      ringRequested = false;
      handleDoorbellEventFirebase();
    }

    // 2) process unlock queue events
    UnlockEvent ev;
    while (xQueueReceive(unlockQueue, &ev, 0) == pdTRUE) {
      pushHistoryEventFirebase("unlock", String(ev.user), "");
      if (ev.isOtp) {
        Serial.println("One-Time Code used. Deleting...");
        String path = String("/access_codes/") + String(ev.code);
        Firebase.RTDB.deleteNode(&fbdo, path);
        codesRefreshRequested = true;
      }
    }

    // 3) update door status if dirty
    if (doorStatusDirty && Firebase.ready()) {
      doorStatusDirty = false;
      bool openLocal;
      xSemaphoreTake(doorMutex, portMAX_DELAY);
      openLocal = isDoorOpen;
      xSemaphoreGive(doorMutex);

      updateDoorStatusFirebase(openLocal ? "Open" : "Closed");
    }

    // 4) Poll commands/live settings
    pollRemoteCommandFirebase();
    pollLiveSettingsFirebase();

    // 5) live snapshots
    if (liveActive) {
      pushLiveLatestSnapshotFirebase();
    }

    // 6) background codes refresh
    maybeFetchAccessCodesSafelyFirebase();

    // small sleep to yield CPU, keep stable
    vTaskDelay(pdMS_TO_TICKS(10));
  }
}

// =====================================================
// Access check in main loop (NO Firebase calls!)
// =====================================================
String getUserNameFromCache(const String& code) {
  if (validCodesJson.length() == 0) return "Unknown";

  FirebaseJson json;
  json.setJsonData(validCodesJson);

  FirebaseJsonData data;
  if (json.get(data, code)) {
    if (data.typeNum == FirebaseJson::JSON_STRING && data.stringValue.length() > 0) {
      return data.stringValue;
    }
  }
  return "Unknown";
}

bool codeExistsInCache(const String& code) {
  // fast key existence check by parsing (not indexOf)
  if (validCodesJson.length() == 0) return false;

  FirebaseJson json;
  json.setJsonData(validCodesJson);

  FirebaseJsonData data;
  return json.get(data, code);
}

String inputCode = "";

// =====================================================
// Setup
// =====================================================
void setup() {
  Serial.begin(115200);
  Serial.setDebugOutput(true);
  Serial.println();

  pinMode(LED_PIN, OUTPUT);
  digitalWrite(LED_PIN, LOW);

  pinMode(BUTTON_PIN, INPUT_PULLUP);
  attachInterrupt(digitalPinToInterrupt(BUTTON_PIN), onButtonFalling, FALLING);

  doorMutex = xSemaphoreCreateMutex();
  unlockQueue = xQueueCreate(8, sizeof(UnlockEvent));

  // ---------------- Camera init
  camera_config_t config;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer = LEDC_TIMER_0;

  config.pin_d0 = Y2_GPIO_NUM;
  config.pin_d1 = Y3_GPIO_NUM;
  config.pin_d2 = Y4_GPIO_NUM;
  config.pin_d3 = Y5_GPIO_NUM;
  config.pin_d4 = Y6_GPIO_NUM;
  config.pin_d5 = Y7_GPIO_NUM;
  config.pin_d6 = Y8_GPIO_NUM;
  config.pin_d7 = Y9_GPIO_NUM;

  config.pin_xclk = XCLK_GPIO_NUM;
  config.pin_pclk = PCLK_GPIO_NUM;
  config.pin_vsync = VSYNC_GPIO_NUM;
  config.pin_href = HREF_GPIO_NUM;

  config.pin_sccb_sda = SIOD_GPIO_NUM;
  config.pin_sccb_scl = SIOC_GPIO_NUM;

  config.pin_pwdn = PWDN_GPIO_NUM;
  config.pin_reset = RESET_GPIO_NUM;

  config.xclk_freq_hz = 20000000;
  config.frame_size = FRAMESIZE_UXGA;
  config.pixel_format = PIXFORMAT_JPEG;
  config.grab_mode = CAMERA_GRAB_WHEN_EMPTY;
  config.fb_location = CAMERA_FB_IN_PSRAM;
  config.jpeg_quality = 12;
  config.fb_count = 1;

  if (config.pixel_format == PIXFORMAT_JPEG) {
    if (psramFound()) {
      config.jpeg_quality = 10;
      config.fb_count = 2;
      config.grab_mode = CAMERA_GRAB_LATEST;
    } else {
      config.frame_size = FRAMESIZE_SVGA;
      config.fb_location = CAMERA_FB_IN_DRAM;
    }
  }

  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK) {
    Serial.printf("Camera init failed with error 0x%x\n", err);
    return;
  }

  sensor_t* s = esp_camera_sensor_get();
  gSensor = s;
  s->set_framesize(s, FRAMESIZE_QVGA);

#if defined(CAMERA_MODEL_ESP32S3_EYE)
  s->set_vflip(s, 1);
#endif

  // ---------------- WiFi
  WiFi.begin(ssid, password);
  WiFi.setSleep(false);

  Serial.print("Connecting to WiFi");
  while (WiFi.status() != WL_CONNECTED) {
    delay(250);
    Serial.print(".");
  }
  Serial.println("\nWiFi connected");
  Serial.print("IP Address: ");
  Serial.println(WiFi.localIP());

  // ---------------- Start camera server (LAN debug)
  startCameraServer();
  Serial.print("Stream URL (LAN debug): http://");
  Serial.print(WiFi.localIP());
  Serial.println(":81/stream");

  // ---------------- Firebase init
  fconfig.api_key = API_KEY;
  fconfig.database_url = DATABASE_URL;
  fconfig.signer.test_mode = true;

  // bigger SSL buffers
  fbdo.setBSSLBufferSize(16384, 16384);
  fconfig.timeout.serverResponse = 15000;

  Firebase.begin(&fconfig, &auth);
  Firebase.reconnectWiFi(true);

  // defaults (non-blocking)
  // We'll do the first writes in the task when ready
  doorStatusDirty = true;

  // initial codes fetch request (task will do it once idle)
  codesRefreshRequested = true;
  lastUserActionMs = millis();

  // Create Firebase task pinned to core 1 (main loop stays super responsive)
  xTaskCreatePinnedToCore(
    firebaseTask,
    "firebaseTask",
    12288,
    nullptr,
    1,
    nullptr,
    1
  );
}

// =====================================================
// Loop (FAST: keypad + button + door state only)
// =====================================================
void loop() {
  // 1) Button press: ISR -> here we apply cooldown and request ring
  if (btnEdgeSeen) {
    btnEdgeSeen = false;
    lastUserActionMs = millis();

    unsigned long now = millis();
    if (now - lastRingMs > RING_COOLDOWN_MS) {
      lastRingMs = now;
      ringRequested = true;
      Serial.println("Doorbell button pressed! (fast ISR capture)");
    } else {
      Serial.println("Doorbell pressed too fast (ignored)");
    }
  }

  // 2) Apply remote command (set by Firebase task)
  DoorCmd cmd = pendingDoorCmd;
  if (cmd != DC_NONE) {
    pendingDoorCmd = DC_NONE;
    if (cmd == DC_LOCK) lockDoorLocal();
    else if (cmd == DC_UNLOCK) unlockDoorLocal();
  }

  // 3) Keypad read (fast)
  char key;
  // read quickly in case multiple keys were pressed
  while ((key = keypad.getKey())) {
    lastUserActionMs = millis();

    if (key == '#') {
      if (inputCode.length() < 4) {
        blinkErrorLocal();
        inputCode = "";
        break;
      }

      // If cache old, request refresh in background (but do NOT block)
      if (millis() - lastCodesFetchMs > CODES_MAX_AGE_BEFORE_UNLOCK_MS) {
        codesRefreshRequested = true;
      }

      if (codeExistsInCache(inputCode)) {
        String userName = getUserNameFromCache(inputCode);
        unlockDoorLocal();

        // enqueue history + OTP delete in background
        UnlockEvent ev{};
        strncpy(ev.code, inputCode.c_str(), sizeof(ev.code) - 1);
        strncpy(ev.user, userName.c_str(), sizeof(ev.user) - 1);
        ev.isOtp = (userName == "OTP_Visitor");
        xQueueSend(unlockQueue, &ev, 0);
      } else {
        blinkErrorLocal();
      }

      inputCode = "";
      break;
    }

    if (key == '*') {
      if (isDoorOpen) lockDoorLocal();
      inputCode = "";
      break;
    }

    // digit
    inputCode += key;
    if (inputCode.length() > 10) { // safety
      inputCode = "";
      blinkErrorLocal();
    }
  }

  // 4) Auto relock (fast)
  bool openLocal;
  unsigned long openTimeLocal;
  xSemaphoreTake(doorMutex, portMAX_DELAY);
  openLocal = isDoorOpen;
  openTimeLocal = doorOpenTime;
  xSemaphoreGive(doorMutex);

  if (openLocal && (millis() - openTimeLocal >= AUTO_LOCK_DELAY)) {
    lockDoorLocal();
  }

  // no heavy delay; keep scanning fast
  delay(1);
}
