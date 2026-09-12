# Mac 跑分 M5 Pro standard 校准报告

- Baseline: `m5-pro-2026-07-v4`
- Workload: `mac-benchmark-standard-v4`
- Harness: `swiftpm-release-xctest.v1` (optimized Release)
- Harness app version: `1.9.0`
- Harness app build: `202607171910`
- Reference: MacBook Pro Mac17,9 · Apple M5 Pro · 18 cores · 48 GB
- Valid release runs: 8
- Independent sessions: 2
- Maximum accepted within-run and standard aggregate CV: 0.050000000
- Maximum accepted GPU aggregate CV: 0.100000000
- Maximum accepted durable-write aggregate CV: 0.100000000
- Frozen at: 2026-07-17T09:33:27.000Z
- Calibration document SHA-256: `220a7c0c88ccbe0ebae22d91d92c4cf260b355301df8452873bdadce2b145ed7`
- Baseline report SHA-256: `43a0df48c69e8824b09570f966f4496ba8bb2c78a13422217f4a9b760cd38506`

| Component | Reference median | Across-run CV |
| --- | ---: | ---: |
| cpuSingle | 419.119680133 | 0.012720519 |
| cpuMulti | 6906.347386988 | 0.015596991 |
| gpu | 2513.047867655 | 0.003435477 |
| memory | 28.187976554 | 0.017287034 |
| diskRead | 0.186122223 | 0.013084844 |
| diskWrite | 2.042645077 | 0.058161264 |

本报告只含聚合指标、非设备唯一硬件描述、非设备唯一 session 标签与源记录 SHA-256；不含序列号、硬件 UUID、用户名、路径或 IP。
