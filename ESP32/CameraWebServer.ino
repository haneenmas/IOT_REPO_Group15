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
const char* ssid = "bezeqfiber";
const char* password = "0522441867";

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
// Firebase objects
// ===========================
FirebaseData fbdo;
FirebaseAuth auth;
FirebaseConfig fconfig;

// ===========================
// Mutexes / Queues
// ===========================
static SemaphoreHandle_t doorMutex;
static SemaphoreHandle_t codesMutex;
QueueHandle_t unlockQueue;

// ===========================
// Door logic
// ===========================
volatile bool isDoorOpen = false;
volatile unsigned long doorOpenTime = 0;
const unsigned long AUTO_LOCK_DELAY = 60000;
volatile bool doorStatusDirty = false;

// ===========================
// Cached access codes
// ===========================
String validCodesJson = "";
volatile unsigned long lastCodesFetchMs = 0;

unsigned long lastUserActionMs = 0;
const unsigned long IDLE_BEFORE_FETCH_MS = 2500;
const unsigned long CODES_BACKGROUND_REFRESH_MS = 120000;   // 2 minutes
const unsigned long CODES_MAX_AGE_BEFORE_UNLOCK_MS = 10000; // 10 seconds
volatile bool codesRefreshRequested = false;

// ===========================
// Live mode variables
// ===========================
volatile bool liveActive = false;
volatile int liveFps = 1;
unsigned long lastLiveSnapMs = 0;

// Polling periods (Firebase task)
unsigned long lastCmdPoll = 0;
const unsigned long CMD_POLL_MS = 800;
unsigned long lastLivePoll = 0;
const unsigned long LIVE_POLL_MS = 800;

// Backoff after failures
unsigned long liveBackoffUntil = 0;

// Pause live while ring upload is running
volatile bool ringInProgress = false;

// ===========================
// Remote command from Firebase -> applied locally
// ===========================
enum DoorCmd { DC_NONE, DC_LOCK, DC_UNLOCK };
volatile DoorCmd pendingDoorCmd = DC_NONE;

// ===========================
// Fast button capture via ISR (debounced)
// ===========================
volatile uint16_t btnIsrCount = 0;
volatile uint32_t lastBtnIsrUs = 0;
const uint32_t BTN_BOUNCE_US = 80000; // 80ms ISR debounce
unsigned long lastRingMs = 0;
const unsigned long RING_COOLDOWN_MS = 3000;
volatile bool ringRequested = false;

// ===========================
// Unlock event queue (main loop -> Firebase task)
// ===========================
typedef struct {
  char code[12];
  char user[40];
  bool isOtp;
} UnlockEvent;

// ===========================
// Camera sensor pointer + profiles
// ===========================
sensor_t* gSensor = nullptr;

// startCameraServer() is in app_httpd.cpp
void startCameraServer();

// ===========================
// ✅ NEW: LAN publish state
// ===========================
String lastPublishedIp = "";
unsigned long lastLanPublishMs = 0;
const unsigned long LAN_PUBLISH_MS = 30000; // publish at boot + every 30s (or when IP changes)

// ===========================
// ✅ NEW: adaptive live clarity
// ===========================
unsigned long forceSmallLiveUntil = 0; // if live fails, force small profile for some time

// ---------- Camera profiles ----------
void setCameraProfileLiveSmall() {
  if (!gSensor) return;
  gSensor->set_framesize(gSensor, FRAMESIZE_QQVGA); // 160x120
  gSensor->set_quality(gSensor, 22);                // smaller file
}

void setCameraProfileLiveClear() {
  if (!gSensor) return;
  gSensor->set_framesize(gSensor, FRAMESIZE_QVGA);  // 320x240 (clearer)
  gSensor->set_quality(gSensor, 16);                // clearer but larger
}

void setCameraProfileRing() {
  if (!gSensor) return;
  gSensor->set_framesize(gSensor, FRAMESIZE_QVGA);  // 320x240
  gSensor->set_quality(gSensor, 18);                // stable size
}

// =====================================================
// Button ISR
// =====================================================
void IRAM_ATTR onButtonFalling() {
  uint32_t now = micros();
  if (now - lastBtnIsrUs < BTN_BOUNCE_US) return;
  lastBtnIsrUs = now;
  btnIsrCount++;
}

// =====================================================
// Local door control (NO Firebase here)
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
  for (int i = 0; i < 2; i++) {
    digitalWrite(LED_PIN, HIGH); delay(60);
    digitalWrite(LED_PIN, LOW);  delay(60);
  }
}

