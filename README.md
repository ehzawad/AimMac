<p align="center"><img src="docs/icon.png" width="160" alt="Orbit Pointer icon"></p>

# Orbit Pointer

Use your **iPhone as a trackpad and keyboard** for your Mac, right alongside your real trackpad.

No Wi-Fi and no servers: the phone talks straight to the Mac over Bluetooth, and everything you type is encrypted between the two.

> Status: early beta. Real-device testing is still under way, so expect rough edges.

## What it does

| On the iPhone | On the Mac |
| --- | --- |
| Slide one finger | Move the pointer |
| Tap | Click |
| Tap, then slide | Drag |
| Hold one finger still | Look up, with a strong haptic in place of a force click |
| Slide two fingers | Scroll, with momentum |
| Pinch two fingers | Zoom in or out (⌘+ and ⌘−) |
| Tap with two fingers | Right-click |
| Swipe three fingers left or right | Switch Spaces |
| Swipe three fingers up or down | Mission Control or App Exposé |
| Tap with three fingers | Look up |
| **Keyboard** button | Type with the iPhone keyboard |

The keyboard only opens from its button. While it's up, a row of keys gives you esc, tab, ⌘ ⌥ ⌃ ⇧ and the arrows; a modifier applies to the next key you press.

Use it upright or turn the phone sideways for a wide trackpad with the controls in a slim column, and tap the rotation lock to stay in either one. The keyboard works in both. Your real trackpad keeps working the whole time.

- **Pairing with a code.** The first time a phone connects, both screens show a six-digit code and the Mac asks you to allow it. Only allow it if the codes match.
- **Notch panel.** Hover the notch (or the middle of the menu bar) to see the connected phone, its battery and quick buttons. Pin it to keep it open.
- **Orbit Pop**, a small target game to try it on.

## Requirements

- Mac with macOS 14 or later, Apple silicon or Intel, with Bluetooth
- iPhone with iOS 17 or later
- Xcode 26 or later to build it (Swift 6)

## 1. Mac app

```bash
cd Mac
chmod +x build.sh
./build.sh install
```

This builds Orbit Pointer and puts it in `/Applications`. The first launch asks for **Bluetooth** and **Accessibility** (System Settings › Privacy & Security › Accessibility). Accessibility is what lets it move the pointer and type. Allow both.

With an Apple Development certificate, macOS remembers the permission across rebuilds. Without one, turn Orbit Pointer off and on in that list after each rebuild.

## 2. iPhone app

With [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
cd Apple
xcodegen
open AimMac.xcodeproj
```

1. Sign with your Apple ID: create `Apple/Local.xcconfig` with your bundle prefix and Team ID (see `Apple/Config.xcconfig`), or just pick your Team in **Signing & Capabilities**.
2. Choose your iPhone as the run destination and press **⌘R**. The first time, turn on **Developer Mode** on the iPhone (Settings › Privacy & Security) and trust your developer profile (Settings › General › VPN & Device Management).
3. Open Orbit Pointer on the iPhone, tap **Pair** next to your Mac, check that the codes match, then click **Allow** on the Mac.

## Settings

Speed, smoothing and scroll direction are in the Orbit Pointer menu on the Mac.

## Orbit Pop

Click **Game** in the notch panel or **Play the target game** in the menu. Press **F** for full screen. Rings shrink and fade; pop them before they collapse. Center hits score double, gold rings triple, and every hit in a row raises your combo.

## How it works

- **iPhone** (`Apple/`): a multi-touch surface turns fingers into relative moves, clicks and scrolls, and a key-capture view forwards the iPhone keyboard.
- **Mac** (`Mac/`): plays each movement out over a few milliseconds so Bluetooth's uneven timing doesn't show, adds in whatever your real trackpad did meanwhile, and posts ordinary mouse and keyboard events.
- **Bluetooth**: the Mac advertises a service and the phone connects to it. The protocol is documented at the top of `Shared/Protocol.swift`.
- **Security**: each device has its own key. Every connection is authenticated with a fresh key exchange, and all input is encrypted and protected against replay (`Shared/PairingAuth.swift`). Status messages from the Mac are not authenticated.

Run the logic checks with `Tests/run.sh`.

## Credits

Based on [AimMac](https://github.com/Coolerwave/AimMac), inspired by [WatchPointer](https://github.com/umarz317/WatchPointer) by umarz317.

## License

MIT
