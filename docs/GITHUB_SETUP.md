# GitHub repository setup

## Repository metadata

- **Name:** `edgetx-gps-qrcode`
- **Description:** Universal EdgeTX GPS telemetry QR widget and telemetry script
- **Topics:** `edgetx`, `lua`, `gps`, `qrcode`, `radiomaster`, `rc`, `telemetry`
- **License:** BSD 3-Clause
- **Default branch:** `master`

This repository is maintained as a fork of `alufers/edgetx-gps-qrcode`, so GitHub may also show how many commits the fork is ahead of or behind the upstream `master` branch.

## Initial publication

From the repository directory:

```bash
git init
git add .
git commit -m "Publish GPS QR universal release"
git branch -M master
git remote add origin <repository-url>
git push -u origin master
```

For this existing fork, do not reinitialize the repository. Work from the current clone and pull remote changes before pushing:

```bash
git switch master
git pull --rebase origin master
```

## Recommended settings

- Enable GitHub Actions.
- Protect `master` after the first successful workflow run.
- Require the `verify` workflow before merging pull requests.
- Enable private vulnerability reporting.
- Enable Issues and Discussions if community hardware reports are desired.
- Use squash or rebase merging to keep development history readable.

## Continuous integration

The workflow in `.github/workflows/ci.yml` runs on pushes and pull requests. It:

1. Checks out the repository.
2. Installs Node.js and Python.
3. Installs public npm dependencies from `package-lock.json`.
4. Installs Python test dependencies from `requirements-dev.txt`.
5. Builds readable and minified distributions.
6. Runs the host and independent QR-decoding tests.
7. Verifies repository invariants.
8. Rebuilds release archives and checks that committed `dist/` files are current.

The Python cache configuration must include:

```yaml
cache: pip
cache-dependency-path: requirements-dev.txt
```

The committed `package-lock.json` must use public `https://registry.npmjs.org/` package URLs and must not reference private build-environment registries.

## Releases

Create a GitHub Release for each version tag and attach:

- `GPSQR-v<version>-SD-minified.zip` — normal installation package.
- `GPSQR-v<version>-SD-readable.zip` — documented package for auditing and customization.
- `SHA256SUMS` — release integrity checks.

The v10.10.7 release is published by `.github/workflows/release-v10.10.7.yml`. That workflow has `contents: write` permission and creates the tag and release assets from the committed files under `dist/`.

Future releases should replace or generalize the version-specific workflow rather than leaving multiple active one-time workflows.

## Working with this fork

When opening a pull request for changes intended only for this fork, verify that the destination says:

```text
EdgarAllenPoe:master
```

Do not accidentally target:

```text
alufers:master
```

A pull request into the upstream repository requires upstream maintainer approval and may trigger separate workflow-approval rules.

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