// =====================================================
// Firebase helpers (Firebase task only)
// =====================================================
void updateDoorStatusFirebase(const String& status) {
  if (Firebase.ready()) Firebase.RTDB.setString(&fbdo, "/door_status", status);
}

void setDoorCommandNoneFirebase() {
  if (Firebase.ready()) Firebase.RTDB.setString(&fbdo, "/door_command", "NONE");
}

// ✅ NEW: publish LAN stream URL to Firebase
void publishLanInfoFirebase(bool force = false) {
  if (!Firebase.ready()) return;

  if (WiFi.status() != WL_CONNECTED) {
    Firebase.RTDB.setBool(&fbdo, "/lan/online", false);
    return;
  }

  String ip = WiFi.localIP().toString();
  if (!force && ip == lastPublishedIp && (millis() - lastLanPublishMs) < LAN_PUBLISH_MS) return;

  String url = "http://" + ip + ":81/stream";

  Firebase.RTDB.setString(&fbdo, "/lan/ip", ip);
  Firebase.RTDB.setString(&fbdo, "/lan/stream_url", url);
  Firebase.RTDB.setBool(&fbdo, "/lan/online", true);

  FirebaseJson ts;
  ts.set(".sv", "timestamp");
  Firebase.RTDB.setJSON(&fbdo, "/lan/ts", &ts);

  lastPublishedIp = ip;
  lastLanPublishMs = millis();

  Serial.print("✅ Published LAN URL: ");
  Serial.println(url);
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
    String json = fbdo.jsonString();

    xSemaphoreTake(codesMutex, portMAX_DELAY);
    validCodesJson = json;
    xSemaphoreGive(codesMutex);

    lastCodesFetchMs = millis();
    Serial.println("Success! List updated.");
  } else {
    Serial.println("Failed: " + fbdo.errorReason());
  }
}

bool setJSONWithRetry(const char* path, FirebaseJson& json, int tries = 3) {
  for (int i = 0; i < tries; i++) {
    if (WiFi.status() != WL_CONNECTED) return false;

    if (Firebase.RTDB.setJSON(&fbdo, path, &json)) return true;

    Serial.print("setJSON failed: ");
    Serial.println(fbdo.errorReason());
    vTaskDelay(pdMS_TO_TICKS(250 * (i + 1)));
  }
  return false;
}

// =====================================================
// Snapshot -> Base64 (Firebase task only) + size prints
// =====================================================
String captureJpegToBase64() {
  camera_fb_t* fb = esp_camera_fb_get();
  if (!fb) { Serial.println("Snapshot failed: fb null"); return ""; }
  if (fb->format != PIXFORMAT_JPEG) { Serial.println("Snapshot not JPEG"); esp_camera_fb_return(fb); return ""; }

  Serial.print("JPEG bytes: "); Serial.println(fb->len);

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

  if (ret != 0) { Serial.println("base64 encode failed"); free(outBuf); return ""; }

  Serial.print("B64 bytes: "); Serial.println((int)outLen);

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
  if (pushJsonWithServerTs("/history", json, histKey)) Serial.println("History pushed: " + histKey);
}

// =====================================================
// Doorbell event (Firebase task)
// =====================================================
void handleDoorbellEventFirebase() {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("WiFi not connected -> doorbell event skipped");
    return;
  }

  setCameraProfileRing();

  String b64 = captureJpegToBase64();
  if (b64.isEmpty()) { Serial.println("Snapshot base64 empty -> skip event"); return; }

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
  if (pushJsonWithServerTs("/notifications", notif, notifKey)) Serial.println("Notification pushed: " + notifKey);

  pushHistoryEventFirebase("ring", "Visitor", snapKey);
}

