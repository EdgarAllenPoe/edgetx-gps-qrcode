# Development

## Prerequisites

- Node.js 18 or later.
- Python 3.10 or later.
- `texlua` from TeX Live.
- A C/C++ toolchain is not required for host tests.

Install dependencies:

```bash
npm ci
python3 -m pip install -r requirements-dev.txt
```

## Source of truth

Edit only:

```text
src/color/main.lua
src/monochrome/GPSQR.lua
```

Files under `dist/` are generated. The readable distribution is an exact copy of `src/`; the minified distribution is produced by `luamin`.

## Build

```bash
npm run build
```

The build script:

1. Normalizes line endings.
2. Copies documented source into `dist/readable/` using the exact SD-card layout.
3. Minifies each source with `luamin`.
4. Prepends a compact license/source pointer.
5. Writes radio-ready files to `dist/minified/`.

## Documentation policy

Every local Lua function must have a named long-comment block immediately before it. Inline documentation must describe current behavior, parameters, returns, invariants, and side effects.

Do not write release-history language in Lua comments. Put changes in:

- `CHANGELOG.md`.
- `docs/releases/<version>.md`.

`tools/verify_repository.py` checks function-documentation coverage.

## Performance rules

### Color

- Keep the widget self-contained.
- Do not add `loadScript()` dependencies.
- Avoid rebuilding LVGL objects on every refresh callback.
- Use local zone coordinates, not `xabs`/`yabs`, for child objects.
- Keep QR foreground and background colors high contrast.

### Monochrome

- Keep QR generation cooperative.
- Avoid textual bit strings and nested cell tables.
- Keep high-frequency drawing allocation-free.
- Preserve the last completed QR until a replacement is valid.
- Test both normal and inverted polarity.

## Configuration constants

The readable monochrome source exposes policy constants near the top, including:

```lua
local POLARITY_OVERRIDE = "automatic"
local AUTO_REFRESH = false
local AUTO_REFRESH_INTERVAL_TICKS = 30 * 100
local MINIMUM_MOVEMENT_E6 = 20
```

After changing constants, rebuild and test before copying to a radio.

## Complete local pipeline

```bash
make release
```

This builds, tests, verifies repository invariants, creates both SD archives, and writes checksums.
