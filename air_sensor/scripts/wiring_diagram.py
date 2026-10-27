#!/usr/bin/env python3
"""Draw air_sensor/wiring_diagram.pdf from the pin map in HardwareConfig.h.

Usage: python3 air_sensor/scripts/wiring_diagram.py [output.pdf]
Coordinates are pixels on an A4 landscape page at 110 dpi, y pointing down.
"""
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages
from matplotlib.patches import Circle, FancyBboxPatch, Polygon

W, H = 1286, 910
FIRMWARE = "1.1.0"

INK = "#222222"
GREY = "#555555"
SUPPLY = "#d0202a"
RX = "#1f6fd0"
TX = "#1e7d32"
ANALOG = "#b8860b"
OUT = "#7b4fd6"
I2C = "#0e9aa7"
BOX = "#f6f7f9"
ESP = "#edf3fd"


def page():
    fig = plt.figure(figsize=(841.68 / 72, 595.44 / 72))
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, W)
    ax.set_ylim(H, 0)
    ax.axis("off")
    return fig, ax


def text(ax, x, y, s, size=7, color=INK, ha="left", va="center", weight="normal", style="normal"):
    ax.text(x, y, s, fontsize=size, color=color, ha=ha, va=va, fontweight=weight, fontstyle=style)


def line(ax, pts, color=INK, lw=1.3):
    xs, ys = zip(*pts)
    ax.plot(xs, ys, color=color, lw=lw, solid_capstyle="butt")


def dot(ax, x, y, color=INK, size=3.2):
    ax.plot(x, y, "o", color=color, ms=size)


def box(ax, x0, y0, x1, y1, fill=BOX, lw=1.2):
    ax.add_patch(FancyBboxPatch((x0, y0), x1 - x0, y1 - y0, boxstyle="round,pad=0,rounding_size=7",
                                fc=fill, ec=INK, lw=lw))


def resistor_h(ax, x0, x1, y, color, peaks=6, amp=5):
    lead = (x1 - x0) * 0.08
    a, b = x0 + lead, x1 - lead
    step = (b - a) / (peaks * 2)
    pts = [(x0, y), (a, y)]
    for i in range(peaks * 2):
        pts.append((a + step * (i + 0.5), y + (-amp if i % 2 == 0 else amp)))
    pts += [(b, y), (x1, y)]
    line(ax, pts, color)


def resistor_v(ax, x, y0, y1, color, peaks=4, amp=5):
    lead = (y1 - y0) * 0.12
    a, b = y0 + lead, y1 - lead
    step = (b - a) / (peaks * 2)
    pts = [(x, y0), (x, a)]
    for i in range(peaks * 2):
        pts.append((x + (amp if i % 2 == 0 else -amp), a + step * (i + 0.5)))
    pts += [(x, b), (x, y1)]
    line(ax, pts, color)


def ground_side(ax, x, y):
    """Ground at the end of a horizontal stub ending at x."""
    for dx, half in ((0, 10), (4, 6.5), (8, 3)):
        line(ax, [(x + dx, y - half), (x + dx, y + half)], INK, 1.4)


def ground_down(ax, x, y):
    """Ground at the bottom of a vertical stub ending at y."""
    for dy, half in ((0, 11), (4, 7), (8, 3)):
        line(ax, [(x - half, y + dy), (x + half, y + dy)], INK, 1.4)


def arrow(ax, x, y, color, right=True):
    ax.plot(x, y, ">" if right else "<", color=color, ms=4.5)


# ---------------------------------------------------------------- page 1

ESP_L, ESP_R = 571, 770
SENSOR_L, SENSOR_R = 78, 294


def sensor(ax, y0, y1, title, subtitle, pins):
    box(ax, SENSOR_L, y0, SENSOR_R, y1)
    text(ax, (SENSOR_L + SENSOR_R) / 2, y0 + 16, title, 10, weight="bold", ha="center")
    text(ax, (SENSOR_L + SENSOR_R) / 2, y0 + 36, subtitle, 6, GREY, ha="center")
    for y, label in pins:
        text(ax, SENSOR_R - 9, y, label, 7, ha="right")
        dot(ax, SENSOR_R, y)


def supply(ax, y):
    line(ax, [(SENSOR_R, y), (330, y)], SUPPLY)
    text(ax, 333, y, "+5V", 6.5, SUPPLY, weight="bold")


