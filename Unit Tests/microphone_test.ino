#include <Arduino.h>
#include "driver/i2s.h"

// ---- I2S pin mapping (MUST match wiring) ----
#define I2S_WS      15    // INMP441 WS
#define I2S_SCK     14    // INMP441 SCK (BCLK)
#define I2S_SD      32    // INMP441 SD  (data out)

#define I2S_PORT    I2S_NUM_0
#define SAMPLE_RATE 16000      // 16 kHz

// Software gain (you can increase if needed)
#define GAIN_FACTOR 16

void setupI2SMic() {
  i2s_config_t config = {
    .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
    .sample_rate = SAMPLE_RATE,
    .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
    // Read BOTH channels so we don't care if mic is Left or Right
    .channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT,
    .communication_format = I2S_COMM_FORMAT_I2S,
    .intr_alloc_flags = 0,
    .dma_buf_count = 4,
    .dma_buf_len = 256,
    .use_apll = false,
    .tx_desc_auto_clear = false,
    .fixed_mclk = -1
  };

  i2s_pin_config_t pin_config = {
    .bck_io_num   = I2S_SCK,
    .ws_io_num    = I2S_WS,
    .data_out_num = I2S_PIN_NO_CHANGE,
    .data_in_num  = I2S_SD
  };

  i2s_driver_install(I2S_PORT, &config, 0, NULL);
  i2s_set_pin(I2S_PORT, &pin_config);
  i2s_zero_dma_buffer(I2S_PORT);
}

void setup() {
  Serial.begin(115200);
  Serial.println("INMP441 dual-channel high-sensitivity test");
  setupI2SMic();
}

void loop() {
  const int N = 256;
  int32_t buffer[N];
  size_t bytes_read = 0;

  i2s_read(I2S_PORT, (void*)buffer, sizeof(buffer), &bytes_read, portMAX_DELAY);

  int samples = bytes_read / sizeof(int32_t);
  if (samples < 2) return;

  int32_t maxLeft  = 0;
  int32_t maxRight = 0;

  // Data order with I2S_CHANNEL_FMT_RIGHT_LEFT is: R, L, R, L, ...
  for (int i = 0; i < samples - 1; i += 2) {
    int32_t sR = buffer[i];     // Right
    int32_t sL = buffer[i + 1]; // Left

    // 24-bit data left-justified in 32 bits – keep as is (no >> shift)
    if (sL < 0) sL = -sL;
    if (sR < 0) sR = -sR;

    // apply software gain
    sL *= GAIN_FACTOR;
    sR *= GAIN_FACTOR;

    if (sL > maxLeft)  maxLeft  = sL;
    if (sR > maxRight) maxRight = sR;
  }

  Serial.print("L=");
  Serial.print(maxLeft);
  Serial.print("   R=");
  Serial.print(maxRight);
  Serial.print("   |L:");

  int levelL = maxLeft / 50000;   // tune this divisor if needed
  int levelR = maxRight / 50000;
  if (levelL > 40) levelL = 40;
  if (levelR > 40) levelR = 40;

  for (int i = 0; i < levelL; i++) Serial.print('#');
  Serial.print("  R:");
  for (int i = 0; i < levelR; i++) Serial.print('#');
  Serial.println();

  delay(80);
}
