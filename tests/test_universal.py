#!/usr/bin/env python3
"""End-to-end host verification for both EdgeTX display families.

The test suite does more than parse Lua. It executes each entry point inside a
small EdgeTX-compatible harness, renders monochrome frames to PGM images, and
uses OpenCV as an independent QR decoder. This catches QR encoding, matrix,
layout, and renderer regressions that syntax-only checks cannot detect.
"""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

import cv2

ROOT = Path(__file__).resolve().parents[1]
COLOR_SOURCE = ROOT / "src" / "color" / "main.lua"
MONO_SOURCE = ROOT / "src" / "monochrome" / "GPSQR.lua"
COLOR_READABLE = ROOT / "dist" / "readable" / "WIDGETS" / "GPSQR" / "main.lua"
MONO_READABLE = ROOT / "dist" / "readable" / "SCRIPTS" / "TELEMETRY" / "GPSQR.lua"
COLOR_MINIFIED = ROOT / "dist" / "minified" / "WIDGETS" / "GPSQR" / "main.lua"
MONO_MINIFIED = ROOT / "dist" / "minified" / "SCRIPTS" / "TELEMETRY" / "GPSQR.lua"
COLOR_HARNESS = ROOT / "tests" / "color_harness.lua"
MONO_HARNESS = ROOT / "tests" / "mono_harness.lua"

CASES = [
    (40.7128, -74.006, "geo:0,0?q=40.712800,-74.006000"),
    (-90.0, -180.0, "geo:0,0?q=-90.000000,-180.000000"),
    (51.507351, -0.127758, "geo:0,0?q=51.507351,-0.127758"),
]


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    """Execute one required command and return captured text output."""

    return subprocess.run(command, check=True, text=True, capture_output=True)


def decode(path: Path) -> str:
    """Decode one rendered QR image with OpenCV and return its exact payload."""

    image = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
    if image is None:
        raise AssertionError(f"Unable to read rendered image {path}")

    value, points, _ = cv2.QRCodeDetector().detectAndDecode(image)
    if points is None or not value:
        raise AssertionError(f"Unable to decode QR in {path}")
    return value


def check_syntax() -> None:
    """Parse every readable and minified Lua entry point with luaparse."""

    run(
        [
            "npx",
            "--no-install",
            "luaparse",
            "-q",
            str(COLOR_SOURCE),
            str(MONO_SOURCE),
            str(COLOR_READABLE),
            str(MONO_READABLE),
            str(COLOR_MINIFIED),
            str(MONO_MINIFIED),
        ]
    )


def check_monochrome_rendering(temp: Path, script: Path, label: str) -> None:
    """Render and independently decode one-bit and grayscale radio frames."""

    configurations = [
        (128, 64, "boxer-simu", False),
        (212, 64, "x9dp-simu", True),
    ]

    for width, height, radio, grayscale in configurations:
        for index, (latitude, longitude, expected) in enumerate(CASES):
            output = temp / f"{label}_{radio}_{index}.pgm"
            result = run(
                [
                    "texlua",
                    str(MONO_HARNESS),
                    str(script),
                    str(output),
                    repr(latitude),
                    repr(longitude),
                    str(width),
                    str(height),
                    radio,
                    "1" if grayscale else "0",
                    "110",
                ]
            )

            actual = decode(output)
            if actual != expected:
                raise AssertionError(
                    f"{label}/{radio}: expected {expected!r}, decoded {actual!r}"
                )
            if "sensor=NavPos" not in result.stdout:
                raise AssertionError(
                    f"{label}/{radio}: renamed live GPS sensor was not selected\n"
                    + result.stdout
                )


def check_t14_profile(temp: Path, script: Path, label: str) -> None:
    """Verify the automatic inverted-polarity profile for the Jumper T14."""

    output = temp / f"{label}_t14.pgm"
    result = run(
        [
            "texlua",
            str(MONO_HARNESS),
            str(script),
            str(output),
            "40.0",
            "-70.0",
            "128",
            "64",
            "t14-simu",
            "0",
            "110",
        ]
    )
    if "inverted=true" not in result.stdout:
        raise AssertionError(f"{label}: T14 polarity profile not selected: {result.stdout}")


def check_color_widget(script: Path, label: str) -> None:
    """Exercise native color layouts in landscape, portrait, wide, and compact zones."""

    configurations = [
        (480, 272, True, True),
        (320, 480, True, True),
        (800, 480, True, True),
        (120, 80, False, False),
    ]

    for width, height, fullscreen, expect_qr in configurations:
        result = run(
            [
                "texlua",
                str(COLOR_HARNESS),
                str(script),
                str(width),
                str(height),
                "1" if fullscreen else "0",
                "1" if expect_qr else "0",
            ]
        )

        if expect_qr:
            expected = "color_payload=geo:0,0?q=40.712800,-74.006000"
            if expected not in result.stdout:
                raise AssertionError(f"{label}/{width}x{height}: {result.stdout}")
        else:
            expected = "color_status=Open the widget full screen to scan"
            if expected not in result.stdout:
                raise AssertionError(f"{label}/{width}x{height}: {result.stdout}")


def main() -> None:
    """Run syntax, sensor-selection, layout, polarity, and decode verification."""

    check_syntax()

    color_variants = [
        (COLOR_SOURCE, "source"),
        (COLOR_READABLE, "readable-dist"),
        (COLOR_MINIFIED, "minified-dist"),
    ]
    mono_variants = [
        (MONO_SOURCE, "source"),
        (MONO_READABLE, "readable-dist"),
        (MONO_MINIFIED, "minified-dist"),
    ]

    for script, label in color_variants:
        check_color_widget(script, label)

    with tempfile.TemporaryDirectory(prefix="gpsqr-universal-") as directory:
        temp = Path(directory)
        for script, label in mono_variants:
            check_monochrome_rendering(temp, script, label)
            check_t14_profile(temp, script, label)

    print(
        "Verified source, readable dist, and minified dist across color, one-bit, "
        "grayscale, renamed-sensor, responsive-layout, QR-decode, and polarity cases."
    )


if __name__ == "__main__":
    main()
