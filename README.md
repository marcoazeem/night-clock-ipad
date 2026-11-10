# Night Clock for 32-bit iPads

A native Objective-C / UIKit port of
[Night Clock](https://github.com/marcoazeem/night-clock), a bedside clock
and smart-home dashboard, for an iPad 4th gen running **iOS 10.3.4**
(32-bit armv7). Flutter and Swift can't target that hardware any more, so
this is plain UIKit with no dependencies.

The look (Nov 2026) is "luxury" OLED black: ivory and muted text, one
gold accent, thin outline icons, and cards with a brushed-metal hairline
edge. On its side the screen is two columns — the clock on the left, the
controls on the right — with the room's name and its scenes along the top
and text-only room tabs along the foot (HOME, then each room). Standing,
the clock goes on top and the controls under it.

What it shows:

- **Clock**: the date in small caps, `HH:MM` in Jost ExtraLight (ivory;
  slate in night mode), a fading hairline, and the weather from Open-Meteo
  (no API key): the animated Meteocons icon, the temperature and "MALÉ ·
  RAIN".
- **Holidays**: when a Maldives public holiday is 15 days away or less, it
  sits on the hairline in red ("REPUBLIC DAY · TOMORROW"). The dates come
  from Google's public "Holidays in Maldives" calendar (no key; it follows
  the moon-sighted Islamic dates), fetched every 12 hours and kept for
  offline. This is iPad-only; the phone's face has no room for it.
- **Picture**: your own clips, framed under the clock with soft edges —
  never full screen. By day they play on a loop; after dark you get a
  greyscale still that drifts very slowly.
- **Energy** under the picture: the room's draw now, this bill's projected
  cost, and a thin gold line of past bills (kWh a day).
- **Controls**, in the order they're used: the lights as big tiles (tap to
  switch, and the dimmer row under them sets 1 / 25 / 50 / 100% — tap its
  name for the next light; press and hold a colour bulb for its colour
  temperature), the wall switches, a row per AC (− setpoint + and power),
  and a slim strip per TV (volume, play / pause, power). All of it over
  the local network with no cloud:
  - Tapo bulbs (KLAP v2) and Mi bulbs (miIO)
  - Gree ACs (UDP 7000, AES-ECB/GCM)
  - Hisense VIDAA TV (MQTT over TLS)
  - Android TV box (network ADB, with an RSA key in the keychain)
  - Wake-on-LAN
- **The house** on the home page, as in the phone app: a 3D render of
  the apartment (`assets/images/blueprint.png` in the main repo, your own —
  without it the home page shows room cards) with a label hung at each
  room — tap the room or the label to open it — and the rooms glowing with
  what's on: amber for lights, a cool halo while an AC cools, violet on a
  TV that's on. Drag it sideways to turn it; it springs back.
- **Energy estimate** on the home page, as in the phone app: the draw
  now, today, this bill and its projected cost, and a line graph of past
  bills, with a tally of lights on, ACs cooling and screens on.
- **Dimmer**: press, hold and slide up or down to dim. The backlight tops
  out at 40% — the iPad lives in a bedroom and the backlight is most of
  what it draws.
- **Standby**: after 15 seconds untouched the picture's clip stops where
  it is and the backlight drops to 12% (the screen is black already).
  Everything stays on screen and keeps working; the first touch brings it
  back.
- **Night mode** (23:00–06:00): the gold turns night red, the clock
  slate, and the weather icon stands still, tinted red.

## Layout

This repo lives **inside** a checkout of the main Night Clock repo, as
its `ipad/` folder. It borrows these from the main repo:

- `lights.json` for your device config
- the fonts
- the Flutter toolchain, which renders the panel's icons (and the app
  icon's digits) to PNGs
- the clips for the picture

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

The Jost (The Jost Project Authors, indestructible type) and Inter fonts come from the
main repo's `fonts/` and are under the SIL Open Font License
(`OFL-Jost.txt`, `OFL-Inter.txt`). The Chakra Petch font renders the app
icon's digits (SIL Open Font License). The light tiles of earlier versions
were based on [Lightbox](https://rive.app/marketplace/19639-36948-lightbox/)
by Gary Simon, [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The weather icons are
[Meteocons](https://github.com/basmilius/weather-icons) by Bas Milius (MIT),
from `assets/weather/` in the main repo, animated by
[lottie-ios](https://github.com/airbnb/lottie-ios) 2.5.3 (Airbnb, Apache
2.0), which `build.sh` fetches and builds into `build/`. The background
clips aren't included.
