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

// ===== Audio (MAX98357A) =====
#include "FS.h"
#include "LittleFS.h"
#include "driver/i2s.h"

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
// ✅ Security: PIN lockout after 5 failures (1 minute)
// ===========================
static uint8_t wrongAttempts = 0;
static unsigned long lockoutUntilMs = 0;

const uint8_t MAX_WRONG_ATTEMPTS = 5;
const unsigned long LOCKOUT_MS = 60000; // 1 minute

static volatile bool lockoutEventPending = false;  // Firebase task will log this
static volatile uint8_t lockoutEventAttempts = 0;

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
void startCameraServer();

// ===========================
// ✅ LAN publish state
// ===========================
String lastPublishedIp = "";
unsigned long lastLanPublishMs = 0;
const unsigned long LAN_PUBLISH_MS = 30000;

// ===========================
// ✅ adaptive live clarity
// ===========================
unsigned long forceSmallLiveUntil = 0;

// ---------- Camera profiles ----------
void setCameraProfileLiveSmall() {
  if (!gSensor) return;
  gSensor->set_framesize(gSensor, FRAMESIZE_QQVGA); // 160x120 (fast)
  gSensor->set_quality(gSensor, 22);                // more compression (smaller)
}

void setCameraProfileLiveClear() {
  if (!gSensor) return;
  gSensor->set_framesize(gSensor, FRAMESIZE_QVGA);  // 320x240 (clear)
  gSensor->set_quality(gSensor, 10);                // ✅ clearer (bigger upload)
}


void setCameraProfileRing() {
  if (!gSensor) return;
  gSensor->set_framesize(gSensor, FRAMESIZE_QVGA);
  gSensor->set_quality(gSensor, 18);
}

// =====================================================
// ===== OFFLINE cache (LittleFS) =====
// =====================================================
static const char* CODES_FILE = "/offline_codes.json";

void saveCodesCacheToFS(const String& json) {
  String s = json;
  s.trim();

  // ✅ Do NOT overwrite cache with empty/invalid Firebase returns
  if (s.length() < 2 || s == "null" || s == "{}") {
    Serial.print("⚠️ Not saving cache (invalid json): '");
    Serial.print(s);
    Serial.println("'");
    return;
  }

  File f = LittleFS.open(CODES_FILE, "w");
  if (!f) {
    Serial.println("❌ Failed to open offline_codes.json for writing");
    return;
  }

  size_t written = f.print(s);
  f.flush();
  f.close();

  // ✅ verify by reopening
  File v = LittleFS.open(CODES_FILE, "r");
  size_t sz = v ? v.size() : 0;
  String head = "";
  if (v) {
    head = v.readString().substring(0, 120);
    v.close();
  }

  Serial.print("✅ Codes cache saved: wrote=");
  Serial.print(written);
  Serial.print(" bytes | file_size=");
  Serial.println(sz);

  Serial.print("📄 offline_codes.json preview: ");
  Serial.println(head);
}


bool loadCodesCacheFromFS() {
  if (!LittleFS.exists(CODES_FILE)) {
    Serial.println("ℹ️ No codes cache file in LittleFS yet");
    return false;
  }

  File f = LittleFS.open(CODES_FILE, "r");
  if (!f) {
    Serial.println("❌ Failed to open codes cache file for reading");
    return false;
  }

  String json = f.readString();
  f.close();

  if (json.length() < 2) {
    Serial.println("❌ Codes cache file is empty/bad");
    return false;
  }

  xSemaphoreTake(codesMutex, portMAX_DELAY);
  validCodesJson = json;
  xSemaphoreGive(codesMutex);

  // Treat as "fresh enough" for offline usage
  lastCodesFetchMs = millis();

  Serial.println("✅ Codes cache loaded from LittleFS (offline mode ready)");
  return true;
}

