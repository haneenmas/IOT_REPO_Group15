## Smart Doorbell Project by :  
**Group 15 (ICST – Technion)**

## Details about the project
A smart doorbell system using **ESP32-S3-CAM + Firebase Realtime Database + Flutter app**.  
The system supports **snapshot-on-ring**, **semi-live remote view via Firebase snapshots**, **LAN streaming when near the device**, **secure keypad access with offline cache**, **remote unlock**, **event history + notifications**, and **pre-recorded voice messages** played at the door (MAX98357A + I2S + WAV on LittleFS).

> ✅ Implemented: 1,2,3,4,5,6,9,10,11,12  
> ⏳ Not implemented yet: 7,8,13,14

---

## Folder description :
* **ESP32/**: source code for the ESP32-S3-CAM firmware (camera + keypad + Firebase + audio + offline cache).
* **Documentation/**: wiring diagram + basic operating instructions.
* **Unit Tests/**: tests for individual hardware components (input/output devices).
* **flutter_app/**: Dart code for the Flutter mobile app.
* **Parameters/**: description of parameters and settings that can be modified **in code**.
* **Assets/**: link to 3D printed parts, audio files used in this project, Fritzing connection file (FZZ), etc.

---

## ESP32 SDK version used in this project:
* Arduino ESP32 Core: **2.0.17** (ESP32-S3 on Mac Apple Silicon)

---

## Arduino/ESP32 libraries used in this project:
* **Firebase ESP Client** (Firebase_ESP_Client)
* **Keypad** library
* **esp_camera** (ESP32 camera driver)
* **LittleFS** (FS storage)
* **mbedtls/base64** (image encoding)
* **FreeRTOS** (tasks/queues/semaphores)
* **I2S driver** (MAX98357A audio output)

---

## Connection diagram:
See: `Documentation/` (Fritzing + wiring diagrams)

---

## Project Poster:
See: `Documentation/` (IOT Poster)

---

This project is part of **ICST - The Interdisciplinary Center for Smart Technologies**,  
Taub Faculty of Computer Science, Technion  
https://icst.cs.technion.ac.il/

---

# User stories

| # | so that | I want | as a | story name | Status |
|---|--------|--------|------|-----------|--------|
| 1 | I can immediately recognize who is at the door | the system to capture and show me a photo/short clip when someone presses the bell | Homeowner | Snapshot on Doorbell Press | ✅ Done |
| 2 | I can check my entrance whenever I’m away | to start a live view of my door from outside my home network | Homeowner | Watch Live From Anywhere | ✅ Done (semi-live snapshots via Firebase) |
| 3 | Trusted visitors can enter once without permanent access | to create a single-use access code for a specific time window | Homeowner | One-Time Access Code | ✅ Done |
| 4 | I can review what happened if I missed an alert | door events to be saved with their audio/video for later viewing | Homeowner | Event History with Media | ✅ Done (history + snapshot keys) |
| 5 | I can let trusted people in even when I’m not home | to unlock the door from the app after I verify the visitor | Homeowner | Remote Unlock | ✅ Done |
| 6 | I can guide visitors when I’m busy or can’t answer | to play a preset voice note at the door (e.g., “Leave the package”) | Homeowner | Play Pre-Recorded Message | ✅ Done (I2S + LittleFS WAV + Firebase commands) |
| 7 | I can control who can enter and when | to add users, set roles, and define when each one may unlock | Homeowner | Web & Mobile Access with History | ⏳ Not done |
| 8 | someone in the house will respond quickly even if one person is busy | doorbell calls to notify multiple recipients (app/web) with escalation if the first doesn’t answer | Household member | Multi-Resident Call Routing | ⏳ Not done |
| 9 | the door isn’t accidentally left unlocked after deliveries or visitors | the door to automatically re-lock after a configurable time following a remote unlock | Homeowner | Auto-Relock Safety Timeout | ✅ Done |
| 10 | I can detect suspicious attempts and keep my door access secure | the system to notify me when someone enters an incorrect one-time access code and to play beeping | Homeowner | Failed Access Attempt Alert | ✅ Done (beep + history logging hooks) |
| 11 | I can still get basic operation like keys saved locally | the doorbell to still function when there is no Wi-Fi or internet (basic functionalities) | Homeowner | Offline Mode | ✅ Done (LittleFS cached codes + local unlock) |
| 12 | brute-force guessing is discouraged and I’m alerted to suspicious activity | the lockpad to disable PIN entry for 2 minutes after 5 consecutive wrong attempts and log the event | Homeowner | PIN Lockout After 5 Failures | ✅ Done |
| 13 | make a conversation | to talk with the person at the other side of the door | Homeowner | Two-Way Talk |  ✅ Done |
| 14 | snapshots and live video are clear at night without extra IR LEDs | camera auto increases brightness during time range (e.g., 7 PM–6 AM) according to light sensor | Homeowner | Night-Time Auto Brightness |  ✅ Done |

