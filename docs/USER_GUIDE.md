# User guide

## What the QR contains

GPS QR encodes a standard geographic URI:

```text
geo:<latitude>,<longitude>
```

Coordinates are formatted to six decimal places. The display text and QR payload are committed together, so the visible numbers describe the location encoded in the active QR.

## Color widget

### Embedded view

A sufficiently large widget zone displays the QR and position details. A compact zone may show:

```text
Open the widget full screen to scan
```

This is intentional. A QR that is too small or has insufficient quiet space may look correct but scan unreliably.

### Full-screen view

Full-screen mode uses the available screen dimensions and adds a **Refresh QR** control when EdgeTX exposes interactive LVGL controls. Touch is optional; physical Enter events also request a refresh.

### Automatic refresh

A new fix marks the QR as pending. The widget waits for the refresh interval before replacing an existing QR, limiting repeated LVGL QR reconstruction when telemetry updates rapidly. The last completed QR remains visible until the new payload is committed.

## Monochrome and grayscale telemetry screen

The telemetry script generates the QR cooperatively across background callbacks. During generation:

- The previous completed QR stays on screen.
- Status text indicates that a new QR is pending or being generated.
- Enter requests a QR for the latest valid fix.

The QR uses only black and white modules. Grayscale is used as a display capability signal, not for QR module colors.

## Status messages

### `No configured GPS sensor`

The active model does not contain a telemetry sensor whose unit is GPS Coordinates. Run sensor discovery while telemetry is active.

### `Waiting for <sensor> telemetry`

A GPS sensor is configured, but the selected source is not currently returning valid latitude and longitude. Check the telemetry link, GPS fix, and flight-controller configuration.

### `<sensor> source unavailable`

The configured GPS sensor was found but its current-value source could not be resolved. Re-discover the sensor, remove duplicate or stale telemetry entries, and restart the radio.

### `<sensor> fix N seconds ago`

The displayed fix was last accepted N seconds ago. A rising age can indicate lost telemetry or a flight controller that stopped publishing coordinates.

### `<sensor> fix pending`

A newer valid position exists, but the QR still represents the previous committed location until the refresh policy or manual request rebuilds it.

## Multiple GPS sensors

When several configured sensors have `UNIT_GPS`, GPS QR prefers the first candidate currently returning valid coordinates. If none are live, it retains the previous selection when possible to avoid switching during short telemetry interruptions.

## Last-known position

The application intentionally preserves the last valid fix after telemetry disappears. This is useful for model recovery, but the position may be stale. Always read the displayed fix age.

## Scanning tips

- Open the widget or telemetry screen only when needed.
- Use full-screen mode on color radios.
- Increase radio backlight when outdoors.
- Hold the phone parallel to the display.
- Avoid glare across finder patterns.
- Keep the entire QR and its white border in the camera frame.
- Clean the display and camera lens.
