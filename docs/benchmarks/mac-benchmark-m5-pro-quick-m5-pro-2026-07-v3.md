# Mac 跑分 M5 Pro quick 校准报告

- Baseline: `m5-pro-2026-07-v3`
- Workload: `mac-benchmark-quick-v3`
- Harness: `swiftpm-release-xctest.v1` (optimized Release)
- Harness app version: `1.6.0`
- Harness app build: `202607170900`
- Reference: MacBook Pro Mac17,9 · Apple M5 Pro · 18 cores · 48 GB
- Valid release runs: 8
- Independent sessions: 2
- Maximum accepted within-run and standard aggregate CV: 0.050000000
- Maximum accepted GPU aggregate CV: 0.100000000
- Maximum accepted durable-write aggregate CV: 0.100000000
- Frozen at: 2026-07-17T01:12:00.000Z
- Calibration document SHA-256: `9254fc76fa09661f2951290651ab683c3cdb203f6cf6ac03c47437beef8aa9f2`
- Baseline report SHA-256: `51f2efb20a70a205621818ec8f7623cc65177349ee425ee114b0d684f0311667`

| Component | Reference median | Across-run CV |
| --- | ---: | ---: |
| cpuSingle | 413.860200614 | 0.039633539 |
| cpuMulti | 6924.682398286 | 0.012220546 |
| gpu | 3319.995753200 | 0.000140893 |
| memory | 29.962937118 | 0.021650568 |
| diskRead | 0.189541012 | 0.030553514 |
| diskWrite | 1.931303243 | 0.096437345 |

本报告只含聚合指标、非设备唯一硬件描述、非设备唯一 session 标签与源记录 SHA-256；不含序列号、硬件 UUID、用户名、路径或 IP。
