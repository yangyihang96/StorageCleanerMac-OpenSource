# Mac 跑分 M5 Pro full 校准报告

- Baseline: `m5-pro-2026-07-v3`
- Workload: `mac-benchmark-full-v3`
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
- Calibration document SHA-256: `09e9af893ed4da240ca5390f64d7550cc844a51d38a36b8f33e9d5f7d75cd6dd`
- Baseline report SHA-256: `4a0b5490b01fed924283fdeed3ae06a68160d9e81c26d688c6bb9de32b8a4422`

| Component | Reference median | Across-run CV |
| --- | ---: | ---: |
| cpuSingle | 416.078551210 | 0.020551760 |
| cpuMulti | 6831.154217574 | 0.002398333 |
| gpu | 3380.794256298 | 0.000053517 |
| memory | 29.321334648 | 0.014546087 |
| diskRead | 0.190737780 | 0.004612646 |
| diskWrite | 7.073967103 | 0.009401496 |

本报告只含聚合指标、非设备唯一硬件描述、非设备唯一 session 标签与源记录 SHA-256；不含序列号、硬件 UUID、用户名、路径或 IP。
