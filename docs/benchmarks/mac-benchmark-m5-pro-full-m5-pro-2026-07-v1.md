# Mac 跑分 M5 Pro full 校准报告

- Baseline: `m5-pro-2026-07-v1`
- Workload: `mac-benchmark-full-v2`
- Harness: `swiftpm-release-xctest.v1` (optimized Release)
- Harness app version: `1.5.0`
- Harness app build: `202607161945`
- Reference: MacBook Pro Mac17,9 · Apple M5 Pro · 18 cores · 48 GB
- Valid release runs: 8
- Independent sessions: 2
- Maximum accepted within-run and standard aggregate CV: 0.050000000
- Maximum accepted GPU aggregate CV: 0.100000000
- Frozen at: 2026-07-16T12:59:33.000Z
- Calibration document SHA-256: `fc7193404754361399b74774da0440990d6b00f306dc3272f18590b1454c2794`
- Baseline report SHA-256: `3155785961eec4bcc00fdc0194897e274714d3e30dc8a14ac283c8f5b69baa02`

| Component | Reference median | Across-run CV |
| --- | ---: | ---: |
| cpuSingle | 417.950747881 | 0.005501403 |
| cpuMulti | 6874.786379236 | 0.010553946 |
| gpu | 3156.265008763 | 0.077561880 |
| memory | 57.693798641 | 0.028804994 |
| diskRead | 0.189709499 | 0.015183012 |
| diskWrite | 10.058769791 | 0.004519103 |

本报告只含聚合指标、非设备唯一硬件描述、非设备唯一 session 标签与源记录 SHA-256；不含序列号、硬件 UUID、用户名、路径或 IP。
