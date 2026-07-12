# Test suite

The host suite validates both EdgeTX entry points without requiring a physical transmitter.

## Coverage

- Lua syntax for documented source, readable distributions, and minified distributions.
- Unit-based discovery of renamed GPS sensors.
- Selection of a live GPS when more than one GPS sensor is configured.
- Exact QR decoding on 128×64 one-bit and 212×64 grayscale displays.
- Automatic Jumper T14 inverted-polarity profile.
- Color layouts at 480×272, 320×480, and 800×480.
- Compact color zones that direct the user to full-screen mode.

## Requirements

- Python 3.10 or later.
- Node.js 18 or later and `npm ci` completed.
- `texlua` from TeX Live.
- OpenCV Python bindings (`opencv-python-headless`).

## Run

```bash
npm ci
npm run build
python3 -m pip install -r requirements-dev.txt
python3 tests/test_universal.py
```

Physical-radio testing remains important because the harness cannot reproduce transmitter CPU scheduling, panel polarity, SD-card timing, touch calibration, or outdoor phone-camera conditions.
