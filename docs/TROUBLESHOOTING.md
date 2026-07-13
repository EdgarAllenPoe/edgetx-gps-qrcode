# Troubleshooting

## GPS QR is not listed as a widget

Confirm the exact path:

```text
/WIDGETS/GPSQR/main.lua
```

The folder must be directly under `WIDGETS`, and the file must be named `main.lua`. Remove an extra archive-name directory if one was created during extraction. Delete `main.luac` and restart the radio.

## GPSQR is not listed as a telemetry script

Confirm:

```text
/SCRIPTS/TELEMETRY/GPSQR.lua
```

Monochrome telemetry script names are constrained by EdgeTX, so the filename is intentionally six characters before `.lua`. Delete `GPSQR.luac` and restart.

## The widget is blank

Use the current self-contained color file from `dist/`. It must not depend on modules under `/SCRIPTS/GPSQR/`. Delete the entire `/WIDGETS/GPSQR/` folder, copy the release folder again, remove `main.luac`, restart, and re-add the widget.

## `Unable to load script`

Check for:

- An incomplete or zero-byte file.
- A stale `.luac` file.
- Incorrect capitalization or path.
- SD-card corruption.
- A readable source copied onto a radio with very little free Lua memory; try the minified release.

The color widget in this repository is self-contained and contains no `loadScript()` dependency.

## `No configured GPS sensor`

Open the active model's Telemetry page and run **Discover New** while the receiver, flight controller, GPS, and telemetry link are active. A sensor whose unit is GPS Coordinates must appear.

## `Waiting for ... telemetry`

The sensor exists but is not currently returning valid coordinates. Check:

- GPS power and wiring.
- Satellite fix.
- Flight-controller GPS detection.
- Telemetry output configuration.
- Receiver-to-flight-controller telemetry wiring.
- Receiver link and correct active model.

Some systems publish coordinates only after a valid fix.

## The configured GPS has a different name

No rename is required. The scripts identify configured sensors by `UNIT_GPS`. A renamed sensor should appear in the status text.

## A compact color widget does not show a QR

Open the widget full screen. The application intentionally avoids rendering a QR below its reliability threshold.

## The QR does not scan

- Use full screen where available.
- Increase display brightness.
- Reduce reflections.
- Hold the phone square to the radio.
- Keep the quiet zone visible.
- Try a different camera or QR application.
- Confirm the display is not inverted incorrectly.

## The QR location is old

Read the displayed fix age. The application preserves the last valid position after telemetry loss. Restore telemetry or press Enter/Refresh after a new fix arrives.

## Monochrome radio becomes sluggish

Close the telemetry screen. The script performs cooperative work, but lower-power radios and firmware builds have different Lua budgets. Use the screen only when recovering the model and validate behavior before flight.

## QR polarity is wrong on a monochrome radio

Use the documented source and set:

```lua
local POLARITY_OVERRIDE = "normal"
```

or:

```lua
local POLARITY_OVERRIDE = "inverted"
```

Then rebuild the distribution. `automatic` applies known radio-profile behavior.

## Reporting a new radio issue

Use the GitHub bug template and include:

- Radio model.
- Exact EdgeTX version.
- Display dimensions and color/B&W/grayscale class.
- Physical radio, EdgeTX Simulator, or host test.
- GPS sensor name and protocol.
- Exact on-screen message.
- A screenshot with coordinates redacted when necessary.