def gnd(ax, y):
    line(ax, [(SENSOR_R, y), (328, y)], INK)
    ground_side(ax, 328, y)


def uart(ax, y_tx, y_rx, rx_label, tx_label):
    line(ax, [(SENSOR_R, y_tx), (ESP_L, y_tx)], RX)
    arrow(ax, 503, y_tx, RX, right=True)
    line(ax, [(SENSOR_R, y_rx), (ESP_L, y_rx)], TX)
    arrow(ax, 345, y_rx, TX, right=False)
    for y, label in ((y_tx, rx_label), (y_rx, tx_label)):
        dot(ax, ESP_L, y)
        text(ax, ESP_L + 9, y, label, 7)


def esp_right_pin(ax, y, label):
    dot(ax, ESP_R, y)
    text(ax, ESP_R - 9, y, label, 7, ha="right")


def draw_page1(ax):
    text(ax, 51, 35, "Canary air sensor — wiring diagram", 15, weight="bold")
    text(ax, 51, 64, f"ESP32-S3-DevKitC-1 · firmware {FIRMWARE} · pin map from air_sensor/HardwareConfig.h", 8, GREY)

    # ESP32-S3
    box(ax, ESP_L, 130, ESP_R, 860, fill=ESP)
    text(ax, (ESP_L + ESP_R) / 2, 146, "ESP32-S3", 10.5, weight="bold", ha="center")
    text(ax, (ESP_L + ESP_R) / 2, 165, "DevKitC-1", 6, GREY, ha="center")

    # Sensors on the left
    sensor(ax, 147, 294, "Winsen ZE03-CO", "carbon monoxide · UART 9600 8N1",
           [(206, "VIN 5V"), (230, "GND"), (254, "TX"), (278, "RX")])
    supply(ax, 206); gnd(ax, 230)
    uart(ax, 254, 278, "GPIO17  (RX0)", "GPIO18  (TX0)")

    sensor(ax, 320, 467, "HLK-LD2410", "presence radar · UART 256000 8N1",
           [(380, "VCC 5V"), (403, "GND"), (427, "TX/OT1"), (451, "RX")])
    supply(ax, 380); gnd(ax, 403)
    uart(ax, 427, 451, "GPIO15  (RX1)", "GPIO16  (TX1)")

    sensor(ax, 493, 640, "Plantower PMS5003T", "PM + temp/RH · UART 9600 8N1",
           [(553, "VCC 5V (pin 1)"), (577, "GND (pin 2)"), (601, "TX (pin 5)"), (625, "RX (pin 4)")])
    supply(ax, 553); gnd(ax, 577)
    uart(ax, 601, 625, "GPIO13  (RX2)", "GPIO14  (TX2)")

    sensor(ax, 667, 840, "MQ-5 module", "combustible gas · analog AO",
           [(726, "VCC 5V (heater)"), (750, "GND"), (774, "AO (0–5 V)"), (798, "DO")])
    supply(ax, 726); gnd(ax, 750)
    text(ax, 303, 798, "× not connected", 6.5, GREY)
    line(ax, [(SENSOR_R, 774), (330, 774)], ANALOG)
    resistor_h(ax, 330, 412, 774, ANALOG)
    text(ax, 371, 757, "R1 15 kΩ", 6.5, ha="center")
    line(ax, [(412, 774), (ESP_L, 774)], ANALOG)
    dot(ax, 450, 774, ANALOG)
    line(ax, [(450, 774), (450, 795)], ANALOG)
    resistor_v(ax, 450, 795, 840, ANALOG)
    line(ax, [(450, 840), (450, 856)], ANALOG)
    ground_down(ax, 450, 856)
    text(ax, 461, 816, "R2 10 kΩ", 6.5)
    text(ax, 372, 834, "divider: 5 V → 2.0 V max", 6.5, ANALOG, ha="center", style="italic")
    text(ax, 372, 845, "(must stay ≤ 2.9 V)", 6.5, ANALOG, ha="center", style="italic")
    dot(ax, ESP_L, 774)
    text(ax, ESP_L + 9, 774, "GPIO10  (ADC1_CH9)", 7)

    # Power
    esp_right_pin(ax, 198, "5V")
    line(ax, [(ESP_R, 198), (805, 198)], SUPPLY)
    text(ax, 809, 198, "+5V rail", 6.5, SUPPLY, weight="bold")
    esp_right_pin(ax, 224, "GND")
    line(ax, [(ESP_R, 224), (803, 224)], INK)
    ground_side(ax, 803, 224)
    for i, s in enumerate(("5 V (USB / 5V pin) feeds", "every sensor; all grounds", "tied together")):
        text(ax, 788, 254 + i * 10, s, 6, GREY)

    # RGB LED
    box(ax, 1005, 234, 1100, 441, fill=BOX)
    text(ax, 1052, 250, "RGB LED", 10, weight="bold", ha="center")
    text(ax, 1052, 270, "common cathode", 6, GREY, ha="center")
    text(ax, 1051, 219, "PWM 5 kHz · 8-bit · LED_COMMON_ANODE = false", 6, GREY, ha="center")
    for y, gpio, letter, color in ((302, "GPIO21", "R", "#c62828"), (354, "GPIO47", "G", TX), (406, "GPIO48", "B", RX)):
        esp_right_pin(ax, y, gpio)
        line(ax, [(ESP_R, y), (828, y)], OUT)
        resistor_h(ax, 828, 945, y, INK)
        text(ax, 887, y - 17, "220 Ω", 6.5, ha="center")
        line(ax, [(945, y), (1005, y)], OUT)
        text(ax, 1013, y, letter, 8.5, color, weight="bold")
    text(ax, 1051, 423, "K", 7, ha="center")
    line(ax, [(1100, 423), (1135, 423)], INK, 2)
    dot(ax, 1100, 423)
    ground_side(ax, 1135, 423)

    # Buzzer stage
    esp_right_pin(ax, 579, "GPIO39")
    line(ax, [(ESP_R, 579), (795, 579)], OUT)
    resistor_h(ax, 795, 842, 579, INK, peaks=4)
    text(ax, 818, 562, "R3 1 kΩ", 6.5, ha="center")
    line(ax, [(842, 579), (950, 579)], OUT)
    dot(ax, 891, 579, OUT)
    line(ax, [(891, 579), (891, 598)], OUT)
    resistor_v(ax, 891, 598, 642, INK)
    line(ax, [(891, 642), (891, 658)], OUT)
    ground_down(ax, 891, 658)
    text(ax, 902, 612, "R4 10 kΩ", 6.5)
    text(ax, 902, 624, "pull-down", 6.5)
    ax.add_patch(Circle((960, 580), 25, fc="white", ec=INK, lw=1.3))
    line(ax, [(950, 565), (950, 595)], INK, 2)
    line(ax, [(950, 573), (970, 558), (970, 537)], INK)
    line(ax, [(950, 587), (970, 602), (970, 658)], INK)
    ax.add_patch(Polygon([(970, 602), (961, 601), (966, 594)], closed=True, fc=INK, ec=INK))
    ground_down(ax, 970, 658)
    text(ax, 991, 578, "Q1 NPN", 6.5)
    text(ax, 991, 589, "S8050 / 2N2222", 6.5)
    box(ax, 941, 497, 1001, 537, fill="#fdf3c4")
    text(ax, 971, 517, "BUZZER", 6, weight="bold", ha="center")
    text(ax, 963, 488, "+", 7, ha="center")
    text(ax, 932, 480, "+5V (or 3V3)", 6.5, SUPPLY, weight="bold", ha="right")
    line(ax, [(935, 481), (970, 481), (970, 497)], SUPPLY)
    line(ax, [(970, 490), (1032, 490), (1032, 506)], INK, 0.9)
    ax.add_patch(Polygon([(1023, 521), (1041, 521), (1032, 506)], closed=True, fc=INK, ec=INK))
    line(ax, [(1023, 506), (1041, 506)], INK, 1.3)
    line(ax, [(1032, 521), (1032, 545), (970, 545)], INK, 0.9)
    text(ax, 1045, 503, "D1 1N4148", 6)
    text(ax, 1045, 514, "(inductive", 6, GREY)
    text(ax, 1045, 525, "buzzer only)", 6, GREY)
    text(ax, 906, 683, "active buzzer, BUZZER_ACTIVE_HIGH = true", 6.5, GREY, ha="center")

    # SSD1306 OLED (optional)
    box(ax, 990, 700, 1130, 770, fill=BOX)
    text(ax, 1060, 715, "SSD1306 OLED", 9, weight="bold", ha="center")
    for y, gpio, pin in ((737, "GPIO8  (SDA)", "SDA"), (755, "GPIO9  (SCL)", "SCL")):
        esp_right_pin(ax, y, gpio)
        line(ax, [(ESP_R, y), (990, y)], I2C)
        dot(ax, 990, y)
        text(ax, 998, y, pin, 7)
    for y, pin in ((737, "VCC"), (755, "GND")):
        dot(ax, 1130, y)
        text(ax, 1122, y, pin, 7, ha="right")
    line(ax, [(1130, 737), (1160, 737)], SUPPLY)
    text(ax, 1164, 737, "+3V3", 6.5, SUPPLY, weight="bold")
    line(ax, [(1130, 755), (1158, 755)], INK)
    ground_side(ax, 1158, 755)
    text(ax, 885, 727, "I2C 400 kHz", 6, I2C, ha="center")
    text(ax, 1060, 781, "128×64 · address 0x3C · optional", 6, GREY, ha="center")
    text(ax, 1060, 792, "4.7 kΩ pull-ups to 3V3 only if the module has none", 6, GREY, ha="center")

    # Config button
    esp_right_pin(ax, 822, "GPIO0")
    line(ax, [(ESP_R, 822), (926, 822)], OUT)
    dot(ax, 926, 822)
    dot(ax, 961, 822)
    line(ax, [(926, 822), (957, 806)], INK)
    line(ax, [(942, 806), (942, 800)], INK)
    line(ax, [(961, 822), (1005, 822)], INK)
    ground_side(ax, 1005, 822)
    for i, s in enumerate(("CONFIG button (onboard BOOT)", "hold 3 s while running → setup portal",
                           "INPUT_PULLUP, active low")):
        text(ax, 943, 840 + i * 10, s, 6, ha="center")

    # Legend
    legend = (("+5 V supply", SUPPLY), ("GND (common)", INK), ("sensor TX → ESP RX", RX),
              ("ESP TX → sensor RX", TX), ("analog (divided)", ANALOG), ("I2C (OLED)", I2C),
              ("ESP outputs / inputs", OUT))
    for i, (label, color) in enumerate(legend):
        x = 51 + i * 163
        line(ax, [(x, 893), (x + 32, 893)], color, 2)
        text(ax, x + 39, 893, label, 6.5)
    text(ax, 1233, 893, "1 / 2", 6.5, GREY, ha="right")


