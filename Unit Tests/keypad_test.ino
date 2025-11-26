#include <Keypad.h>

// Rows & columns count
const byte ROWS = 3;
const byte COLS = 4;

// Keypad layout
char keys[ROWS][COLS] = {
  {'9','6','3','#'},
  {'8','5','2','0'},
  {'7','4','1','*'},
};


// Safe ESP32-S3 pins
byte rowPins[ROWS] = {
  32, // Row 0 : 1 2 3
  13, // Row 1 : 4 5 6
  12, // Row 2 : 7 8 9  // Row 3 : * 0 #
};

byte colPins[COLS] = {
  26, // Col 0 (1,4,7,*)
  25, // Col 1 (2,5,8,0)
  33, // Col 2 (3,6,9,#)
  27
};

// Create keypad
Keypad keypad = Keypad(makeKeymap(keys), rowPins, colPins, ROWS, COLS);

void setup() {
  Serial.begin(115200);
  Serial.println("3x4 Keypad Test Started...");
}

void loop() {
  char key = keypad.getKey();

  if (key) {
    Serial.print("Pressed: ");
    Serial.println(key);
  }
}