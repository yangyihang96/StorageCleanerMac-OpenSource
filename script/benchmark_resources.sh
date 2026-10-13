#!/bin/bash
# Sourced after the caller's existing copy_resource_file; no existing resource is changed.
verify_benchmark_resources() {
  local resources="$1"
  python3 - "$ROOT_DIR/Resources/Benchmark" "$resources/Benchmark" <<'PY'
from pathlib import Path
import hashlib, json, sys
source, destination = map(Path, sys.argv[1:])
for name in ('AppleSiliconCatalog.json', 'AppleSiliconCatalog.manifest.json'):
    if (source / name).read_bytes() != (destination / name).read_bytes():
        raise SystemExit('Benchmark resource copy differs: ' + name)
data = (destination / 'AppleSiliconCatalog.json').read_bytes()
manifest = json.loads((destination / 'AppleSiliconCatalog.manifest.json').read_bytes())
catalog = json.loads(data)
if hashlib.sha256(data).hexdigest() != manifest['sha256']:
    raise SystemExit('Benchmark catalog SHA-256 mismatch')
if catalog['schemaVersion'] != 'apple-silicon-catalog-v2' or catalog['catalogVersion'] != manifest['catalogVersion']:
    raise SystemExit('Benchmark catalog schema/version mismatch')
if not catalog['chips'] or len({c['id'] for c in catalog['chips']}) != len(catalog['chips']):
    raise SystemExit('Benchmark catalog chip structure invalid')
ids = set()
for chip in catalog['chips']:
    for sku in chip['skus']:
        if sku['id'] in ids or not 0 <= sku['cpuOption'] < len(chip['cpu']) or sku['gpuCores'] not in chip['gpuCoreOptions']:
            raise SystemExit('Benchmark catalog SKU structure invalid')
        ids.add(sku['id'])
PY
}

copy_benchmark_resources() {
  /bin/mkdir -p "$APP_RESOURCES/Benchmark"
  copy_resource_file "$ROOT_DIR/Resources/Benchmark/AppleSiliconCatalog.json" "$APP_RESOURCES/Benchmark/AppleSiliconCatalog.json"
  copy_resource_file "$ROOT_DIR/Resources/Benchmark/AppleSiliconCatalog.manifest.json" "$APP_RESOURCES/Benchmark/AppleSiliconCatalog.manifest.json"
  verify_benchmark_resources "$APP_RESOURCES"
}