# ---------------------------------------------------------------- page 2

ROWS = [
    ("ZE03-CO receive", "GPIO17 (UART0 RX)", "ZE03 TX", "9600 8N1, CO_RX_PIN"),
    ("ZE03-CO transmit", "GPIO18 (UART0 TX)", "ZE03 RX", "CO_TX_PIN"),
    ("LD2410 receive", "GPIO15 (UART1 RX)", "LD2410 TX", "256000 8N1, PRESENCE_RX_PIN"),
    ("LD2410 transmit", "GPIO16 (UART1 TX)", "LD2410 RX", "PRESENCE_TX_PIN"),
    ("PMS5003T receive", "GPIO13 (UART2 RX)", "PMS TX (pin 5)", "9600 8N1, PARTICULATE_RX_PIN"),
    ("PMS5003T transmit", "GPIO14 (UART2 TX)", "PMS RX (pin 4)", "PARTICULATE_TX_PIN"),
    ("MQ-5 analog", "GPIO10 (ADC1_CH9)", "MQ-5 AO via R1/R2 divider (×0.4)", "12-bit, 11 dB"),
    ("LED red", "GPIO21", "220 Ω → LED R anode", "PWM 5 kHz, 8-bit"),
    ("LED green", "GPIO47", "220 Ω → LED G anode", "LED_GREEN_PIN"),
    ("LED blue", "GPIO48", "220 Ω → LED B anode", "LED_COMMON_ANODE = false"),
    ("Buzzer driver", "GPIO39", "1 kΩ → NPN base", "BUZZER_ACTIVE_HIGH = true"),
    ("Config button", "GPIO0", "button to GND (onboard BOOT)", "INPUT_PULLUP, hold 3 s"),
    ("OLED data (optional)", "GPIO8 (I2C SDA)", "SSD1306 SDA", "400 kHz, 0x3C, DISPLAY_SDA_PIN"),
    ("OLED clock (optional)", "GPIO9 (I2C SCL)", "SSD1306 SCL", "DISPLAY_SCL_PIN"),
    ("Power", "5V / 3V3 / GND", "5V: all four sensors · 3V3: OLED", "shared ground required"),
]

