# Black Pearl for macOS

A native macOS control panel for the **TRN Black Pearl** USB-C DAC: 10-band parametric EQ with a draggable response graph, presets, AutoEQ import/export, volume with headroom warning, balance, microphone gain, digital filter, gain and amplifier mode.

It talks to the DAC directly over USB HID - no driver, no account, no network. The protocol is ported from [pyBlackPearl](https://github.com/KDRN/pyBlackPearl), the reverse-engineered Windows tool.

> **Firmware updates are not included.** Those go through Walkplay's own server. Use the official web app at <https://peq.szwalkplay.com/> in Chrome or Edge for that.

## Install

**Prebuilt:** download `BlackPearl-x.y.z.zip` from the [Releases](../../releases) page, unzip, and drag `BlackPearl.app` to Applications. The app is ad-hoc signed, not notarized, so the first launch needs a right-click → Open (or `xattr -d com.apple.quarantine /Applications/BlackPearl.app`).

**From source** (needs Xcode 15+ or the Command Line Tools):

```sh
git clone https://github.com/BenHigh/BlackPearl-MacOS.git
cd BlackPearl-MacOS
make install        # builds and copies BlackPearl.app into /Applications
```

`make run` builds and launches without installing; `make test` runs the protocol tests.

## Using it

1. **Plug headphones into the DAC first**, then connect it to the Mac. The Black Pearl stays asleep on USB until it detects a load on the jack - it won't even power its LED, let alone enumerate.
2. Launch Black Pearl. It finds the DAC automatically, reads its current state, and keeps the window in sync (including volume changes made with the DAC's own buttons).
3. Drag the numbered dots on the graph, or edit the band table. Changes go to the DAC immediately and are committed to its flash memory 3 seconds after you stop adjusting, so they persist when you move the DAC to a phone.

**Presets** are stored at `~/Library/Application Support/BlackPearl/settings.json`. The "Device" preset always mirrors whatever the DAC holds when no saved preset matches it. **Import AutoEQ…** accepts the `ParametricEQ.txt` files from [AutoEQ](https://github.com/jaakkopasanen/AutoEq) / Equalizer APO; gains are clamped to the DAC's ±10 dB.

**Headroom:** the orange ceiling line shows how much boost fits under digital full scale at the current volume. If your EQ exceeds it, the Device tab offers a one-click volume trim.

## Hardware notes

- USB identity: vendor `0x3302` (TTGK Technology), product `0x43E8`, name "TE-C".
- Every exchange is a 64-byte HID report with report ID `0x4B`. See `Sources/BlackPearl/Protocol.swift` for the command set and `Tests/BlackPearlTests` for byte-exact fixtures.
- Only one Black Pearl is handled at a time.

## License

GPL-3.0, like pyBlackPearl it derives from. TRN, Black Pearl and Walkplay are trademarks of their respective owners; this project is not affiliated with them.
