# FPGA to Arduino I2C Link

DE10-Lite FPGA (I2C controller) talking to an Arduino Uno (peripheral at address 0x42) through a BS170 MOSFET level shifter. The FPGA reads or writes one byte every 5 seconds and shows the received value on the LEDs and 7-segment displays.

The I2C core is the same one from [fpga-i2c-accelerometer](https://github.com/ANaceri26/fpga-i2c-accelerometer).

## Files

- `board/arduino_i2c/de10_arduino_i2c_top.sv`: transaction scheduler, switch synchronizer, binary-to-BCD display
- `rtl/i2c_controller.sv`: I2C controller
- `firmware/arduino_i2c_peer/arduino_i2c_peer.ino`: Uno sketch. Type 0-255 in Serial Monitor (115200) to set the reply byte
- `scripts/check_quartus_pin_report.py`: checks a fitted `.pin` report against the intended pinout

## Wiring

| Signal | DE10-Lite | FPGA pin | Uno |
|---|---|---|---|
| SDA | Arduino header IO14 | AB21 | A4 |
| SCL | Arduino header IO15 | AA20 | A5 |
| GND | GND | | GND |

Level shifter on each line:

```
DE10 3.3V --10k--+-- S [BS170] D --+--10k-- Uno 5V
                 |       G         |
           FPGA IO14/15  DE10 3.3V  Uno A4/A5
```

The sketch disables the Uno's internal pull-ups. Bus speed is about 10 kHz.

## Controls

| Control | Function |
|---|---|
| SW9 down | read a byte from the Uno every 5 s |
| SW9 up | write SW[7:0] to the Uno every 5 s |
| KEY0 | reset |
| LEDR[7:0], HEX2-HEX0 | last byte read (binary and decimal) |
| LEDR9 | last transfer succeeded |
| LEDR8 | flashing = error |

## Build

1. Upload the sketch to the Uno.
2. Open `board/arduino_i2c/de10_arduino_i2c.qpf` in Quartus (device 10M50DAF484C7G) and compile.
3. Optional: `python scripts/check_quartus_pin_report.py board/arduino_i2c/output_files/de10_arduino_i2c.pin`
4. Program the `.sof` with the Quartus Programmer.

## Debug note

The first hardware build didn't work. The fit report showed Quartus had ignored all 72 pin assignments because the QSF wrapped target names in braces (`-to {MAX10_CLK1_50}`), so the fitter placed every pin on its own. Removing the braces fixed the assignments, and the pin-report checker was added so this gets caught before programming the board.

## Checks

Uno sketch compiles (4,076 B flash, 384 B RAM). SystemVerilog elaborates with no errors or warnings. All 72 pins were checked against the DE10-Lite manual. Logs are in `results/`.
