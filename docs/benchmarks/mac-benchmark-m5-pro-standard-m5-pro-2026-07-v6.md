# Mac 跑分 M5 Pro standard 校准报告

- Baseline: `m5-pro-2026-07-v6`
- Workload: `mac-benchmark-standard-v6`
- Harness: `swiftpm-release-xctest.v1` (optimized Release)
- Harness app version: `1.8.2`
- Harness app build: `202607172016`
- Reference: MacBook Pro Mac17,9 · Apple M5 Pro · 18 cores · 48 GB
- Valid release runs: 8
- Independent sessions: 2
- Maximum accepted within-run and standard aggregate CV: 0.050000000
- Maximum accepted GPU aggregate CV: 0.100000000
- Maximum accepted durable-write aggregate CV: 0.100000000
- Frozen at: 2026-07-17T15:06:40.000Z
- Calibration document SHA-256: `86ca44383e3b8667e4529a7da449e353a3d6ac7e6778d876a64562b2a17f4861`
- Baseline report SHA-256: `e5feddf7f178959b581de45ed0375fd511c814a30967f9ce0a8f9d2d5ea166f8`

| Component | Reference median | Across-run CV |
| --- | ---: | ---: |
| cpuSingle | 420.573051504 | 0.027130672 |
| cpuMulti | 6946.964858254 | 0.013243883 |
| gpu | 3078.317339594 | 0.067024990 |
| memory | 29.989172821 | 0.045008140 |
| diskRead | 0.197967240 | 0.019807976 |
| diskWrite | 2.029915387 | 0.018094289 |

本报告只含聚合指标、非设备唯一硬件描述、非设备唯一 session 标签与源记录 SHA-256；不含序列号、硬件 UUID、用户名、路径或 IP。
