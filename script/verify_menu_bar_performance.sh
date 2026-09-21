#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# Runs locally only. Budgets are fixed in MenuBarPerformancePolicy and must
# not be increased to accommodate a regression. UI visibility is audited separately.
python3 - <<'PY'
from pathlib import Path
root = Path('Sources/StorageCleanerMac/Views/MenuBarAdvanced')
for name in ['GeekProcessorView.swift', 'GeekMemoryView.swift', 'GeekDiskView.swift', 'GeekNetworkView.swift', 'MenuBarGeekPanel.swift']:
    text = (root / name).read_text()
    for forbidden in ['store.refreshEnergyImpact(', 'store.refreshMemory(', 'Shell.run(', 'Shell.capture(', 'Process()']:
        assert forbidden not in text, f'{name}: blocking/whole-window work in live presentation: {forbidden}'
settings = (root.parent / 'SettingsView.swift').read_text()
assert '@State private var launchAtLoginStatus = SMAppService' not in settings, 'Hidden Settings scene must not query a system service during construction'
charts = (root / 'MenuBarGeekCharts.swift').read_text()
disk = charts.split('struct GeekDiskIOChart: View {')[1].split('struct GeekHoverValue')[0]
assert 'points.map' not in disk and 'displayBuckets(' not in disk, 'Disk preparation leaked into draw/hover path'
PY
swift test -c release --scratch-path "${STORAGE_CLEANER_VERIFY_ROOT:-/tmp/storage-cleaner-verify}/release" \
  --jobs "${SWIFT_BUILD_JOBS:-2}" --filter MenuBarPerformanceRegressionTests
