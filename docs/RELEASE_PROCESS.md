# Release process

## 1. Update the version

Keep these values aligned:

- `VERSION`.
- `package.json`.
- `src/color/main.lua` — `APP_VERSION`.
- `src/monochrome/GPSQR.lua` — `SCRIPT_VERSION`.
- `tools/build.js` and `tools/package_release.py`.
- `CHANGELOG.md`.
- `docs/releases/<version>.md`.

## 2. Update documentation

- Describe runtime changes in the changelog and release note.
- Update compatibility and troubleshooting when behavior changes.
- Document every new function inline without mentioning prior versions.
- Record physical-radio validation separately from host validation.

## 3. Build and verify

```bash
npm ci
python3 -m pip install -r requirements-dev.txt
make release
```

The command must complete without warnings or failed QR decodes.

## 4. Review generated artifacts

Confirm:

```text
dist/minified/WIDGETS/GPSQR/main.lua
dist/minified/SCRIPTS/TELEMETRY/GPSQR.lua
dist/readable/WIDGETS/GPSQR/main.lua
dist/readable/SCRIPTS/TELEMETRY/GPSQR.lua
dist/GPSQR-v<version>-SD-minified.zip
dist/GPSQR-v<version>-SD-readable.zip
dist/SHA256SUMS
```

Open each ZIP and verify that `WIDGETS/` and `SCRIPTS/` are at the archive root.

## 5. Check generated-file cleanliness

```bash
git diff --exit-code -- dist
```

Commit source and generated distribution changes together so a GitHub checkout always contains installable files.

## 6. Hardware smoke test

At minimum:

- Re-test one physically available color radio.
- Re-test one representative monochrome or grayscale radio when that backend changes.
- Scan a QR with an independent phone application.
- Confirm exact coordinates using non-sensitive test data.

## 7. Tag and publish

Create an annotated tag:

```bash
git tag -a v<version> -m "GPS QR v<version>"
git push origin main --tags
```

Create a GitHub Release from the tag and attach:

- `GPSQR-v<version>-SD-minified.zip`.
- `GPSQR-v<version>-SD-readable.zip`.
- `SHA256SUMS`.

Use the corresponding file from `docs/releases/` as the release description.
