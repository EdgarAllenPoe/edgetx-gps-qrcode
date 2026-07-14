#!/usr/bin/env python3
"""Validate repository structure, documentation coverage, and release invariants."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION = "10.10.8"

SOURCE_FILES = [
    ROOT / "src" / "color" / "main.lua",
    ROOT / "src" / "monochrome" / "GPSQR.lua",
]

REQUIRED_FILES = [
    ROOT / "README.md",
    ROOT / "LICENSE",
    ROOT / "THIRD_PARTY_NOTICES.md",
    ROOT / "CHANGELOG.md",
    ROOT / "docs" / "INSTALLATION.md",
    ROOT / "docs" / "COMPATIBILITY.md",
    ROOT / "docs" / "TROUBLESHOOTING.md",
    ROOT / "dist" / "minified" / "WIDGETS" / "GPSQR" / "main.lua",
    ROOT / "dist" / "minified" / "SCRIPTS" / "TELEMETRY" / "GPSQR.lua",
    ROOT / "dist" / "readable" / "WIDGETS" / "GPSQR" / "main.lua",
    ROOT / "dist" / "readable" / "SCRIPTS" / "TELEMETRY" / "GPSQR.lua",
]

FUNCTION_PATTERN = re.compile(r"^local function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(", re.MULTILINE)


def verify_required_files() -> None:
    """Ensure the files expected by users and GitHub automation exist."""

    missing = [str(path.relative_to(ROOT)) for path in REQUIRED_FILES if not path.is_file()]
    if missing:
        raise AssertionError("Missing required files: " + ", ".join(missing))


def verify_function_documentation(path: Path) -> None:
    """Require a named long-comment documentation block before every local function."""

    text = path.read_text(encoding="utf-8")
    for match in FUNCTION_PATTERN.finditer(text):
        name = match.group(1)
        prefix = text[max(0, match.start() - 1600) : match.start()]
        marker = f"{name}()"
        block_start = prefix.rfind("--[=[")
        block_end = prefix.rfind("]=]")
        if block_start == -1 or block_end < block_start or marker not in prefix[block_start:block_end]:
            line = text.count("\n", 0, match.start()) + 1
            raise AssertionError(f"{path.relative_to(ROOT)}:{line}: undocumented function {name}")


def verify_source_contracts() -> None:
    """Check version alignment and self-contained deployment behavior."""

    color = SOURCE_FILES[0].read_text(encoding="utf-8")
    mono = SOURCE_FILES[1].read_text(encoding="utf-8")

    if f'local APP_VERSION = "{VERSION}"' not in color:
        raise AssertionError("color source version does not match repository version")
    if f'local SCRIPT_VERSION = "{VERSION}"' not in mono:
        raise AssertionError("monochrome source version does not match repository version")
    if "loadScript(" in color:
        raise AssertionError("color widget must remain self-contained")
    if "UNIT_GPS" not in color or "UNIT_GPS" not in mono:
        raise AssertionError("both entry points must retain unit-based GPS discovery")


def verify_dist_relationships() -> None:
    """Check that readable dist copies match source and minified files are smaller."""

    pairs = [
        (
            ROOT / "src" / "color" / "main.lua",
            ROOT / "dist" / "readable" / "WIDGETS" / "GPSQR" / "main.lua",
            ROOT / "dist" / "minified" / "WIDGETS" / "GPSQR" / "main.lua",
        ),
        (
            ROOT / "src" / "monochrome" / "GPSQR.lua",
            ROOT / "dist" / "readable" / "SCRIPTS" / "TELEMETRY" / "GPSQR.lua",
            ROOT / "dist" / "minified" / "SCRIPTS" / "TELEMETRY" / "GPSQR.lua",
        ),
    ]

    for source, readable, minified in pairs:
        if source.read_bytes() != readable.read_bytes():
            raise AssertionError(f"readable dist is stale: {readable.relative_to(ROOT)}")
        if minified.stat().st_size >= source.stat().st_size:
            raise AssertionError(f"minified file is not smaller: {minified.relative_to(ROOT)}")


def main() -> None:
    """Run every repository-level invariant check."""

    verify_required_files()
    for source in SOURCE_FILES:
        verify_function_documentation(source)
    verify_source_contracts()
    verify_dist_relationships()
    print("Repository structure, version alignment, documentation coverage, and dist files verified.")


if __name__ == "__main__":
    main()
