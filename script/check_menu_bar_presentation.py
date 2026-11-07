#!/usr/bin/env python3
"""Static menu-bar presentation guards.

Shared by script/verify_menu_bar_performance.sh and script/verify_cloud.sh.
Budgets and UI visibility stay in the Swift tests; this file only checks
source that must not do blocking work on the live presentation path.
"""
from pathlib import Path

root = Path(__file__).resolve().parent.parent / "Sources/StorageCleanerMac/Views"
advanced = root / "MenuBarAdvanced"
for name in [
    "GeekProcessorView.swift",
    "GeekMemoryView.swift",
    "GeekDiskView.swift",
    "GeekNetworkView.swift",
    "MenuBarGeekPanel.swift",
]:
    text = (advanced / name).read_text()
    for forbidden in [
        "store.refreshEnergyImpact(",
        "store.refreshMemory(",
        "Shell.run(",
        "Shell.capture(",
        "Process()",
    ]:
        if forbidden in text:
            raise SystemExit(
                f"{name}: blocking/whole-window work in live presentation: {forbidden}"
            )

settings = (root / "SettingsView.swift").read_text()
if "@State private var launchAtLoginStatus = SMAppService" in settings:
    raise SystemExit("Hidden Settings scene must not query a system service during construction")

charts = (advanced / "MenuBarGeekCharts.swift").read_text()
disk = charts.split("struct GeekDiskIOChart: View {")[1].split("struct GeekHoverValue")[0]
if "points.map" in disk or "displayBuckets(" in disk:
    raise SystemExit("Disk preparation leaked into draw/hover path")

print("menu-bar presentation checks passed")
