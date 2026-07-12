# Contributing

Contributions are welcome for radio compatibility, performance, testing, documentation, and user experience.

## Before opening a pull request

1. Create a focused branch.
2. Modify the documented files under `src/`, never the generated files under `dist/` directly.
3. Keep Lua compatible with the EdgeTX Lua runtime used by the supported firmware range.
4. Add detailed inline documentation for every new function.
5. Keep change history out of Lua comments; describe changes in `CHANGELOG.md` and the release note.
6. Run the complete local pipeline:

   ```bash
   make release
   ```

7. Confirm `git diff --exit-code -- dist` is clean after rebuilding.

## Coding guidelines

- Prefer local variables and functions to reduce global-state collisions.
- Avoid allocating tables or strings in high-frequency callbacks unless necessary.
- Treat telemetry as intermittent; preserve the last valid fix.
- Keep QR modules pure black and white even on grayscale displays.
- Use integer microdegrees for position comparison and formatting.
- Build LVGL objects with coordinates local to the widget zone.
- Keep the color widget self-contained; do not add cross-directory `loadScript()` dependencies.
- Keep monochrome generation cooperative rather than performing all masks in one callback.

## Pull request evidence

Include:

- Radio model and EdgeTX version, if hardware-tested.
- Screen dimensions and display class.
- GPS telemetry protocol and sensor label.
- Test output from `npm test`.
- Photos or screenshots only after removing sensitive coordinates.

## Reporting compatibility

A successful report should identify whether testing was physical, EdgeTX Simulator, or host harness. Do not mark a radio as physically validated based only on matching resolution or simulator behavior.
