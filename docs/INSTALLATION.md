# Installation

## Choose a package

For normal installation, download one of the assets from the [latest GitHub Release](https://github.com/EdgarAllenPoe/edgetx-gps-qrcode/releases/latest):

- `GPSQR-v10.10.8-SD-minified.zip` — recommended for normal radio use.
- `GPSQR-v10.10.8-SD-readable.zip` — functionally equivalent, with full inline documentation for inspection and modification.
- `SHA256SUMS` — checksums for verifying the downloaded archives.

A repository checkout also contains the same generated archives under `dist/`.

The minified scripts reduce SD-card reads, Lua parsing work, and temporary heap use. Keep the readable archive on a computer for development and troubleshooting.

## Copy to the SD card

Extract the selected ZIP directly to the **root** of the radio SD card. Do not copy the ZIP itself and do not create an extra enclosing directory.

The final paths must be:

```text
/WIDGETS/GPSQR/main.lua
/SCRIPTS/TELEMETRY/GPSQR.lua
```

Both files may remain installed. EdgeTX uses the color widget on color radios and the telemetry script on black-and-white or grayscale radios.

Delete stale compiled files if they exist:

```text
/WIDGETS/GPSQR/main.luac
/SCRIPTS/TELEMETRY/GPSQR.luac
```

Completely power off and restart the radio after copying.

## Configure GPS telemetry

1. Select the model that will provide GPS telemetry.
2. Power the receiver, flight controller, and GPS.
3. Confirm the receiver has an active telemetry link.
4. Open the model **Telemetry** page.
5. Select **Discover New**.
6. Wait for a sensor whose unit is **GPS Coordinates**.
7. Stop discovery after the expected sensors appear.

The sensor label may be changed. GPS QR detects the sensor by its EdgeTX unit, not only by the text `GPS`.

## Color radios

Color radios use the widget path:

```text
/WIDGETS/GPSQR/main.lua
```

1. Open the Main View layout editor.
2. Select a widget zone.
3. Choose **GPS QR**.
4. Open the widget full screen for the largest QR code and refresh control.

Native color QR rendering requires EdgeTX 2.11 or later.

## Black-and-white and grayscale radios

These radios use the telemetry-script path:

```text
/SCRIPTS/TELEMETRY/GPSQR.lua
```

1. Open the active model's display or telemetry-screen settings.
2. Assign the script named `GPSQR` to a telemetry screen.
3. Open that screen when the location must be scanned.
4. Press Enter to request an immediate QR refresh.

The telemetry screen should be used as a recovery aid rather than left open throughout a flight until CPU behavior has been validated on that radio.

## Verify a download

From PowerShell, run:

```powershell
Get-FileHash .\GPSQR-v10.10.8-SD-minified.zip -Algorithm SHA256
```

Compare the result with the matching entry in `SHA256SUMS` from the same GitHub Release.

## Upgrade

1. Download the new release archive.
2. Replace both `.lua` files with the new release.
3. Delete any matching `.luac` cache files.
4. Restart the radio.
5. On a color radio, remove and re-add the widget if EdgeTX retained an old instance state.

## Uninstall

Remove:

```text
/WIDGETS/GPSQR/
/SCRIPTS/TELEMETRY/GPSQR.lua
/SCRIPTS/TELEMETRY/GPSQR.luac
```

Then restart the radio and remove any GPS QR widget or telemetry-screen assignment from the model.
