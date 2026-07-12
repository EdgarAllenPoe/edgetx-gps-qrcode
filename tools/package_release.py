#!/usr/bin/env python3
"""Create deterministic SD-card archives for the readable and minified builds.

The ZIP files open directly to WIDGETS/ and SCRIPTS/, allowing users to extract
an archive onto the SD-card root without introducing an extra enclosing folder.
Documentation and checksums are included beside the radio files so an archive
remains self-explanatory when downloaded from a GitHub Release page.
"""

from __future__ import annotations

import hashlib
import os
import stat
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"
VERSION = "10.10.7"
FIXED_ZIP_TIME = (2024, 1, 1, 0, 0, 0)

INSTALL_TEXT = f"""GPS QR v{VERSION} UNIVERSAL INSTALLATION

Copy the WIDGETS and SCRIPTS directories to the root of the radio SD card.

Color radios:
  /WIDGETS/GPSQR/main.lua
  Add the \"GPS QR\" widget to a Main View. EdgeTX 2.11 or later is required.

Black-and-white or grayscale radios:
  /SCRIPTS/TELEMETRY/GPSQR.lua
  Assign GPSQR as a telemetry screen in the active model.

Delete stale files named main.luac or GPSQR.luac before restarting the radio.
The active model must contain a configured telemetry sensor with UNIT_GPS.
"""


def sha256(path: Path) -> str:
    """Return the lowercase SHA-256 digest of one file."""

    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def zip_info(name: str) -> zipfile.ZipInfo:
    """Create a stable ZIP metadata record independent of the build machine."""

    info = zipfile.ZipInfo(name, FIXED_ZIP_TIME)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = (stat.S_IFREG | 0o644) << 16
    return info


def add_bytes(archive: zipfile.ZipFile, name: str, content: bytes) -> None:
    """Write generated content with deterministic metadata."""

    archive.writestr(zip_info(name), content)


def add_file(archive: zipfile.ZipFile, source: Path, name: str) -> None:
    """Write a repository file to an archive using a selected archive path."""

    add_bytes(archive, name, source.read_bytes())


def create_archive(flavor: str) -> Path:
    """Package one dist flavor and return the completed archive path."""

    source_root = DIST / flavor
    archive_path = DIST / f"GPSQR-v{VERSION}-SD-{flavor}.zip"
    radio_files = sorted(path for path in source_root.rglob("*") if path.is_file())

    if not radio_files:
        raise RuntimeError(f"No files found under {source_root}; run npm run build first")

    checksums = []
    for file_path in radio_files:
        relative = file_path.relative_to(source_root).as_posix()
        checksums.append(f"{sha256(file_path)}  {relative}")

    with zipfile.ZipFile(archive_path, "w") as archive:
        for file_path in radio_files:
            relative = file_path.relative_to(source_root).as_posix()
            add_file(archive, file_path, relative)
        add_bytes(archive, "GPSQR-INSTALL.txt", INSTALL_TEXT.encode("utf-8"))
        add_file(archive, ROOT / "LICENSE", "LICENSE")
        add_file(archive, ROOT / "THIRD_PARTY_NOTICES.md", "THIRD_PARTY_NOTICES.md")
        add_file(archive, ROOT / "CHANGELOG.md", "CHANGELOG.md")
        add_bytes(
            archive,
            "SHA256SUMS",
            ("\n".join(checksums) + "\n").encode("utf-8"),
        )

    return archive_path


def main() -> None:
    """Create both archives and a repository-level checksum manifest."""

    DIST.mkdir(parents=True, exist_ok=True)
    archives = [create_archive("minified"), create_archive("readable")]
    manifest_lines = []

    for archive in archives:
        manifest_lines.append(f"{sha256(archive)}  {archive.name}")
        print(f"created {archive.relative_to(ROOT)} ({archive.stat().st_size} bytes)")

    (DIST / "SHA256SUMS").write_text("\n".join(manifest_lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