NOTES = [
    "MQ-5 divider is mandatory. AO swings up to ~5 V; the ADC resolves only ~0–2.9 V at 11 dB and a 5 V input damages the pin. R1 = 15 kΩ (AO side), R2 = 10 kΩ (GND side)\ngives 2.0 V at full scale; swapped they give 3.0 V and clip. Default gas thresholds (warn 1200, danger 1760 counts) assume this ratio.",
    "MQ-5 heater draws ~150 mA at 5 V. Feed it from the 5 V rail, never from a GPIO.",
    "All sensor signals are 3.3 V TTL (ZE03, LD2410, PMS5003T run on 5 V but talk at 3 V levels) — wire them directly, no level shifter.",
    "Cross TX/RX: each sensor's TX goes to the ESP RX pin listed above, and its RX to the ESP TX pin.",
    "Build with “USB CDC On Boot: Enabled”. UART0 belongs to the ZE03-CO; the debug console is on the native USB port.",
    "Confirm the particulate sensor is a PMS5003T, not a plain PMS5003 — the parser cannot tell them apart and would report particle counts as temperature.",
    "Do not use GPIO35/36/37 for the LED on modules with Octal PSRAM (N8R8, N16R8, every WROOM-2). The compiled GPIO21/47/48 set works on every module. GPIO48 also drives the onboard RGB LED on\nDevKitC-1 v1.0.",
    "GPIO39 has a weak pull-up at reset, so the buzzer can chirp at power-on. R4 (10 kΩ pull-down) suppresses it. Add D1 only if the buzzer is inductive (magnetic type).",
    "GPIO0 is a boot strapping pin: holding it during reset enters ROM download mode, not the setup portal.",
    "LD2410: B/C variants ship at 256000 baud; an older V1.03 LD2410 ships at 57600 — change PRESENCE_BAUD if no frames arrive. LD2410S/D are not compatible.",
    "Never open Serial2 without explicit pins: its default GPIO19/20 are the USB data lines.",
    "The SSD1306 is optional. Power it from 3V3, not 5V. Address 0x3C (0x3D with the module's jumper moved, DISPLAY_I2C_ADDRESS). With no display the firmware logs it and runs\nunchanged; set DISPLAY_ENABLED = false to skip the probe. The alarm never depends on the display.",
    "Resistor values for R1–R4, the LED resistors and the optional I2C pull-ups are recommendations, not fixed by the firmware.",
]


