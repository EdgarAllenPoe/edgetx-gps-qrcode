# Changelog

All notable project changes are documented here. Runtime source comments describe current behavior only; release history belongs in this file and the release notes under `docs/releases/`.

## [10.10.7] - 2026-07-12

### Added

- Universal SD-card package containing both color-widget and monochrome telemetry entry points.
- Unit-based discovery of renamed GPS sensors on every display class.
- Multiple-GPS selection that prefers a source currently returning valid coordinates.
- Responsive color layouts for landscape, portrait, full-screen, and compact zones.
- Native `lvgl.qrcode` rendering on EdgeTX 2.11+ color radios.
- Fixed Version 2-L encoder for one-bit and grayscale radios.
- Packed QR rows, cooperative Reed-Solomon work, mask scoring, and cached rectangle runs.
- Radio-aware display polarity and work-budget defaults, including Jumper T14 inversion.
- Host tests with independent QR decoding.

### Validated

- Physical color-radio operation on RadioMaster TX16S.
- Host-rendered 128×64 one-bit and 212×64 grayscale output.
- Host-simulated 480×272, 320×480, and 800×480 color layouts.

[10.10.7]: docs/releases/v10.10.7.md
