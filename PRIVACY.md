# Orbit Pointer Privacy Policy

Orbit Pointer turns your iPhone into a trackpad and keyboard for your Mac.

**Orbit Pointer does not collect your data.** It has no accounts, no servers, no analytics and no advertising. The developer never receives anything you do in the app.

## What stays between your devices

- Pointer movement, clicks, gestures and the text you type or dictate go directly from your iPhone to your Mac over Bluetooth, encrypted between the two. Nothing is sent over the internet.
- Your iPhone also tells your Mac its name, model and battery level over Bluetooth. The Mac shows the name and battery level. These details are not encrypted by the app, and the name is sent before pairing finishes, as part of connecting.
- Each device stores its own pairing key and the identity of the device it is paired with. Your settings are stored on your own devices too.

## What the app can do on your Mac

The Mac app needs Accessibility permission so it can move the pointer, click and type for you. It uses that permission only to carry out what you do on your paired iPhone.

## Other companies' services

If you use iPhone dictation, Apple handles it under its own privacy terms. If you install through TestFlight, Apple shares limited test information with the developer, such as crashes and feedback you choose to send, under TestFlight's terms.

## Removing your data

Unpair in the iPhone app and choose **Forget paired devices** in the Mac menu.

Deleting the iPhone app removes its settings. iOS may keep its pairing key in the Keychain.

Dragging the Mac app to the Trash leaves its data behind. To remove that too, delete `~/Library/Application Support/OrbitPointer` and `~/Library/Preferences/com.ehzawad.aimmac.mac.plist`. Orbit Pop keeps its best score in your browser's storage for the game page.

## Questions

Open an issue at <https://github.com/ehzawad/AimMac/issues>.
