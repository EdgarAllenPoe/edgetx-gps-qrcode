#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OLD = "10.10.7"
NEW = "10.10.8"


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def write(path, text):
    target = ROOT / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8", newline="\n")


def repl(path, old, new, count=None):
    text = read(path)
    found = text.count(old)
    if found == 0 or (count is not None and found != count):
        raise RuntimeError(f"{path}: expected {count}, found {found}: {old!r}")
    write(path, text.replace(old, new))


write("VERSION", NEW + "\n")
for path, old, new, count in [
    ("package.json", f'"version": "{OLD}"', f'"version": "{NEW}"', 1),
    ("package-lock.json", f'"version": "{OLD}"', f'"version": "{NEW}"', 2),
    ("tools/build.js", f"const version = '{OLD}';", f"const version = '{NEW}';", 1),
    ("tools/package_release.py", f'VERSION = "{OLD}"', f'VERSION = "{NEW}"', 1),
    ("tools/verify_repository.py", f'VERSION = "{OLD}"', f'VERSION = "{NEW}"', 1),
    ("src/color/main.lua", OLD, NEW, None),
    ("src/monochrome/GPSQR.lua", OLD, NEW, None),
    ("README.md", OLD, NEW, None),
    ("docs/INSTALLATION.md", OLD, NEW, None),
    ("docs/GITHUB_SETUP.md", OLD, NEW, None),
]:
    repl(path, old, new, count)

repl(
    "src/color/main.lua",
    'widget.payload = "geo:" .. widget.latitudeText .. "," .. widget.longitudeText',
    'widget.payload = "geo:0,0?q=" .. widget.latitudeText .. "," .. widget.longitudeText',
    1,
)
repl(
    "src/monochrome/GPSQR.lua",
    'local payload = "geo:" .. requestedLatitudeText .. "," .. requestedLongitudeText',
    'local payload = "geo:0,0?q=" .. requestedLatitudeText .. "," .. requestedLongitudeText',
    1,
)

for old, new in {
    "geo:40.712800,-74.006000": "geo:0,0?q=40.712800,-74.006000",
    "geo:-90.000000,-180.000000": "geo:0,0?q=-90.000000,-180.000000",
    "geo:51.507351,-0.127758": "geo:0,0?q=51.507351,-0.127758",
}.items():
    repl("tests/test_universal.py", old, new)

# The Lua color harness contains its own exact version and payload assertions.
# Keep those expectations synchronized with the source modified above.
repl("tests/color_harness.lua", OLD, NEW, 1)
repl(
    "tests/color_harness.lua",
    'assert(qr.data == "geo:40.712800,-74.006000", "wrong color QR payload")',
    'assert(qr.data == "geo:0,0?q=40.712800,-74.006000", "wrong color QR payload")',
    1,
)

repl(
    "docs/USER_GUIDE.md",
    "geo:<latitude>,<longitude>",
    "geo:0,0?q=<latitude>,<longitude>",
    1,
)
repl(
    "docs/ARCHITECTURE.md",
    "geo:<latitude>,<longitude>",
    "geo:0,0?q=<latitude>,<longitude>",
    1,
)
repl(
    "docs/COMPATIBILITY.md",
    "geo:-90.000000,-180.000000",
    "geo:0,0?q=-90.000000,-180.000000",
    1,
)

changelog = read("CHANGELOG.md")
marker = "## Unreleased\n"
if marker not in changelog:
    raise RuntimeError("CHANGELOG.md: Unreleased heading missing")
entry = """## Unreleased

## [10.10.8] - 2026-07-14

### Changed

- Changed both QR payload builders to `geo:0,0?q=<latitude>,<longitude>` so compatible map applications, including Google Maps, place a marker at the scanned position.
- Added host verification for the marker-compatible payload, including the 32-byte geographic-extrema case.

"""
changelog = changelog.replace(marker, entry, 1)
link = "[10.10.7]: docs/releases/v10.10.7.md"
changelog = changelog.replace(
    link,
    "[10.10.8]: docs/releases/v10.10.8.md\n" + link,
    1,
)
write("CHANGELOG.md", changelog)

write(
    "docs/releases/v10.10.8.md",
    """# GPS QR v10.10.8

Both EdgeTX entry points now encode coordinates as:

```text
geo:0,0?q=<latitude>,<longitude>
```

This asks compatible mapping applications, including Google Maps, to place a location pin at the scanned coordinates. Six-decimal precision is unchanged.

The longest possible payload remains exactly 32 bytes:

```text
geo:0,0?q=-90.000000,-180.000000
```

This still fits the monochrome Version 2-L encoder.

## Installation

Download `GPSQR-v10.10.8-SD-minified.zip`, extract it to the SD-card root, delete stale `.luac` files, and restart the radio.
""",
)

extreme = "geo:0,0?q=-90.000000,-180.000000"
assert len(extreme.encode("ascii")) == 32
for path in ("src/color/main.lua", "src/monochrome/GPSQR.lua"):
    text = read(path)
    assert "geo:0,0?q=" in text
