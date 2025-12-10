#include <WiFi.h>
#include <Firebase_ESP_Client.h>
#include <Keypad.h>
#include "addons/TokenHelper.h"
#include "addons/RTDBHelper.h"

// ==========================================
// 1. CREDENTIALS
// ==========================================
#define WIFI_SSID "ICST"
#define WIFI_PASSWORD "arduino123"

#define API_KEY "AIzaSyAZZFAOF2lEXONTwvi1iNaMZvJiPETzlpE"
#define DATABASE_URL "iot15-46c28-default-rtdb.firebaseio.com"

// ==========================================
// 2. KEYPAD SETUP
// ==========================================
#define ROWS 3
#define COLS 4
char keys[ROWS][COLS] = {
  {'9','6','3','#'},
  {'8','5','2','0'},
  {'7','4','1','*'},
};
byte rowPins[ROWS] = {32, 13, 12};
byte colPins[COLS] = {26, 25, 33, 27};
Keypad keypad = Keypad(makeKeymap(keys), rowPins, colPins, ROWS, COLS);

// ==========================================
// 3. HARDWARE & VARIABLES
// ==========================================
#define LED_PIN 5 

FirebaseData fbdo;
FirebaseAuth auth;
FirebaseConfig config;

String validCodesJson = ""; 
String inputCode = "";      
unsigned long lastCheckTime = 0; 
bool isDoorOpen = false;           
unsigned long doorOpenTime = 0;    
const unsigned long AUTO_LOCK_DELAY = 60000; // 1 Minute

void setup() {
  Serial.begin(115200);
  pinMode(LED_PIN, OUTPUT);
  digitalWrite(LED_PIN, LOW); 

  // --- A. Connect to WiFi ---
  Serial.print("Connecting to WiFi");
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  while (WiFi.status() != WL_CONNECTED) {
    Serial.print(".");
    delay(300);
  }
  Serial.println("\nWiFi Connected!");
  Serial.print("IP Address: ");
  Serial.println(WiFi.localIP());

  // --- B. Connect to Firebase (MATCHING YOUR WORKING CODE) ---
  // I REMOVED the "Time Hack" here because it caused your crash.
  
  config.api_key = API_KEY;
  config.database_url = DATABASE_URL;
  config.signer.test_mode = true;
  
  // This is the setting that made it work for you before:
  fbdo.setBSSLBufferSize(4096, 1024); 
  config.timeout.serverResponse = 10000;
  
  Firebase.begin(&config, &auth);
  Firebase.reconnectWiFi(true);

  // --- C. Initial Setup ---
  updateDoorStatus("Closed"); 
  fetchAccessCodes();         
}

void loop() {
  // 1. Read Keypad
  char key = keypad.getKey();
  if (key) {
    Serial.print("Pressed: "); Serial.println(key);
    
    if (key == '#') { 
      checkAccess(); 
      inputCode = ""; 
    } 
    else if (key == '*') { 
      if (isDoorOpen) lockDoor(); // Manual Lock
      inputCode = ""; 
      Serial.println("Entry cleared!");
    } 
    else { 
      inputCode += key; 
    }
  }

  // 2. Refresh Codes every 30s
  if (millis() - lastCheckTime > 30000) {
    fetchAccessCodes();
    lastCheckTime = millis();
  }

  // 3. Auto-Relock
  if (isDoorOpen && (millis() - doorOpenTime >= AUTO_LOCK_DELAY)) {
    Serial.println("Auto-Relock triggered.");
    lockDoor();
  }
}

// ==========================================
// LOGIC FUNCTIONS
// ==========================================

void unlockDoor() {
  digitalWrite(LED_PIN, HIGH);
  isDoorOpen = true;
  doorOpenTime = millis();
  updateDoorStatus("Open"); // Updates App Light to ON
}

void lockDoor() {
  digitalWrite(LED_PIN, LOW);
  isDoorOpen = false;
  updateDoorStatus("Closed"); // Updates App Light to OFF
}

void updateDoorStatus(String status) {
  if (Firebase.ready()) {
    Firebase.RTDB.setString(&fbdo, "/door_status", status);
  }
}

void fetchAccessCodes() {
  if (Firebase.ready()) {
    Serial.print("Updating codes... ");
    // Reads "/access_codes" (Where App saves users)
    if (Firebase.RTDB.getJSON(&fbdo, "/access_codes")) {
      validCodesJson = fbdo.jsonString(); 
      Serial.println("Success! List: " + validCodesJson);
    } else {
      Serial.println("Failed: " + fbdo.errorReason());
    }
  }
}

void checkAccess() {
  Serial.print("Checking: " + inputCode);

  if (inputCode.length() < 4) {
    Serial.println(" -> Too short");
    blinkError();
    return;
  }

  // Search logic: We search for the code WITH QUOTES "\"1234\""
  if (validCodesJson.indexOf("\"" + inputCode + "\"") >= 0) {
    Serial.println(" -> ACCESS GRANTED!");
    
    // 1. Log History & Handle OTP
    logHistory(inputCode);
    
    // 2. Open Door
    unlockDoor();
    
  } else {
    Serial.println(" -> ACCESS DENIED.");
    blinkError();
  }
}

void logHistory(String code) {
  // 1. Get the Name associated with this code
  String namePath = "/access_codes/" + code;
  String userName = "Unknown";
  
  if (Firebase.RTDB.getString(&fbdo, namePath)) {
    userName = fbdo.stringData();
  }
  
  // 2. Write to History Log
  String timestamp = String(millis()); 
  String logEntry = "Door opened by " + userName;
  Firebase.RTDB.setString(&fbdo, "/history/" + timestamp, logEntry);
  
  // 3. ONE-TIME CODE DELETION
  if (userName == "OTP_Visitor") {
    Serial.println("One-Time Code used. Deleting...");
    Firebase.RTDB.deleteNode(&fbdo, namePath);
    fetchAccessCodes(); // Refresh list immediately
  }
}

void blinkError() {
  for(int i=0; i<3; i++) { digitalWrite(LED_PIN, HIGH); delay(100); digitalWrite(LED_PIN, LOW); delay(100); }
}