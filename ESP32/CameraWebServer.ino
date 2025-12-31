#include "esp_camera.h"
#include <WiFi.h>

#include <Firebase_ESP_Client.h>
#include <Keypad.h>
#include "addons/TokenHelper.h"
#include "addons/RTDBHelper.h"
#include "mbedtls/base64.h"

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

// Button debounce
bool lastBtnState = HIGH;
unsigned long lastBtnChange = 0;
const unsigned long DEBOUNCE_MS = 60;

// Queue ring action so keypad stays responsive
volatile bool pendingRing = false;
unsigned long lastRingMs = 0;
const unsigned long RING_COOLDOWN_MS = 3000;

// ===========================
// Firebase objects
// ===========================
FirebaseData fbdo;
FirebaseAuth auth;
FirebaseConfig fconfig;

// ===========================
// Door logic variables
// ===========================
String validCodesJson = "";
String inputCode = "";
unsigned long lastCheckTime = 0;

bool isDoorOpen = false;
unsigned long doorOpenTime = 0;
const unsigned long AUTO_LOCK_DELAY = 60000;

// Remote command polling
unsigned long lastCmdPoll = 0;
const unsigned long CMD_POLL_MS = 500;

// Live snapshot mode polling
unsigned long lastLivePoll = 0;
const unsigned long LIVE_POLL_MS = 500;

bool liveActive = false;
int liveFps = 1; // default 1 fps
unsigned long lastLiveSnapMs = 0;

// ---------------------------
// ✅ NEW: Make hardware responsive
// ---------------------------
// Track last user activity so we fetch codes ONLY when idle
unsigned long lastUserActionMs = 0;               // updates on button press / keypad press
const unsigned long IDLE_BEFORE_FETCH_MS = 2500;  // only fetch when idle for 2.5s

// Cache freshness: refresh before unlock if too old
unsigned long lastCodesFetchMs = 0;
const unsigned long CODES_MAX_AGE_BEFORE_UNLOCK_MS = 10000; // 10s

// Instead of every 30s always, do background refresh rarely & only when idle
const unsigned long CODES_BACKGROUND_REFRESH_MS = 120000;   // 2 minutes

// Keep a global sensor pointer (optional)
sensor_t* gSensor = nullptr;

// startCameraServer() is in app_httpd.cpp
void startCameraServer();

// =====================================================
// Firebase helpers
// =====================================================
void updateDoorStatus(const String& status) {
  if (Firebase.ready()) {
    Firebase.RTDB.setString(&fbdo, "/door_status", status);
  }
}

void setDoorCommandNone() {
  if (Firebase.ready()) {
    Firebase.RTDB.setString(&fbdo, "/door_command", "NONE");
  }
}

void fetchAccessCodes() {
  if (Firebase.ready()) {
    Serial.print("Updating codes... ");
    if (Firebase.RTDB.getJSON(&fbdo, "/access_codes")) {
      validCodesJson = fbdo.jsonString();
      lastCodesFetchMs = millis(); // ✅ remember freshness
      Serial.println("Success! List updated.");
    } else {
      Serial.println("Failed: " + fbdo.errorReason());
    }
  }
}

// ✅ NEW: fetch codes only when safe (idle + not during ring + not while typing)
void maybeFetchAccessCodesSafely() {
  // don't fetch while user is doing something important
  if (pendingRing) return;
  if (inputCode.length() > 0) return; // user typing -> do not block
  if (millis() - lastUserActionMs < IDLE_BEFORE_FETCH_MS) return;

  // background refresh only if old enough
  if (millis() - lastCodesFetchMs > CODES_BACKGROUND_REFRESH_MS) {
    fetchAccessCodes();
  }
}

