# Waveshare ESP32-S3-Touch-LCD-3.49B hardware contract

This document records the hardware contract used by the stable 3.49B V2 port.
The 3.49B name describes the Case B enclosure and battery option; it does not
identify the PCB revision. Remaining work is tracked in the
[active TODO](../../../TODO.md), and completed port evidence is retained in the
[development history](../DEVELOPMENT-HISTORY.md).

## Physical revision gate

Waveshare discontinued V1 and changed shipments to V2 after 2026-06-08. The
two revisions are not firmware-compatible because the LCD reset, TE,
backlight, and expander-interrupt assignments changed.

Before enabling or flashing a physical DMDClock image, record both:

1. The PCB silkscreen. Waveshare identifies V2 by `Rev1.1`.
2. The enclosure QC sticker. Waveshare identifies V2 with a `V2` sticker.

The release flasher requires the V2 / Rev1.1 confirmation and refuses to offer
this firmware for V1 hardware.

## Common contract

| Property | Official value |
| --- | --- |
| Product | ESP32-S3-Touch-LCD-3.49B, Case B, SKU 32375 |
| MCU | ESP32-S3R8, dual-core up to 240 MHz |
| Flash | 16 MB external W25Q128JVSI |
| PSRAM | 8 MB in-package octal PSRAM |
| LCD | 3.49-inch IPS, native 172x640, AXS15231B |
| LCD bus | QSPI mode 3, 40 MHz, GPIO 9-14 |
| Pixel format | RGB565, RGB element order, 16 bits per pixel |
| Touch | AXS15231B I2C at address `0x3b`, 300 kHz |
| Touch bus | SDA GPIO 17, SCL GPIO 18 |
| microSD card | Native one-bit SDMMC: CMD 39, D0 40, CLK 41; D3/CD 38 is unused in one-bit mode |
| Flash/log interface | ESP32-S3 native USB through the Type-C connector |

The official example renders in portrait native coordinates (`172x640`). Its
touch transform is `landscape_x = native_y` and
`landscape_y = 640 - native_x`. DMDClock must validate endpoint handling on
the physical panel before reusing that transform.

## Revision differences

| Signal | V1 | V2 (`Rev1.1`) |
| --- | --- | --- |
| LCD reset | GPIO 21 | TCA9554 P5 |
| LCD TE | Not used by example | GPIO 21 |
| Backlight PWM | GPIO 8 | GPIO 42, active low (`0` is full brightness) |
| Backlight enable | Direct PWM path | TCA9554 P1, active high |
| Expander interrupt | Not used by example | GPIO 8 |
| Touch interrupt | Not exposed to example | TCA9554 P0 input |

Both official factory examples use QSPI CS 9, clock 10, data 0-3 on GPIO
11-14, a 40 MHz pixel clock, 32 command bits, 8 parameter bits, and quad mode.
They reset the LCD high for 30 ms, low for 250 ms, then high for 30 ms before
panel initialization. Their extra initialization commands are sleep-out
`0x11` and display-on `0x29`, each followed by 100 ms; the AXS15231B component
provides its controller initialization table.

## Official artifacts

The evidence was inspected from these official repositories on 2026-08-12:

| Revision | Repository commit | Factory image | SHA-256 |
| --- | --- | --- | --- |
| V1 | `def6edd0b6e1925ed09702eed01a2f181afdf8c1` | `ESP32-S3-Touch-LCD-3.49-FactoryProgram.bin` (2,813,728 bytes) | `921C41A413E75DCE5F0DA4954023864C21E159B16BF3B36311823ACD9B96E4DC` |
| V2 | `1c157e6e8e68b89fd4dc400f46bf1724cb64a57e` | `ESP32-S3-Touch-LCD-3.49-V2.bin` (2,813,008 bytes) | `1D1F84C766E720F344FAF59D1E6C95846DF1A26DA4C1E6D6094F9095F6B68312` |

- V1 example: <https://github.com/waveshareteam/ESP32-S3-Touch-LCD-3.49>
- V2 example and schematic: <https://github.com/waveshareteam/ESP32-S3-Touch-LCD-3.49-V2>
- Waveshare resources: <https://docs.waveshare.com/ESP32-S3-Touch-LCD-3.49/Resources-And-Documents>
- Waveshare flashing instructions: <https://docs.waveshare.com/ESP32-S3-Touch-LCD-3.49/Firmware-Flashing>

## Recovery gate

Use only the factory image matching the confirmed PCB revision. The official
image is flashed at address `0x0`. Enter download mode by holding BOOT and
pressing RESET (or power-cycling while BOOT is held if synchronization fails),
then flash through the Type-C USB port. After reset, exercise the factory test
for the LCD, touch, microSD card, and other onboard devices.

P4 is complete only after the matching image hash has been rechecked and this
recovery has succeeded on the actual 3.49B board. Research and a compilable
driver are not substitutes for that physical proof.
