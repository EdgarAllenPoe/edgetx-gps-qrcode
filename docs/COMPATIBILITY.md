# Compatibility

## Display classes

| Display class | EdgeTX entry point | QR renderer | Status |
|---|---|---|---|
| Color LCD | Widget | Native `lvgl.qrcode` | Supported on EdgeTX 2.11+ |
| One-bit LCD | Telemetry script | Embedded Version 2-L encoder | Supported; hardware validation recommended |
| Grayscale LCD | Telemetry script | Embedded Version 2-L encoder | Supported; hardware validation recommended |
| Touch color LCD | Widget | Native QR plus touch control | Touch optional |
| Key-only color LCD | Widget | Native QR plus Enter control | Supported |

## Firmware

- **Color radios:** EdgeTX 2.11 or later is required because `lvgl.qrcode` was introduced in 2.11.
- **Monochrome/grayscale radios:** the code relies on long-standing telemetry and Lua 5.2/`bit32` APIs. Release testing targets modern EdgeTX builds; older firmware should be treated as unverified.

## Screen geometry

The color layout derives its orientation and dimensions from the assigned widget zone. Host tests cover:

- 480×272 landscape.
- 320×480 portrait.
- 800×480 wide landscape.
- Compact embedded zones that suppress an undersized QR.

The monochrome layout derives module scale and side-panel placement from `LCD_W` and `LCD_H`. Host tests cover:

- 128×64 one-bit.
- 212×64 grayscale.

Unusual dimensions use conservative fallback layout rules.

## Radio-specific behavior

- **RadioMaster TX16S:** physically validated with the color widget.
- **Jumper T14:** the telemetry script automatically selects inverted polarity from the normalized radio identifier; this is host-tested.
- **Other radios:** compatibility is inferred from EdgeTX APIs and tested display classes, not from physical validation unless explicitly documented.

## GPS protocols

GPS QR is protocol-agnostic after EdgeTX creates a GPS-coordinate telemetry sensor. It can work with telemetry delivered through CRSF/ExpressLRS, FrSky, MULTI, FlySky, or other supported protocols, provided `getValue()` returns a GPS table with `lat` and `lon`.

Flight-controller and receiver configuration remains protocol-specific and is outside this project's control.

## Payload limits

The monochrome encoder is specialized for QR Version 2-L and a maximum byte-mode payload of 32 bytes. Six-decimal `geo:` coordinates fit within that limit, including geographic extrema:

```text
geo:-90.000000,-180.000000
```

The color widget uses EdgeTX's native encoder and is not constrained by the embedded Version 2 specialization for its normal GPS payload.

## Validation terminology

- **Physically validated:** tested on a real transmitter.
- **Simulator validated:** tested with EdgeTX Simulator.
- **Host validated:** executed in the repository's Lua harness and checked independently.

Do not treat matching resolution alone as proof of hardware validation.
