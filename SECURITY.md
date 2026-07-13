# Security and privacy

## Supported release

Security and privacy fixes are applied to the latest release line.

## Reporting a vulnerability

Please report vulnerabilities privately to the repository maintainer through GitHub's private vulnerability reporting feature when enabled. Avoid opening a public issue containing exploit details or private coordinates.

Useful information includes:

- GPS QR version.
- Radio model and EdgeTX version.
- Whether the issue affects the color widget, telemetry script, or build tooling.
- Reproduction steps using non-sensitive test coordinates.

## Location privacy

A GPS QR code directly encodes a geographic position. Anyone who can scan the display, view a photograph, or access a screenshot can recover those coordinates. The project does not transmit coordinates over the network, but users must treat generated QR images as sensitive data.

## Flight safety

This project is a recovery aid, not a flight-critical navigation system. Telemetry can be stale, interrupted, misconfigured, or unavailable. Confirm the fix age and use independent recovery procedures. Validate performance on the intended radio before leaving the monochrome QR screen open during flight.
