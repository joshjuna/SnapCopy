# SnapCopy

A tiny macOS menu-bar utility that grabs **text** or **QR/barcodes** off your screen
and puts the result on the clipboard — a clone of [GrabText](https://grabtext.app/).

Select a region with the native crosshair, and SnapCopy runs on-device OCR (Apple's
Vision framework — no network, no dependencies) and copies the result, showing a
"Copied" notification.

## Features

- Lives in the menu bar (no Dock icon)
- **⌃S** — Select Text (OCR → clipboard)
- **⌃Q** — Select QR Code / barcode (decode → clipboard)
- Native region selection via macOS `screencapture`
- On-device recognition via the Vision framework
- "Copied" notification with a preview of the result

## Install (no build required)

1. Download `SnapCopy.zip` from the [latest release](https://github.com/joshjuna/SnapCopy/releases/latest) and unzip it.
2. Move `SnapCopy.app` to `/Applications`.
3. **First launch:** right-click the app › **Open** › **Open** (it's not notarized, so
   this clears Gatekeeper once; afterwards it opens normally).
4. Grant **Screen Recording** when prompted (see [Permissions](#permissions)).

## Build from source

```sh
./build.sh
```

This compiles `main.swift`, assembles `SnapCopy.app`, and ad-hoc signs it.
Requires the Xcode command-line tools (`swiftc`). macOS 13+.

## Run

```sh
open SnapCopy.app
```

Then click the menu-bar icon, or press **⌃S** / **⌃Q**.

### Permissions

- **Screen Recording** (required): on first capture macOS prompts for it.
  Enable SnapCopy under *System Settings › Privacy & Security › Screen Recording*,
  then quit and reopen the app. Without it, captures come back blank.
- **Notifications** (optional): allow it to see the "Copied" banner. The clipboard
  copy works regardless.

## How it works

`main.swift` is the whole app (~250 lines):

- `HotKeyManager` — Carbon `RegisterEventHotKey` for the global ⌃S / ⌃Q shortcuts
  (no Accessibility permission needed).
- `Grab.captureSelection()` — shells out to `screencapture -i`, then **materializes**
  the captured pixels into an in-memory bitmap so recognition (which runs async) isn't
  reading a temp file that's already been cleaned up.
- `Grab.recognizeText` / `Grab.scanCodes` — Vision `VNRecognizeTextRequest` /
  `VNDetectBarcodesRequest`.
- `AppDelegate` — menu-bar `NSStatusItem`, clipboard, and `UserNotifications` banner.
