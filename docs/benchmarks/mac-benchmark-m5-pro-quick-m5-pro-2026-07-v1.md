# Mac 跑分 M5 Pro quick 校准报告

- Baseline: `m5-pro-2026-07-v1`
- Workload: `mac-benchmark-quick-v2`
- Harness: `swiftpm-release-xctest.v1` (optimized Release)
- Harness app version: `1.5.0`
- Harness app build: `202607161945`
- Reference: MacBook Pro Mac17,9 · Apple M5 Pro · 18 cores · 48 GB
- Valid release runs: 8
- Independent sessions: 2
- Maximum accepted within-run and standard aggregate CV: 0.050000000
- Maximum accepted GPU aggregate CV: 0.100000000
- Frozen at: 2026-07-16T12:59:33.000Z
- Calibration document SHA-256: `fc8a3187965b269291abc707a0ab95dec312f0c4c47d6c0112aa6aa7555b9f63`
- Baseline report SHA-256: `0a48ff085a94f931013e5d69ecdc154da9bcb2e28cb35afdab4a52445da31a7e`

| Component | Reference median | Across-run CV |
| --- | ---: | ---: |
| cpuSingle | 421.105805192 | 0.021287809 |
| cpuMulti | 6966.392962428 | 0.004981030 |
| gpu | 3142.230855926 | 0.076431571 |
| memory | 58.422796998 | 0.031164850 |
| diskRead | 0.191891652 | 0.022783165 |
| diskWrite | 10.183236981 | 0.008355316 |

本报告只含聚合指标、非设备唯一硬件描述、非设备唯一 session 标签与源记录 SHA-256；不含序列号、硬件 UUID、用户名、路径或 IP。