// =====================================================
// ===== AUDIO forward declarations =====
// =====================================================
static void i2sInitOnce();
static void testBeep();
static bool readWavHeader(File& f, uint32_t& sampleRate, uint16_t& channels, uint16_t& bitsPerSample, uint32_t& dataStart, uint32_t& dataSize);
static void playWavFile(const char* path, int vol0_10);

// =====================================================
// ===== AUDIO (MAX98357A) - LittleFS =====
// =====================================================
// Wiring:
#define I2S_BCLK_PIN 39
#define I2S_LRC_PIN  40
#define I2S_DOUT_PIN 38

static const char* FB_AUDIO_COMMAND  = "/audio/command";
static const char* FB_AUDIO_ACTIVE   = "/audio/active";
static const char* FB_AUDIO_VOLUME   = "/audio/volume";
static const char* FB_AUDIO_MESSAGES = "/audio/messages";

volatile bool audioActive = false;
volatile int  audioVolume = 2; // 0..10

unsigned long lastAudioPoll = 0;
const unsigned long AUDIO_POLL_MS_ACTIVE = 400;
const unsigned long AUDIO_POLL_MS_IDLE   = 4000;

// audio worker queue
typedef struct {
  char file[64];   // "/LeavePackage.wav"
  int volume;      // 0..10
  bool stop;       // true = stop
} AudioJob;

static QueueHandle_t audioQueue;
static TaskHandle_t  audioTaskHandle = nullptr;
static volatile bool audioStopFlag = false;

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
  testBeep();
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

    // ✅ offline persistence
    saveCodesCacheToFS(json);

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
// Snapshot -> Base64 (Firebase task only)
// =====================================================
String captureJpegToBase64() {
  camera_fb_t* fb = esp_camera_fb_get();
  if (!fb) { Serial.println("Snapshot failed: fb null"); return ""; }
  if (fb->format != PIXFORMAT_JPEG) { Serial.println("Snapshot not JPEG"); esp_camera_fb_return(fb); return ""; }

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

  outBuf[outLen] = '\0';
  String b64 = String((char*)outBuf);
  free(outBuf);
  return b64;
}

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
    Serial.println("WiFi not connected -> doorbell event skipped (offline)");
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
// Live latest snapshot (Firebase task)
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
  forceSmallLiveUntil = millis() + 10000; // ✅ only 10s small mode
  liveBackoffUntil = millis() + 3000;
} else {
  forceSmallLiveUntil = 0; // ✅ go back to clear immediately
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
// ===== AUDIO implementation =====
// =====================================================
static void i2sInitOnce() {
  static bool inited = false;
  if (inited) return;
  inited = true;

  i2s_config_t i2s_config = {};
  i2s_config.mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_TX);
  i2s_config.sample_rate = 16000;
  i2s_config.bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT;

  // ✅ Most compatible: stereo frames
  i2s_config.channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT;
  i2s_config.communication_format = I2S_COMM_FORMAT_STAND_I2S;

  i2s_config.intr_alloc_flags = 0;
  i2s_config.dma_buf_count = 8;
  i2s_config.dma_buf_len = 256;
  i2s_config.use_apll = false;
  i2s_config.tx_desc_auto_clear = true;
  i2s_config.fixed_mclk = 0;

  i2s_pin_config_t pin_config = {};
  pin_config.bck_io_num = I2S_BCLK_PIN;
  pin_config.ws_io_num = I2S_LRC_PIN;
  pin_config.data_out_num = I2S_DOUT_PIN;
  pin_config.data_in_num = I2S_PIN_NO_CHANGE;

  esp_err_t e1 = i2s_driver_install(I2S_NUM_0, &i2s_config, 0, NULL);
  esp_err_t e2 = i2s_set_pin(I2S_NUM_0, &pin_config);
  i2s_zero_dma_buffer(I2S_NUM_0);

  Serial.print("✅ I2S init: install=");
  Serial.print((int)e1);
  Serial.print(" set_pin=");
  Serial.println((int)e2);
}

