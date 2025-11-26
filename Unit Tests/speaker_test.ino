#include <Arduino.h>
#include "driver/i2s.h"

// -------- I2S pin mapping --------
#define I2S_BCLK 26   // MAX98357A BCLK
#define I2S_LRC  25   // MAX98357A LRC (LRCLK)
#define I2S_DOUT 22   // MAX98357A DIN

// -------- I2S configuration --------
#define SAMPLE_RATE 44100
#define TONE_FREQ   440.0   // 440 Hz = musical A

// I2S port
#define I2S_PORT I2S_NUM_0

void setupI2S() {
  i2s_config_t i2s_config = {
    .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_TX),
    .sample_rate = SAMPLE_RATE,
    .bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT,
    .channel_format = I2S_CHANNEL_FMT_ONLY_LEFT,
    .communication_format = I2S_COMM_FORMAT_STAND_MSB,
    .intr_alloc_flags = 0,          // default interrupt priority
    .dma_buf_count = 8,
    .dma_buf_len = 64,
    .use_apll = false,
    .tx_desc_auto_clear = true,
    .fixed_mclk = -1
  };

  i2s_pin_config_t pin_config = {
    .bck_io_num = I2S_BCLK,
    .ws_io_num = I2S_LRC,
    .data_out_num = I2S_DOUT,
    .data_in_num = I2S_PIN_NO_CHANGE
  };

  // Install and start I2S driver
  i2s_driver_install(I2S_PORT, &i2s_config, 0, NULL);
  i2s_set_pin(I2S_PORT, &pin_config);
  i2s_zero_dma_buffer(I2S_PORT);
}

void setup() {
  Serial.begin(115200);
  Serial.println("MAX98357A test – should hear a continuous 440 Hz tone.");
  setupI2S();
}

void loop() {
  // Generate a short buffer of a sine wave and send it repeatedly
  static const int BUF_LEN = 256;
  static int16_t buffer[BUF_LEN];

  static float phase = 0.0;
  const float phase_inc = 2.0 * PI * TONE_FREQ / SAMPLE_RATE;

  for (int i = 0; i < BUF_LEN; i++) {
    float sample = sin(phase);
    phase += phase_inc;
    if (phase >= 2.0 * PI) phase -= 2.0 * PI;

    // convert to 16-bit signed sample
    buffer[i] = (int16_t)(sample * 30000);
  }

  size_t bytes_written;
  i2s_write(I2S_PORT, (const char *)buffer, sizeof(buffer), &bytes_written, portMAX_DELAY);
}
