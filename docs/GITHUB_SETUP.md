# GitHub repository setup

## Suggested repository metadata

- **Name:** `edgetx-gps-qrcode`
- **Description:** Universal EdgeTX GPS telemetry QR widget and telemetry script
- **Topics:** `edgetx`, `lua`, `gps`, `qrcode`, `radiomaster`, `rc`, `telemetry`
- **License:** BSD 3-Clause

## Initial publication

From the repository directory:

```bash
git init
git add .
git commit -m "Publish GPS QR v10.10.7 universal release"
git branch -M main
git remote add origin <repository-url>
git push -u origin main
```

## Recommended settings

- Enable GitHub Actions.
- Protect `main` after the first successful workflow run.
- Require the `verify` workflow before merge.
- Enable private vulnerability reporting.
- Enable Issues and Discussions if community hardware reports are desired.
- Use squash or rebase merging to keep release history readable.

## Releases

Create a GitHub Release for each version tag and attach both SD-card archives. The minified archive should be marked as the normal installation package; the readable archive is for auditing and customization.

## Issue triage

The included bug template asks for radio, firmware, display class, GPS protocol, and exact messages. Apply labels such as:

- `color-radio`
- `monochrome-radio`
- `grayscale-radio`
- `sensor-discovery`
- `qr-scan`
- `performance`
- `documentation`
- `hardware-validated`

## Sensitive data

Remind contributors to redact coordinates from screenshots, logs, and QR images before posting publicly.