static void testBeep() {
  i2sInitOnce();
  i2s_set_clk(I2S_NUM_0, 16000, I2S_BITS_PER_SAMPLE_16BIT, I2S_CHANNEL_STEREO);

  const int N = 8000; // 0.5 sec
  for (int i = 0; i < N; i++) {
    int16_t s = (i % 80 < 40) ? 16000 : -16000;
    int16_t frame[2] = { s, s };
    size_t written = 0;
    i2s_write(I2S_NUM_0, (const char*)frame, sizeof(frame), &written, portMAX_DELAY);
  }

  i2s_zero_dma_buffer(I2S_NUM_0);
}

static inline int16_t applyVol(int16_t s, int vol0_10) {
  if (vol0_10 < 0) vol0_10 = 0;
  if (vol0_10 > 10) vol0_10 = 10;
  int32_t v = (int32_t)s * vol0_10;
  v /= 10;
  if (v > 32767) v = 32767;
  if (v < -32768) v = -32768;
  return (int16_t)v;
}

static bool readWavHeader(File& f, uint32_t& sampleRate, uint16_t& channels, uint16_t& bitsPerSample, uint32_t& dataStart, uint32_t& dataSize) {
  if (f.size() < 44) return false;

  auto rd32 = [&](uint32_t& v)->bool {
    uint8_t b[4];
    if (f.read(b, 4) != 4) return false;
    v = (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
    return true;
  };
  auto rd16 = [&](uint16_t& v)->bool {
    uint8_t b[2];
    if (f.read(b, 2) != 2) return false;
    v = (uint16_t)b[0] | ((uint16_t)b[1] << 8);
    return true;
  };

  char riff[4];
  if (f.read((uint8_t*)riff, 4) != 4) return false;
  if (memcmp(riff, "RIFF", 4) != 0) return false;

  uint32_t riffSize;
  if (!rd32(riffSize)) return false;

  char wave[4];
  if (f.read((uint8_t*)wave, 4) != 4) return false;
  if (memcmp(wave, "WAVE", 4) != 0) return false;

  bool gotFmt = false;
  bool gotData = false;

  while (f.position() + 8 <= (size_t)f.size()) {
    char id[4];
    if (f.read((uint8_t*)id, 4) != 4) return false;
    uint32_t chunkSize;
    if (!rd32(chunkSize)) return false;

    uint32_t chunkStart = f.position();

    if (memcmp(id, "fmt ", 4) == 0) {
      uint16_t audioFormat;
      if (!rd16(audioFormat)) return false;
      if (!rd16(channels)) return false;
      if (!rd32(sampleRate)) return false;

      uint32_t byteRate;
      uint16_t blockAlign;
      if (!rd32(byteRate)) return false;
      if (!rd16(blockAlign)) return false;
      if (!rd16(bitsPerSample)) return false;

      if (chunkSize > 16) f.seek(chunkStart + chunkSize);

      if (audioFormat != 1) return false; // PCM only
      gotFmt = true;
    } else if (memcmp(id, "data", 4) == 0) {
      dataStart = f.position();
      dataSize = chunkSize;
      f.seek(dataStart);
      gotData = true;
      break;
    } else {
      f.seek(chunkStart + chunkSize);
    }
  }

  return gotFmt && gotData;
}

static void playWavFile(const char* path, int vol0_10) {
  i2sInitOnce();

  if (!LittleFS.exists(path)) {
    Serial.print("❌ WAV not found: ");
    Serial.println(path);
    return;
  }

  File f = LittleFS.open(path, "r");
  if (!f) {
    Serial.print("❌ Failed to open WAV: ");
    Serial.println(path);
    return;
  }

  uint32_t sampleRate = 0, dataStart = 0, dataSize = 0;
  uint16_t channels = 0, bits = 0;

  if (!readWavHeader(f, sampleRate, channels, bits, dataStart, dataSize)) {
    Serial.print("❌ Bad WAV header: ");
    Serial.println(path);
    f.close();
    return;
  }

  if (bits != 16 || channels != 1) {
    Serial.println("❌ Use 16-bit MONO PCM WAV.");
    f.close();
    return;
  }

  if (vol0_10 < 0) vol0_10 = 0;
  if (vol0_10 > 10) vol0_10 = 10;

  i2s_set_clk(I2S_NUM_0, sampleRate, I2S_BITS_PER_SAMPLE_16BIT, I2S_CHANNEL_STEREO);

  Serial.print("▶️ Playing ");
  Serial.print(path);
  Serial.print(" SR=");
  Serial.print(sampleRate);
  Serial.print(" vol=");
  Serial.println(vol0_10);

  const size_t INBUF = 1024;
  uint8_t in[INBUF];
  static int16_t out[INBUF];

  size_t bytesLeft = dataSize;
  audioStopFlag = false;

  while (bytesLeft > 0 && !audioStopFlag) {
    size_t toRead = (bytesLeft > INBUF) ? INBUF : bytesLeft;
    int r = f.read(in, toRead);
    if (r <= 0) break;
    bytesLeft -= (size_t)r;

    int outIdx = 0;
    for (int i = 0; i + 1 < r; i += 2) {
      int16_t s = (int16_t)(in[i] | (in[i + 1] << 8));
      s = applyVol(s, vol0_10);
      out[outIdx++] = s; // L
      out[outIdx++] = s; // R
    }

    size_t written = 0;
    i2s_write(I2S_NUM_0, (const char*)out, outIdx * sizeof(int16_t), &written, portMAX_DELAY);
  }

  f.close();
  i2s_zero_dma_buffer(I2S_NUM_0);

  if (audioStopFlag) Serial.println("⏹️ Audio stopped");
  else Serial.println("✅ Audio finished");
}

static void audioTask(void* pv) {
  (void)pv;
  AudioJob job{};
  for (;;) {
    if (xQueueReceive(audioQueue, &job, portMAX_DELAY) == pdTRUE) {
      if (job.stop) {
        audioStopFlag = true;
        continue;
      }
      playWavFile(job.file, job.volume);
    }
  }
}

static void requestPlay(const String& filePath, int vol0_10) {
  AudioJob j{};
  strncpy(j.file, filePath.c_str(), sizeof(j.file) - 1);
  j.volume = vol0_10;
  j.stop = false;
  xQueueSend(audioQueue, &j, 0);
}

static void requestStop() {
  AudioJob j{};
  j.stop = true;
  xQueueSend(audioQueue, &j, 0);
}

static void pollAudioFirebase() {
  if (!Firebase.ready()) return;

  unsigned long pollMs = audioActive ? AUDIO_POLL_MS_ACTIVE : AUDIO_POLL_MS_IDLE;
  if (millis() - lastAudioPoll < pollMs) return;
  lastAudioPoll = millis();

  if (Firebase.RTDB.getBool(&fbdo, FB_AUDIO_ACTIVE)) audioActive = fbdo.boolData();

  if (Firebase.RTDB.getInt(&fbdo, FB_AUDIO_VOLUME)) {
    int v = fbdo.intData();
    if (v < 0) v = 0;
    if (v > 10) v = 10;
    audioVolume = v;
  }

  if (!Firebase.RTDB.getString(&fbdo, FB_AUDIO_COMMAND)) return;
  String cmd = fbdo.stringData();
  cmd.trim();
  if (cmd.length() == 0) cmd = "NONE";

  if (cmd == "NONE") return;

  // Always reset so user can press again
  Firebase.RTDB.setString(&fbdo, FB_AUDIO_COMMAND, "NONE");

  if (cmd == "STOP") {
    requestStop();
    return;
  }

  if (cmd == "BEEP") {
    testBeep();
    return;
  }

  String base = String(FB_AUDIO_MESSAGES) + "/" + cmd;

  bool enabled = false;
  if (Firebase.RTDB.getBool(&fbdo, (base + "/enabled").c_str())) enabled = fbdo.boolData();
  if (!enabled) {
    Serial.println("Audio message disabled: " + cmd);
    return;
  }

  String filePath;
  if (Firebase.RTDB.getString(&fbdo, (base + "/file").c_str())) filePath = fbdo.stringData();
  filePath.trim();

  if (filePath.length() == 0) {
    Serial.println("Audio message empty file: " + cmd);
    return;
  }

  requestStop();
  vTaskDelay(pdMS_TO_TICKS(30));
  requestPlay(filePath, audioVolume);

  pushHistoryEventFirebase("play_audio", "Homeowner", "");
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

      Firebase.RTDB.setString(&fbdo, "/audio/command", "NONE");
      Firebase.RTDB.setBool(&fbdo, "/audio/active", false);
      if (!Firebase.RTDB.getInt(&fbdo, "/audio/volume")) Firebase.RTDB.setInt(&fbdo, "/audio/volume", 10);

      publishLanInfoFirebase(true);
    }

    if (Firebase.ready()) publishLanInfoFirebase(false);

    // ✅ log PIN lockout event (online)
    if (lockoutEventPending && Firebase.ready()) {
      lockoutEventPending = false;

      FirebaseJson j;
      j.set("attempts", (int)lockoutEventAttempts);
      j.set("duration_ms", (int)LOCKOUT_MS);
      j.set("ts/.sv", "timestamp");
      Firebase.RTDB.setJSON(&fbdo, "/security/lockout", &j);

      pushHistoryEventFirebase("pin_lockout", "Security", "");
      Serial.println("✅ Logged pin_lockout to Firebase history");
    }

    if (ringRequested) {
      ringRequested = false;
      ringInProgress = true;
      handleDoorbellEventFirebase();
      ringInProgress = false;
    }

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

    if (doorStatusDirty && Firebase.ready()) {
      doorStatusDirty = false;
      bool openLocal;
      xSemaphoreTake(doorMutex, portMAX_DELAY);
      openLocal = isDoorOpen;
      xSemaphoreGive(doorMutex);
      updateDoorStatusFirebase(openLocal ? "Open" : "Closed");
    }

    pollRemoteCommandFirebase();
    pollLiveSettingsFirebase();

    if (liveActive) pushLiveLatestSnapshotFirebase();

    maybeFetchAccessCodesSafelyFirebase();

    pollAudioFirebase();

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
  Serial.println();

  pinMode(LED_PIN, OUTPUT);
  digitalWrite(LED_PIN, LOW);

  pinMode(BUTTON_PIN, INPUT_PULLUP);
  attachInterrupt(digitalPinToInterrupt(BUTTON_PIN), onButtonFalling, FALLING);

  doorMutex = xSemaphoreCreateMutex();
  codesMutex = xSemaphoreCreateMutex();
  unlockQueue = xQueueCreate(8, sizeof(UnlockEvent));

  audioQueue = xQueueCreate(4, sizeof(AudioJob));
  xTaskCreatePinnedToCore(audioTask, "audioTask", 8192, nullptr, 1, &audioTaskHandle, 0);

  if (!LittleFS.begin(true)) {
    Serial.println("❌ LittleFS init failed");
  } else {
    Serial.println("✅ LittleFS ready");

    // list files
    File root = LittleFS.open("/");
    File file = root.openNextFile();
    while (file) {
      Serial.print(" - ");
      Serial.print(file.name());
      Serial.print(" (");
      Serial.print(file.size());
      Serial.println(" bytes)");
      file = root.openNextFile();
    }

    // ✅ offline: load last known codes
    loadCodesCacheFromFS();
  }

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
  setCameraProfileRing();

  // ---------------- WiFi (✅ timeout so we don't block offline mode)
  WiFi.begin(ssid, password);
  WiFi.setSleep(false);

  Serial.print("Connecting to WiFi");
  unsigned long wifiStart = millis();
  while (WiFi.status() != WL_CONNECTED && (millis() - wifiStart) < 15000) {
    delay(250);
    Serial.print(".");
  }

  if (WiFi.status() == WL_CONNECTED) {
    Serial.println("\nWiFi connected");
    Serial.print("IP Address: ");
    Serial.println(WiFi.localIP());

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

    doorStatusDirty = true;
    lastUserActionMs = millis();
    codesRefreshRequested = true; // refresh when idle

  } else {
    Serial.println("\n⚠️ WiFi NOT connected -> running OFFLINE MODE (keypad still works)");
    Serial.println("ℹ️ Will retry WiFi in loop()");
  }
}