// Push helper: creates a push key and writes JSON at that key
bool pushJsonWithServerTs(const char* path, FirebaseJson& jsonOut, String& pushedKey) {
  if (!Firebase.ready()) {
    Serial.println("Firebase not ready (skip push)");
    return false;
  }

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

// =====================================================
// Snapshot -> Base64
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
// History helpers
// =====================================================
void pushHistoryEvent(const String& action, const String& by, const String& snapshotKey) {
  if (!Firebase.ready()) return;

  FirebaseJson json;
  json.set("action", action);          // "ring" / "unlock" / etc.
  json.set("by", by);                  // "Visitor" / userName / etc.
  json.set("ts/.sv", "timestamp");
  if (snapshotKey.length() > 0) {
    json.set("snapshotKey", snapshotKey);
  }

  String histKey;
  if (pushJsonWithServerTs("/history", json, histKey)) {
    Serial.println("History pushed: " + histKey);
  }
}

// =====================================================
// Doorbell press event:
// snapshot -> notification(with snapshotKey) -> history(with snapshotKey)
// =====================================================
void handleDoorbellEvent() {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("WiFi not connected -> doorbell event skipped");
    return;
  }

  // 1) Capture snapshot
  String b64 = captureJpegToBase64();
  if (b64.isEmpty()) {
    Serial.println("Snapshot base64 empty -> skip event");
    return;
  }

  // 2) Push snapshot
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

  // 3) Push notification referencing snapshot
  FirebaseJson notif;
  notif.set("type", "ring");
  notif.set("ts/.sv", "timestamp");
  notif.set("snapshotKey", snapKey);

  String notifKey;
  if (pushJsonWithServerTs("/notifications", notif, notifKey)) {
    Serial.println("Notification pushed: " + notifKey);
  }

  // 4) Push history ring event referencing snapshot
  pushHistoryEvent("ring", "Visitor", snapKey);
}

// =====================================================
// Door + keypad logic
// =====================================================
void logHistoryRealTimeUnlock(const String& code) {
  String namePath = "/access_codes/" + code;
  String userName = "Unknown";

  if (Firebase.RTDB.getString(&fbdo, namePath)) {
    userName = fbdo.stringData();
  }

  // push history unlock event
  pushHistoryEvent("unlock", userName, "");

  if (userName == "OTP_Visitor") {
    Serial.println("One-Time Code used. Deleting...");
    Firebase.RTDB.deleteNode(&fbdo, namePath);
    fetchAccessCodes();
  }
}

void unlockDoor() {
  digitalWrite(LED_PIN, HIGH);
  isDoorOpen = true;
  doorOpenTime = millis();
  updateDoorStatus("Open");
}

void lockDoor() {
  digitalWrite(LED_PIN, LOW);
  isDoorOpen = false;
  updateDoorStatus("Closed");
}

void blinkError() {
  for (int i = 0; i < 3; i++) {
    digitalWrite(LED_PIN, HIGH); delay(100);
    digitalWrite(LED_PIN, LOW);  delay(100);
  }
}

void checkAccess() {
  Serial.print("Checking: " + inputCode);

  if (inputCode.length() < 4) {
    Serial.println(" -> Too short");
    blinkError();
    return;
  }

  // ✅ NEW: refresh codes only if cache is old (prevents always-reading)
  if (millis() - lastCodesFetchMs > CODES_MAX_AGE_BEFORE_UNLOCK_MS) {
    Serial.println("\nCodes cache old -> refreshing once before unlock...");
    fetchAccessCodes();
  }

  if (validCodesJson.indexOf("\"" + inputCode + "\"") >= 0) {
    Serial.println(" -> ACCESS GRANTED!");
    logHistoryRealTimeUnlock(inputCode);
    unlockDoor();
  } else {
    Serial.println(" -> ACCESS DENIED.");
    blinkError();
  }
}

void pollRemoteCommand() {
  if (millis() - lastCmdPoll < CMD_POLL_MS) return;
  lastCmdPoll = millis();

  if (!Firebase.ready()) return;

  if (Firebase.RTDB.getString(&fbdo, "/door_command")) {
    String cmd = fbdo.stringData();
    cmd.trim();

    if (cmd == "LOCK") {
      lockDoor();
      setDoorCommandNone();
    } else if (cmd == "UNLOCK") {
      unlockDoor();
      setDoorCommandNone();
    }
  }
}

