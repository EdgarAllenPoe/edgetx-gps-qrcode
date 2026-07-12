# Testing

## Host test pipeline

Run:

```bash
npm ci
npm run build
python3 -m pip install -r requirements-dev.txt
npm test
npm run verify
```

The Python suite executes Lua through `texlua` and parses every source with `luaparse`.

## Color harness

The color harness supplies:

- EdgeTX version and display constants.
- A renamed configured GPS sensor.
- A live `getValue()` GPS table.
- An LVGL specification recorder.

It verifies native QR payloads and layout behavior for landscape, portrait, wide, and compact zones.

## Monochrome harness

The monochrome harness supplies:

- One-bit or grayscale display capability.
- Multiple configured GPS sensors.
- One silent GPS and one renamed live GPS.
- LCD rectangle drawing into a PGM pixel buffer.

OpenCV independently decodes the rendered PGM. This verifies the complete chain from telemetry coordinates through Reed-Solomon, masking, matrix placement, cached runs, and LCD geometry.

## Repository checks

`npm run verify` confirms:

- Required GitHub and user documentation exists.
- Every local Lua function has detailed inline documentation.
- Both sources report the same release version.
- The color widget contains no `loadScript()` dependency.
- Unit-based sensor discovery remains present.
- Readable dist files exactly match source.
- Minified files are smaller than source.

## Physical-radio matrix

Before describing a radio as physically supported, record:

| Field | Example |
|---|---|
| Radio | RadioMaster TX16S |
| EdgeTX | 2.12.x |
| Display | 480×272 color touch |
| GPS path | CRSF / flight controller |
| Sensor label | Position |
| Embedded view | Pass |
| Full screen | Pass |
| Phone scan | Pass |
| Telemetry loss | Last fix retained |
| CPU/UI behavior | Responsive |

For monochrome radios, also test:

- Normal and inverted display polarity.
- QR generation while telemetry updates.
- Opening and closing the telemetry screen.
- Repeated refreshes without memory growth.
- Mixer and UI responsiveness.

## Test limitations

Host tests cannot reproduce:

- Real transmitter instruction scheduling.
- Lua heap fragmentation over long sessions.
- SD-card latency and corruption.
- Panel contrast, glare, or replacement displays.
- Touch calibration.
- Phone-camera autofocus outdoors.