def draw_page2(ax):
    text(ax, 51, 35, "Pin map and wiring notes", 15, weight="bold")
    cols = (51, 268, 484, 787)
    row_h = 24.3
    y = 94
    ax.add_patch(plt.Rectangle((43, y - 13), 1200, 27, fc=ESP, ec="none"))
    for x, h in zip(cols, ("Function", "ESP32-S3 pin", "Connects to", "Setting")):
        text(ax, x, y, h, 7, weight="bold")
    for i, row in enumerate(ROWS):
        y = 118 + i * row_h
        if i % 2:
            ax.add_patch(plt.Rectangle((43, y - row_h / 2), 1200, row_h, fc=BOX, ec="none"))
        for x, cell in zip(cols, row):
            text(ax, x, y, cell, 7)

    y += 52
    text(ax, 51, y, "Notes", 11, weight="bold")
    y += 30
    for i, note in enumerate(NOTES, 1):
        text(ax, 51, y - 6, f"{i}.", 7, weight="bold", va="top")
        text(ax, 73, y - 6, note, 7, va="top")
        y += 34 if "\n" in note else 23

    text(ax, 51, 891, "Not a certified CO / gas / smoke alarm. Install listed alarms alongside it.", 6.5, GREY)
    text(ax, 1233, 891, "2 / 2", 6.5, GREY, ha="right")


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "wiring_diagram.pdf"
    with PdfPages(out, metadata={"Title": "Canary air sensor wiring diagram"}) as pdf:
        for draw in (draw_page1, draw_page2):
            fig, ax = page()
            draw(ax)
            pdf.savefig(fig)
            plt.close(fig)
    print(out)


if __name__ == "__main__":
    main()