// =====================================================
// Live latest snapshot (Firebase task): clearer when possible
// =====================================================
void pushLiveLatestSnapshotFirebase() {
  if (!Firebase.ready()) return;
  if (WiFi.status() != WL_CONNECTED) return;
  if (ringInProgress) return;
  if (millis() < liveBackoffUntil) return;

  int fpsLocal = liveFps;
  if (fpsLocal < 1) fpsLocal = 1;
  if (fpsLocal > 5) fpsLocal = 5;

  unsigned long intervalMs = 1000UL / (unsigned long)fpsLocal;
  if (millis() - lastLiveSnapMs < intervalMs) return;
  lastLiveSnapMs = millis();

  // ✅ clearer when fps is low and no recent failures
  bool forceSmall = (millis() < forceSmallLiveUntil);
  if (!forceSmall && fpsLocal <= 1) setCameraProfileLiveClear();
  else setCameraProfileLiveSmall();

  String b64 = captureJpegToBase64();
  if (b64.isEmpty()) return;

  FirebaseJson live;
  live.set("ts/.sv", "timestamp");
  live.set("format", "jpeg_base64");
  live.set("image", b64);

  if (!setJSONWithRetry("/live/latest", live, 2)) {
    Serial.print("WiFi="); Serial.print(WiFi.status());
    Serial.print(" RSSI="); Serial.print(WiFi.RSSI());
    Serial.print(" Heap="); Serial.println(ESP.getFreeHeap());

    // ✅ if it fails, force small live for 60 seconds
    forceSmallLiveUntil = millis() + 60000;
    liveBackoffUntil = millis() + 3000;
  }
}

