#!/usr/bin/env python3
"""Run the real wallpaper store against temporary PosterBoard fixtures on macOS."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix="GX-WallpaperRemoval-") as directory:
    package = Path(directory)
    sources = package / "Sources" / "UninstallTests"
    sources.mkdir(parents=True)
    for name in ("CustomizationFiles.swift", "CustomizationThemes.swift", "CustomizationStore.swift"):
        shutil.copy2(ROOT / "GestaltX" / name, sources / name)
    shutil.copy2(ROOT / "tests/ImportedWallpaperDeletionTests.swift", sources)
    # Localization is irrelevant to filesystem behavior. The iOS bridge is
    # excluded on macOS; tests inject a temporary system-container resolver.
    (sources / "Localization.swift").write_text('func L(_ key: String) -> String { key }\n')
    (package / "Package.swift").write_text('''// swift-tools-version: 5.10
import PackageDescription
let package = Package(
    name: "GXWallpaperTests", platforms: [.macOS(.v13)],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")],
    targets: [.executableTarget(name: "UninstallTests", dependencies: [
        .product(name: "ZIPFoundation", package: "ZIPFoundation")
    ])]
)
''')
    swift = os.environ.get("SWIFT_BIN") or subprocess.check_output(
        ["xcrun", "--find", "swift"], text=True).strip()
    subprocess.run([swift, "run", "--package-path", str(package), "UninstallTests"], check=True)