// =====================================================
// Loop (FAST)
// =====================================================
String inputCode = "";

void loop() {
  // ✅ WiFi retry in background (offline mode)
  static unsigned long lastWiFiRetryMs = 0;
  if (WiFi.status() != WL_CONNECTED && (millis() - lastWiFiRetryMs) > 10000) {
    lastWiFiRetryMs = millis();
    Serial.println("🔄 Retrying WiFi...");
    WiFi.disconnect();
    WiFi.begin(ssid, password);
  }

  // 1) Handle doorbell button presses (ISR count)
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
      // offline feedback
      if (WiFi.status() != WL_CONNECTED) testBeep();
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

  // 3) Keypad read + Serial prints + lockout logic
  static unsigned long lastLockoutPrintMs = 0;

  char key;
  while ((key = keypad.getKey())) {
    lastUserActionMs = millis();

    Serial.print("Keypad pressed: ");
    Serial.println(key);

    // ✅ lockout active: disable PIN entry (allow '*' to clear buffer only)
    if (millis() < lockoutUntilMs) {
      if (millis() - lastLockoutPrintMs > 800) {
        lastLockoutPrintMs = millis();
        unsigned long left = (lockoutUntilMs - millis()) / 1000;
        Serial.print("⛔ Keypad LOCKED. Wait ");
        Serial.print(left);
        Serial.println("s");
      }

      if (key == '*') {
        inputCode = "";
        Serial.println("Entry cleared (*) while locked");
      }
      continue; // ignore all other keys during lockout
    }

    if (key == '#') {
      Serial.print("Entered code: ");
      Serial.println(inputCode);

      //if (inputCode.length() < 4) {
       // Serial.println("Too short ❌");
       // wrongAttempts++;
       // blinkErrorLocal();
       // inputCode = "";
       // break;
     // }

      // Ask Firebase to refresh later when online (doesn't block offline)
      if (millis() - lastCodesFetchMs > CODES_MAX_AGE_BEFORE_UNLOCK_MS) {
        codesRefreshRequested = true;
      }

      if (codeExistsInCache(inputCode)) {
        Serial.println("ACCESS GRANTED ✅");
        wrongAttempts = 0; // ✅ reset failures on success

        String userName = getUserNameFromCache(inputCode);
        unlockDoorLocal();

        UnlockEvent ev{};
        strncpy(ev.code, inputCode.c_str(), sizeof(ev.code) - 1);
        strncpy(ev.user, userName.c_str(), sizeof(ev.user) - 1);
        ev.isOtp = (userName == "OTP_Visitor");
        xQueueSend(unlockQueue, &ev, 0);

      } else {
        // if (inputCode.length() < 4) 
        Serial.println("Too short ❌");
        Serial.println("ACCESS DENIED ❌");
        blinkErrorLocal();

        wrongAttempts++;
        Serial.print("Wrong attempts: ");
        Serial.println(wrongAttempts);

        if (wrongAttempts >= MAX_WRONG_ATTEMPTS) {
          wrongAttempts = 0;
          lockoutUntilMs = millis() + LOCKOUT_MS;

          Serial.println("⛔ LOCKOUT TRIGGERED (1 minute)");

          // mark event for Firebase task to log when online
          lockoutEventPending = true;
          lockoutEventAttempts = MAX_WRONG_ATTEMPTS;

          // extra feedback
          testBeep();
        }
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

    // digits
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