// =====================================================
// Poll remote command / live settings (Firebase task)
// =====================================================
void pollRemoteCommandFirebase() {
  if (millis() - lastCmdPoll < CMD_POLL_MS) return;
  lastCmdPoll = millis();
  if (!Firebase.ready()) return;

  if (Firebase.RTDB.getString(&fbdo, "/door_command")) {
    String cmd = fbdo.stringData();
    cmd.trim();

    if (cmd == "LOCK") {
      pendingDoorCmd = DC_LOCK;
      setDoorCommandNoneFirebase();
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

  if (Firebase.RTDB.getBool(&fbdo, "/live/active")) liveActive = fbdo.boolData();

  if (Firebase.RTDB.getInt(&fbdo, "/live/fps")) {
    int v = fbdo.intData();
    if (v >= 1 && v <= 5) liveFps = v;
  }
}

void maybeFetchAccessCodesSafelyFirebase() {
  if (!Firebase.ready()) return;

  if (codesRefreshRequested) {
    if (millis() - lastUserActionMs > IDLE_BEFORE_FETCH_MS) {
      codesRefreshRequested = false;
      fetchAccessCodesFirebase();
    }
    return;
  }

  if (millis() - lastUserActionMs < IDLE_BEFORE_FETCH_MS) return;

  if (millis() - lastCodesFetchMs > CODES_BACKGROUND_REFRESH_MS) fetchAccessCodesFirebase();
}

// =====================================================
// Firebase Task
// =====================================================
void firebaseTask(void* pv) {
  (void)pv;

  bool didInitNodes = false;

  for (;;) {
    if (!didInitNodes && Firebase.ready()) {
      didInitNodes = true;

      Firebase.RTDB.setBool(&fbdo, "/live/active", false);
      Firebase.RTDB.setInt(&fbdo, "/live/fps", 1);
      setDoorCommandNoneFirebase();
      updateDoorStatusFirebase("Closed");
      codesRefreshRequested = true;

      // ✅ publish LAN info immediately when Firebase ready
      publishLanInfoFirebase(true);
    }

    // ✅ publish LAN info periodically (or if IP changes)
    if (Firebase.ready()) publishLanInfoFirebase(false);

    // 1) Ring event
    if (ringRequested) {
      ringRequested = false;
      ringInProgress = true;
      handleDoorbellEventFirebase();
      ringInProgress = false;
    }

    // 2) Process unlock queue
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

    // 3) Update door status if dirty
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

    // 5) Live snapshots
    if (liveActive) pushLiveLatestSnapshotFirebase();

    // 6) Background codes refresh
    maybeFetchAccessCodesSafelyFirebase();

    vTaskDelay(pdMS_TO_TICKS(10));
  }
}

// =====================================================
// Cache-based JSON lookup (main loop, NO Firebase)
// =====================================================
bool codeExistsInCache(const String& code) {
  String localJson;
  xSemaphoreTake(codesMutex, portMAX_DELAY);
  localJson = validCodesJson;
  xSemaphoreGive(codesMutex);

  if (localJson.length() == 0) return false;

  FirebaseJson json;
  json.setJsonData(localJson);

  FirebaseJsonData data;
  return json.get(data, code);
}

String getUserNameFromCache(const String& code) {
  String localJson;
  xSemaphoreTake(codesMutex, portMAX_DELAY);
  localJson = validCodesJson;
  xSemaphoreGive(codesMutex);

  if (localJson.length() == 0) return "Unknown";

  FirebaseJson json;
  json.setJsonData(localJson);

  FirebaseJsonData data;
  if (json.get(data, code)) {
    if (data.typeNum == FirebaseJson::JSON_STRING && data.stringValue.length() > 0) return data.stringValue;
  }
  return "Unknown";
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
  attachInterrupt(digitalPinToInterrupt(BUTTON_PIN), onButtonFalling, FALLING);

  doorMutex = xSemaphoreCreateMutex();
  codesMutex = xSemaphoreCreateMutex();
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

  gSensor = esp_camera_sensor_get();

#if defined(CAMERA_MODEL_ESP32S3_EYE)
  if (gSensor) gSensor->set_vflip(gSensor, 1);
#endif

  // default to ring profile
  setCameraProfileRing();

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
  Serial.print("Stream URL (LAN): http://");
  Serial.print(WiFi.localIP());
  Serial.println(":81/stream");

  // ---------------- Firebase init
  fconfig.api_key = API_KEY;
  fconfig.database_url = DATABASE_URL;
  fconfig.signer.test_mode = true;

  fbdo.setBSSLBufferSize(16384, 16384);
  fconfig.timeout.serverResponse = 15000;

  Firebase.begin(&fconfig, &auth);
  Firebase.reconnectWiFi(true);

  doorStatusDirty = true;
  lastUserActionMs = millis();

  // Create Firebase task pinned to core 1
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
// Loop (FAST)
// =====================================================
String inputCode = "";

void loop() {
  // 1) Handle all ISR button presses safely (debounced count)
  static uint16_t lastHandled = 0;
  uint16_t cur = btnIsrCount;

  while (lastHandled != cur) {
    lastHandled++;
    lastUserActionMs = millis();

    unsigned long nowMs = millis();
    if (nowMs - lastRingMs > RING_COOLDOWN_MS) {
      lastRingMs = nowMs;
      ringRequested = true;
      Serial.println("Doorbell button pressed! (queued)");
    } else {
      Serial.println("Doorbell ignored (cooldown)");
    }
  }

  // 2) Apply remote command locally
  DoorCmd cmd = pendingDoorCmd;
  if (cmd != DC_NONE) {
    pendingDoorCmd = DC_NONE;
    if (cmd == DC_LOCK) lockDoorLocal();
    else if (cmd == DC_UNLOCK) unlockDoorLocal();
  }

  // 3) Keypad read + Serial prints
  char key;
  while ((key = keypad.getKey())) {
    lastUserActionMs = millis();

    Serial.print("Keypad pressed: ");
    Serial.println(key);

    if (key == '#') {
      Serial.print("Entered code: ");
      Serial.println(inputCode);

      if (inputCode.length() < 4) {
        Serial.println("Too short ❌");
        blinkErrorLocal();
        inputCode = "";
        break;
      }

      if (millis() - lastCodesFetchMs > CODES_MAX_AGE_BEFORE_UNLOCK_MS) {
        codesRefreshRequested = true; // background refresh
      }

      if (codeExistsInCache(inputCode)) {
        Serial.println("ACCESS GRANTED ✅");
        String userName = getUserNameFromCache(inputCode);
        unlockDoorLocal();

        UnlockEvent ev{};
        strncpy(ev.code, inputCode.c_str(), sizeof(ev.code) - 1);
        strncpy(ev.user, userName.c_str(), sizeof(ev.user) - 1);
        ev.isOtp = (userName == "OTP_Visitor");
        xQueueSend(unlockQueue, &ev, 0);
      } else {
        Serial.println("ACCESS DENIED ❌");
        blinkErrorLocal();
      }

      inputCode = "";
      break;
    }

    if (key == '*') {
      Serial.println("Entry cleared (*)");
      if (isDoorOpen) lockDoorLocal();
      inputCode = "";
      break;
    }

    inputCode += key;
    Serial.print("Current buffer: ");
    Serial.println(inputCode);

    if (inputCode.length() > 10) {
      Serial.println("Buffer too long -> cleared");
      inputCode = "";
      blinkErrorLocal();
    }
  }

  // 4) Auto-relock
  bool openLocal;
  unsigned long openTimeLocal;
  xSemaphoreTake(doorMutex, portMAX_DELAY);
  openLocal = isDoorOpen;
  openTimeLocal = doorOpenTime;
  xSemaphoreGive(doorMutex);

  if (openLocal && (millis() - openTimeLocal >= AUTO_LOCK_DELAY)) {
    Serial.println("Auto-Relock triggered.");
    lockDoorLocal();
  }

  delay(1);
}
