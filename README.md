# Night Clock for 32-bit iPads

A native Objective-C / UIKit port of
[Night Clock](https://github.com/marcoazeem/night-clock), a bedside clock
and smart-home dashboard, for an iPad 4th gen running **iOS 10.3.4**
(32-bit armv7). Flutter and Swift can't target that hardware any more, so
this is plain UIKit with no dependencies.

What it shows:

- **Clock**: `HH:MM` in Bungee Tint (coloured to match the sky), plus the date and the weather from Open-Meteo
  (no API key).
- **Background**: your own clips. By day they play on a loop; after dark
  you get a still frame under a dark wash.
- **Panel**, all controlled over the local network with no cloud:
  - Tapo bulbs (KLAP v2) and Mi bulbs (miIO)
  - Gree ACs (UDP 7000, AES-ECB/GCM)
  - Hisense VIDAA TV (MQTT over TLS)
  - Android TV box (network ADB, with an RSA key in the keychain)
  - Wake-on-LAN
- **Dimmer**: press, hold and slide up or down to dim.

## Layout

This repo lives **inside** a checkout of the main Night Clock repo, as
its `ipad/` folder. It borrows these from the main repo:

- `lights.json` for your device config
- the fonts
- the Flutter toolchain, which pre-renders the clock font's glyphs to PNGs
  (iOS 10 can't draw colour fonts)
- the background clips

```sh
git clone https://github.com/marcoazeem/night-clock
cd night-clock
git clone https://github.com/marcoazeem/night-clock-ipad ipad
```

## Building

Needs macOS with Xcode, Flutter, `ffmpeg`, and
[libimobiledevice](https://libimobiledevice.org) (`brew install
libimobiledevice ideviceinstaller`).

```sh
ipad/build.sh            # builds ipad/build/NightClock.ipa
ipad/build.sh install    # ...and installs it over USB
FORCE_NIGHT=1 ipad/build.sh install   # preview night mode
```

The script handles a few old-SDK tricks:

- It downloads the iOS 10.3 SDK (theos/sdks) and patches it to link with
  current Xcode clang.
- It builds with `-marm` and without ObjC exceptions.
- It links the armv7 math helpers from Xcode's compiler-rt.

Signing uses a paid developer team's wildcard development profile that
lists your iPad. To use your own, set `TEAM_ID`, `BUNDLE_ID` and
`IPAD_UDID`, or put the UDID in `ipad/.udid`; it's gitignored. Xcode
can't see iOS 10 devices, so installing goes through `ideviceinstaller`.

## Licence of bundled assets

The Bungee Tint and Inter fonts come from the main repo and are under the SIL
Open Font License. The lightbox bulb pictures (`assets/images/` in the main
repo) and the light tiles' design come from
[Lightbox](https://rive.app/marketplace/19639-36948-lightbox/) by Gary Simon,
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The background
clips aren't included.
