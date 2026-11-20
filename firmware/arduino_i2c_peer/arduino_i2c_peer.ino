
#include <Wire.h>
#include <util/atomic.h>

const uint8_t I2C_ADDRESS = 0x42;  
const uint8_t INITIAL_REPLY = 42;
volatile uint8_t replyByte = INITIAL_REPLY;
volatile uint8_t receivedByte = 0;
volatile uint8_t requestedByte = 0;
volatile bool receivedPending = false;
volatile bool requestedPending = false;
volatile bool badLengthPending = false;

void receiveFromFpga(int byteCount) {
  if (byteCount == 1 && Wire.available()) {
    receivedByte = static_cast<uint8_t>(Wire.read());
    receivedPending = true;
  } else {
    badLengthPending = true;
  }
  while (Wire.available()) (void)Wire.read();
}

void replyToFpga() {

  const uint8_t snapshot = replyByte;
  Wire.write(snapshot);
  requestedByte = snapshot;
  requestedPending = true;
}

void setup() {
  Serial.begin(115200);
  Wire.onReceive(receiveFromFpga);
  Wire.onRequest(replyToFpga);
  Wire.begin(I2C_ADDRESS);
  // disable internal 5 V pull-ups, external 10k on the level shifter
  digitalWrite(SDA, LOW);
  digitalWrite(SCL, LOW);
  Serial.println(F("Uno I2C ready at address 0x42. Initial reply: 42."));
  Serial.println(F("Enter decimal 0..255 and press Send (Newline, 115200 baud)."));
  Serial.println(F("FPGA SW9 OFF=read reply; ON=write switches; every 5 seconds."));
}

void loop() {
  bool gotWrite, gotRequest, badLength;
  uint8_t rx, offered;
  ATOMIC_BLOCK(ATOMIC_RESTORESTATE) {
    gotWrite = receivedPending;
    gotRequest = requestedPending;
    badLength = badLengthPending;
    rx = receivedByte;
    offered = requestedByte;
    receivedPending = false;
    requestedPending = false;
    badLengthPending = false;
  }
  if (gotWrite) {
    Serial.print(F("FPGA -> Arduino: "));
    Serial.println(rx);
  }
  if (gotRequest) {
    Serial.print(F("FPGA requested a byte; Arduino offered: "));
    Serial.println(offered);
  }
  if (badLength) Serial.println(F("Unexpected I2C write length; expected 1 byte."));

  static uint16_t entered = 0;
  static uint8_t digits = 0;
  static bool lineStarted = false;
  static bool invalidLine = false;
  while (Serial.available() > 0) {
    const char c = static_cast<char>(Serial.read());
    if (c == '\n' || c == '\r') {
      if (lineStarted) {
        if (!invalidLine && digits > 0 && entered <= 255) {
          const uint8_t nextReply = static_cast<uint8_t>(entered);
          ATOMIC_BLOCK(ATOMIC_RESTORESTATE) { replyByte = nextReply; }
          Serial.print(F("Stored reply: "));
          Serial.print(nextReply);
          Serial.println(F(" (used on the next FPGA read)."));
        } else {
          Serial.println(F("Use decimal digits only, 0..255. Reply unchanged."));
        }
      }
      entered = 0;
      digits = 0;
      lineStarted = false;
      invalidLine = false;
    } else {
      lineStarted = true;
      if (c >= '0' && c <= '9' && digits < 3) {
        entered = static_cast<uint16_t>(entered * 10u + static_cast<uint8_t>(c - '0'));
        ++digits;
        if (entered > 255) invalidLine = true;
      } else {
        invalidLine = true;
      }
    }
  }
}
