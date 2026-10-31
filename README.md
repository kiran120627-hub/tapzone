# tapzone

**Tap the corners of your MacBook screen to run actions.** No extra hardware.

Tap the top-left corner to switch desktops, the bottom-left to play or pause music, the
bottom-right to mute your microphone, or set any corner to open an app or press a shortcut.
Every corner has a single tap and a double tap.

It works with the motion sensor already inside your MacBook. A tap on the lid twists the laptop
very slightly about its hinge; tapzone feels that twist and learns, from a two-minute
calibration, which corner each twist comes from. Everything runs on your Mac: no network, no
account, nothing leaves the machine.

## Requirements

- An Apple Silicon MacBook **with the motion sensor**: MacBook Air or Pro with M2 or later, or
  the 14"/16" MacBook Pro with M1 Pro or M1 Max.
  (Not the M1 MacBook Air, the 13" M1 MacBook Pro, desktop Macs or Intel Macs.)
- macOS 14 or later.

## Install

### Download (easiest)

1. Download `tapzone-macos.zip` from the [latest release](../../releases/latest) and unzip it.
2. Move it somewhere on your PATH:
   ```bash
   sudo mkdir -p /usr/local/bin && sudo mv ~/Downloads/tapzone /usr/local/bin/
   ```
3. The download isn't signed by Apple, so macOS blocks it the first time. Allow it with:
   ```bash
   xattr -d com.apple.quarantine /usr/local/bin/tapzone
   ```

### Build from source

Needs Apple's Command Line Tools (`xcode-select --install`).

```bash
git clone <this repository's URL>
cd tapzone
./build.sh
sudo mkdir -p /usr/local/bin && sudo cp build/tapzone /usr/local/bin/
```

## Use

```bash
tapzone calibrate      # tap each corner 10 times when asked (~2 minutes)
tapzone run            # start; Ctrl+C to stop
```

- Tap with a **quick, light flick of a fingertip**, about 2 cm in from the edge. Never press hard:
  pressing on a display can damage it.
- Wait about a second between taps, and keep your hands off the keyboard and trackpad while
  tapping. Taps right after typing or using the trackpad are ignored on purpose.
- Allow **Accessibility** for your terminal app when asked (System Settings → Privacy & Security →
  Accessibility). Desktop switching, media keys and shortcuts need it.
- If the motion sensor sends no data, allow **Input Monitoring** for your terminal app too.

## Change what taps do

```bash
tapzone set top-left single desktop-left
tapzone set bottom-right double open:Spotify
tapzone set top-right double keys:cmd+shift+4
tapzone list
```

Corners: `top-left`, `top-right`, `bottom-left`, `bottom-right`. Gestures: `single`, `double`.

Actions: `desktop-left`, `desktop-right`, `play-pause`, `next-track`, `previous-track`,
`mute-mic`, `none`, `open:<App name>`, `keys:<shortcut>`.

| Setting | Values | What it does |
|---|---|---|
| `sensitivity` | low, medium, high | How light a tap still counts. Use `low` if it reacts when you didn't tap |
| `double-speed` | slow, normal, fast | How quickly the second tap must follow |
| `double-tap` | on, off | Off makes every tap act instantly |

```bash
tapzone set sensitivity low
```

Settings are saved in `~/Library/Application Support/Tapzone/settings.json`. You can edit that file
by hand; a running tapzone picks up changes within a second. A corner without a double-tap action
acts instantly; one with a double-tap action waits briefly to see if a second tap follows.

tapzone pauses the sensor while the lid is closed, the display is asleep or the screen is locked.

## How it works

1. **Sensor:** reads the accelerometer and gyroscope (~800 times a second) and the lid angle through
   IOKit HID.
2. **Detect:** a tap is a sharp twist that stands out from the background. The trigger level adapts
   to how much the laptop is already being jostled, and taps during typing, trackpad use, lid
   movement or ongoing motion are ignored.
3. **Recognise:** each tap becomes a set of features (twist direction, how it splits across the
   axes, its waveform) and a k-nearest-neighbours model trained on your calibration picks the
   corner. Taps it isn't sure about are skipped rather than guessed.
4. **Act:** single and double taps run the action you set for that corner.

## Limitations

- Four corners only; it can't track a finger, drag or detect a long press.
- Accuracy depends on your calibration and drops if the lid angle or surface changes a lot.
  Calibrate again if it gets worse.
- It reads a sensor Apple doesn't document, so a future macOS update could break it.

## Credits

Inspired by [LidTap](https://github.com/harsha20599/lidtap) by Yemcube, which showed that a
MacBook's motion sensor can tell lid taps apart. tapzone is an independent implementation and
shares no code with it.

Not affiliated with or endorsed by Apple.

## License

[MIT](LICENSE)