// =====================================================
// Live mode: app controls /live/active and /live/fps
// ESP overwrites /live/latest with fresh snapshots
// =====================================================
void pollLiveSettings() {
  if (millis() - lastLivePoll < LIVE_POLL_MS) return;
  lastLivePoll = millis();

  if (!Firebase.ready()) return;

  // active
  if (Firebase.RTDB.getBool(&fbdo, "/live/active")) {
    liveActive = fbdo.boolData();
  }

  // fps (optional)
  if (Firebase.RTDB.getInt(&fbdo, "/live/fps")) {
    int v = fbdo.intData();
    if (v >= 1 && v <= 5) liveFps = v; // clamp to safe range
  }
}

void pushLiveLatestSnapshot() {
  if (!Firebase.ready()) return;
  if (WiFi.status() != WL_CONNECTED) return;

  unsigned long intervalMs = 1000UL / (unsigned long)liveFps;
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
  } else {
    Serial.println("Live latest updated");
  }
}

// =====================================================
// Button handling (debounced) -> QUEUE action
// =====================================================
void handleButton() {
  bool cur = digitalRead(BUTTON_PIN);

  if (cur != lastBtnState) {
    lastBtnChange = millis();
    lastBtnState = cur;
  }

  if (millis() - lastBtnChange > DEBOUNCE_MS) {
    static bool lastStable = HIGH;
    if (cur != lastStable) {
      lastStable = cur;

      if (cur == LOW) {
        unsigned long now = millis();
        if (now - lastRingMs > RING_COOLDOWN_MS) {
          lastRingMs = now;
          pendingRing = true;
          lastUserActionMs = millis(); // ✅ mark activity immediately
          Serial.println("Doorbell button pressed! (queued)");
        } else {
          Serial.println("Doorbell pressed too fast (ignored)");
        }
      }
    }
  }
}

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
    delay(300);
    Serial.print(".");
  }
  Serial.println("\nWiFi connected");
  Serial.print("IP Address: ");
  Serial.println(WiFi.localIP());

  // ---------------- Start camera server (still useful for LAN debugging)
  startCameraServer();
  Serial.print("Stream URL (LAN debug): http://");
  Serial.print(WiFi.localIP());
  Serial.println(":81/stream");

  // ---------------- Firebase init
  fconfig.api_key = API_KEY;
  fconfig.database_url = DATABASE_URL;
  fconfig.signer.test_mode = true;

  // ✅ IMPORTANT: bigger SSL buffers to keep snapshot push reliable
  // (does not break your live; it improves stability)
  fbdo.setBSSLBufferSize(16384, 16384);
  fconfig.timeout.serverResponse = 15000;

  Firebase.begin(&fconfig, &auth);
  Firebase.reconnectWiFi(true);

  updateDoorStatus("Closed");
  setDoorCommandNone();

  // ✅ One fetch at boot
  fetchAccessCodes();

  // defaults for live mode nodes (optional)
  Firebase.RTDB.setBool(&fbdo, "/live/active", false);
  Firebase.RTDB.setInt(&fbdo, "/live/fps", 1);

  lastUserActionMs = millis();
}

// =====================================================
// Loop
// =====================================================
void loop() {
  handleButton();

  // Doorbell press event (snapshot + notification + history)
  if (pendingRing) {
    pendingRing = false;
    handleDoorbellEvent();
  }

  pollRemoteCommand();

  // Live view mode (only updates while app sets /live/active=true)
  pollLiveSettings();
  if (liveActive) {
    pushLiveLatestSnapshot();
  }

  // Keypad read
  char key = keypad.getKey();
  if (key) {
    lastUserActionMs = millis(); // ✅ mark activity

    Serial.print("Pressed: ");
    Serial.println(key);

    if (key == '#') {
      checkAccess();
      inputCode = "";
    } else if (key == '*') {
      if (isDoorOpen) lockDoor();
      inputCode = "";
      Serial.println("Entry cleared!");
    } else {
      inputCode += key;
    }
  }

  // ✅ REPLACED the old "every 30s always" refresh:
  // Refresh codes only when idle + safe
  maybeFetchAccessCodesSafely();

  // Auto relock
  if (isDoorOpen && (millis() - doorOpenTime >= AUTO_LOCK_DELAY)) {
    Serial.println("Auto-Relock triggered.");
    lockDoor();
  }

  delay(5);
}
