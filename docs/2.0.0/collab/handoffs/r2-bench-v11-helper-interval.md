# r2-bench-v11 / helper-interval 交接

日期：2026-10-10。worktree `/Users/developer/Developer/sc-worktrees/r2-bench-v11`，分支 `task/r2-bench-v11`，基线 `39f4d959671044124c843fab97ac2c8fc9c65cd1`（已含 B2a/B2b），开始时工作区干净。已读两份 common、协作规则、D5/D48/D55/D60/D71/D72 和 v11 §4。按本轮与 codex-build-common 的后续授权在沙箱编译和跑定向；未写真实 git index/提交。

**状态：生产接线和契约夹具验证已完成；本机原生格式及实际 `helperMeasured` 状态未验证。** 既有夹具只证明 `elapsed_ns` 时长，不能证明实际测量边界。新增高精度数值 `timestamp` / `is_delta` 的 XML 是合成契约夹具，不是本机或任何 M 芯片的录制。若实机固定命令只输出整秒 Date 或没有可信的高精度边界，这版仍返回 `requestBracketOnly`，能效 unavailable；不能将交付包描述为已解决实机能效可用性。合并前还须 D71③单独安全复核并核对原生时间字段的语义、单位、精度。

## 1. 改动及依据

| 文件 | 改动与理由 |
|---|---|
| `Sources/FanControlHelper/PowermetricsProcessRunner.swift` | 在原 `posix_spawn` 前、双管道 EOF 且自身 reap 后捕获同域单调时钟和墙钟锚点；通过本地闭包传入成功解析。保留原进程级随机 helperBootID，每份采样生成 UUID sampleID；已解析的 timing 不再被原 bracket-only 分支覆盖 |
| `Sources/FanControlShared/PowermetricsMeasurementContext.swift` | 新增纯值上下文和保守推导：要求 delta=true、整数 elapsed_ns、可信范围内的高精度 timestamp、两个锚点投影一致且区间完全在子进程内。start/end 两种边界方向必须仅有一种成立。缺失、低精度、方向歧义、时钟端点不一致和异常区间返回 requestBracketOnly，时间起止为 nil |
| `Sources/FanControlShared/PowermetricsSample.swift` | 可选子进程起止和固定来源标记，仅追加回复字段；parser 可接收助手本地 context。现有无 context 解析仍不赋予未知 timestamp 测量证据；缺 elapsed_ns/完整 plist 异常仍是 invalidOutput，不造功率样本 |
| `Sources/FanControlShared/PowermetricsSampling.swift` | 仅成功退出、双管道 EOF 且输出未超限时消费本地 context；超时/超限/非零退出不建立测量 envelope |
| `Sources/StorageCleanerMac/Services/HelperPowerMetricsMonitor.swift` | HEAD 已有 requestStart 对齐，保留其 ≥2 s 正常周期。补齐取消 worker 在 XPC 排空前重开的边界：旧 worker 保留到返回，随后按 due 启动新 generation。节流起点在 envelope requestStart 捕获后设置，避免派发前的准备耗时缩短下一次真实请求间隔 |
| `Sources/StorageCleanerMac/Services/Benchmark/MSeries/MSeriesV11Models.swift`、`MSeriesV11Windows.swift` | 新增可选 sampleCoverageFraction/timeCoverageFraction；分别记录独立样本数覆盖和实际时间覆盖。修正 4/5 有效样本已覆盖三个子窗时被单个诊断样本否决，以及前一阶段诊断污染后一阶段的门禁。全为 requestBracketOnly 时保留该质量，alignmentQuality=unavailable，吞吐仍保留 |
| 两个测试文件 | 新增 10 项区间/执行/协议/桥接/覆盖测试、1 项自动重开排空测试，既有断言均保留 |

`main.swift` 不需要修改：原 JSONEncoder 的 `powerSampleResult` 自动携带新增可选字段，协议仍为 v4；该文件与 HEAD 原字节相同。XPC 请求仍恰好 operation/protocolVersion 两键，拒绝 timestamp、clockDomain、helperBootID、measurementContext 等额外键。literal legacy DTO 测试覆盖新回复→旧客户端以及旧回复→新客户端；旧 timing 字段缺失时 App 标 requestBracketOnly（非法请求时钟则 legacyUntimed），不发明 helper 身份。

## 2. 时钟及原生格式边界

选择既有 `PowermetricsMonotonicClock.nanoseconds`：Darwin `mach_continuous_time` 经系统 `mach_timebase_info` 换算纳秒，domain=`mach-continuous-v1`；它没有进程局部原点，包含休眠，助手、App request bracket 和 `MSeriesV11Clock` 负载时间复用同一实现。未用 `seconds` 的进程局部原点或 UTC 为负载区间计时。同进程模拟测试核对三个入口及捕获顺序。

每个墙钟锚点夹在两次系统单调读取之间，读取间隙必须 ≤1 ms；从 launch、reap 两端将原生 timestamp 投影到同一单调域，两端差值必须 ≤1 ms。UTC 仅在助手内部解释原生 timestamp，最终 workload/功率交集全部用系统单调纳秒；这不是以 App sampledAt 或请求完成时刻减时长。端点校验能发现对应的墙钟偏移，不声称能证明所有可能的瞬时墙钟变化。

受支持契约形状：`is_delta` 必须为 plist boolean true；`elapsed_ns` 为 50 ms…5 s 的整数；`timestamp` 为 Date 或小数 Unix seconds，单位/epoch 必须在两个本地锚点投影范围内，拒绝 string、bool、任意数字 epoch、ns epoch、整秒时间。timestamp 必须是**原生测量边界**，不能是报告生成时刻；当前代码以唯一能落在进程边界内的方向记录 `nativeTimestampStart+elapsed_ns` / `nativeTimestampEnd+elapsed_ns`，不选取有歧义的方向。日期精度/字段语义核对属于实机门槛，数值能投影并不替代该核对。

本轮 Foundation 实验确认：XML `<date>` 默认序列化丢失亚秒，小数 Date XML 由 Foundation 拒绝；二进制 plist 含内嵌 NUL，现有单份 XML/NUL 分帧器拒绝它。本轮**未放宽分帧器或新增二进制/自定义 XML 解析器**。初版二进制测试夹具的 8 项失败已修为 XML 数值契约夹具，最终新增 10 项全绿；低精度 Date 专门保留为负例。**若实机仅提供这种低精度 Date，不存在本轮已经证明的可靠升级路径，必须继续降级。**

## 3. 安全自查（独立安全复核仍 NOT RUN）

- 唯一采样仍为 `/usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power -n 1 -i 1000 -f plist`，参数数组原字节未变；没有新增 sudo、shell、特权入口、第二条采样命令或调用方参数。
- 路径、`LANG=C`/`LC_ALL=C`/固定 PATH、工作目录 `/`、stdin `/dev/null`、POSIX 进程组、CLOEXEC、双管道非阻塞读取、SIGKILL→自身 waitpid 回收均保持；未改授权流程、audit-token 身份/签名/团队/路径验证或助手更新流程。
- daemon 全局开始间隔 ≥2 s、最多 32 等待者、连接尝试限频、5 s 超时、stdout+stderr 合计 512 KiB 上限均保持。Timing 的额外上限只收紧可信证据，不扩大资源预算。
- 攻击面变化仅为已有只读采样回复新增时间/随机身份/固定来源字段，以及对同一有界 stdout 内时间字段的校验；context 由助手本地生成，不接受网络或 XPC 注入，不返回原始 plist、stderr、路径或进程信息，不读取用户文件。
- `main.swift`、`ScanStore.swift` 和原硬件控制入口原字节不变；D5 系统充电暂停行为保持，未运行任何充电/电源/风扇写入。小窗与能耗页仍使用既有共享 demand stream，可见才采样；未改视图/安装/权限消费者。
- 固定命令/签名顺序源码守卫、请求安全测试、client gate、超时/双管道输出预算测试全绿，private API 检查通过（7 条原 allowlist）。这些检查不等同独立安全审核、正式签名放行或 root XPC 实测。

## 4. 实际验证

scratch：`/Users/developer/Developer/.sc-build/r2-bench-v11`。日志路径均相对此根。

| 项目 | 结果及证据 |
|---|---|
| 最终 Debug build + tests targets | PASS，exit 0，26.18 s；`logs/helper-interval-build-validated.log`，含助手/共享模块/App/测试目标。此前两次构建也通过；中途测试夹具问题没有通过改分帧或放宽断言规避 |
| 定向（24 类 + v6 冻结指纹单方法） | exit 1：234 项、5 次断言失败（1 unexpected），未跳过；`logs/helper-interval-targeted.log`。新增区间测试 10/0、新增自动重开测试 1/0；本批源码/解析/执行/协议/client gate/桥接/窗口相关 77 项中，仅既有家目录夹具方法被沙箱阻止 |
| v6 冻结指纹 / v11 compact、storage、history、runner、scoring | 定向已跑并通过；冻结指纹方法不改，原分数/门限不改 |
| private API、diff whitespace | PASS，exit 0；`python3 script/check_private_api.py`、`git diff --check` |
| 43 条反证目标及方法存在性 | PASS；前 33 条逐对象保持且保留原文件字节副本；新增 10 条。变异执行 NOT RUN（由主会话执行，不把静态存在性写为反证已变红） |
| 全量/独立严格并发/Release/完整 verify | NOT RUN，交主会话 |
| 实际 powermetrics/root XPC/实机字段/签名放行/安装/提交/发布 | NOT RUN |
| JEV | BLOCKED：`MCP tool call requires approval, but approval policy is never`；未获得模型判断，没有更换模型或尝试绕过批准策略 |

四个沙箱外复跑方法（共 5 次失败）：

1. `BenchmarkV7HistoryPresentationTests/testDeletingLastConfirmedRecordCannotRevealRevokedLateSuccess`：171 行 synchronize 失败，紧邻日志 CFPreferences 临时路径 `sandbox_extension_issue_file ... Operation not permitted`。
2. `HelperPowerMetricsMonitorTests/testScanStoreWiringDegradesWithoutRequestingOrAuthorizing`：TestFileSystem:60 创建家目录操作 home 被拒，NSPOSIX Code 1；没有放宽产品路径安全检查。
3. `TestPreferenceHygieneTests/testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory`：308/309 两次失败，临时绝对路径偏好域在此沙箱无法落盘。
4. `TestPreferenceHygieneTests/testTemporarySuiteCanBeReopenedOnAWorkerThread`：324 行 synchronize 失败，同类 CFPreferences 拒绝。

新增回归不依赖以上权限，已全部通过。整体定向不可描述为全绿。

实际构建/测试命令（当前最终文件）：

```zsh
cd /Users/developer/Developer/sc-worktrees/r2-bench-v11
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
scratch=/Users/developer/Developer/.sc-build/r2-bench-v11
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path "$scratch/debug" --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
swift test "${F[@]}" --skip-build --filter "$(cat "$scratch/evidence/helper-interval/targeted-filter.txt")"
python3 script/check_private_api.py
git diff --check
python3 "$scratch/prepared/helper-interval/commit-prepared.py" --check-only
```

完整门禁在主会话用私有 verify 根、`STORAGE_CLEANER_VERIFY_BUNDLE=0`、`STORAGE_CLEANER_UI_SMOKE=0` 和指定 DEVELOPER_DIR 运行 `script/verify.sh`；本轮没有运行它。反证由主会话使用 scratch `counterexamples.json` 的 mutation specs 独立执行，按原有运行器记录实际测试变红/编译失败/存活，恢复每个文件后校验 SHA，不能仅靠源码守卫计为行为反证。

## 5. 红 / 绿 / 反证

- **区间缺口**：红例去掉执行策略的 context 连接（`helper-interval-context-disconnected`），成功 parse 只得到 untimed；绿例高精度 XML timestamp→助手 context→JSON v4→App bridge→窗口，5/5 样本得到 5 s observed、10 J、500 matchedWork、50 fixtures/J，样本覆盖 100% 与时间覆盖 50% 分开。仅 elapsed、整秒 Date、非法单位/epoch、墙钟步进、歧义/越界、超时、超体积均不能进入 helperMeasured。
- **轮询排空**：红例重开前把 cancelled worker 立即置 nil（`helper-interval-reopen-before-drain`），新 worker 多等一个周期；绿例第一条从 100 s 挂到 104 s，重开后排空立即派第二条，无第二个 worker/重叠且旧 generation 不发布。HEAD 原 100/102/104 请求起点与每次一秒 sleep 测试保留通过。
- **覆盖门禁**：红例把实际时间覆盖写为样本覆盖（`helper-interval-coverage-conflation`），或让单个无时间样本否决已满足 4/5 的有效样本（`helper-interval-partial-coverage-poisoned`）；绿例分别 0.8/0.4 且每个子窗有交集时可计算。全 requestBracketOnly 时功率交集/有效数为零、efficiency=nil、alignment unavailable，吞吐仍保留。既有 <80%、缺窗、重复/重叠/错域/零功率门禁断言全部保留。
- **XPC/安全**：红例允许 request 额外时间字段（`helper-interval-caller-context-allowed`）；绿例严格两键；旧客户端忽略 timing，新客户端接受无 timing 的旧回复并降级。限频、超时、stdout+stderr 上限的既有行为测试全部保留。

没有改写/删除既有测试断言。窗口门禁的行为变化依据 v11 §4 的“至少 4/5 或 12/15 个有效独立样本”，不以无效样本补数，不放宽 80% 门限。

## 6. prepared 与剩余工作

`prepared/helper-interval/` 包含三组补丁：01 implementation（7 个源码文件）、02 tests（2 个测试文件）、03 handoff；all.patch、逐组提交说明、manifest（基线/分支/before/final SHA-256/组顺序）、static-checks、24 类清单和冻结指纹 filter、43 条 counterexamples 副本、原 33 条字节备份、commit-prepared.py。只读 `--check-only` 验证补丁可应用及 SHA；`--validated` 仅由主会话完成验证/审核后使用，本轮未执行。

剩余：沙箱外复跑四方法及完整门禁；实际运行 10 条新增反证并恢复核对；独立 D71③安全复核；按既有授权流程由主会话核对固定命令的脱敏原生字段（尤其 timestamp 是否为测量边界、数值/Date、单位、精度、is_delta/elapsed_ns），验证 root XPC 同域往返、五个独立样本与可见性行为。不得为了提升质量把低精度日期/报告生成时间/进程 reap 时间充当原生测量边界，也不得通过改变常量命令参数或自动安装助手解决此限制。

## 7. fix1 — 独立安全复核两项 P2（2026-10-10）

复核依据：已全文阅读 `logs/codex-review-helper-security.log` 末尾的六项正式意见；结论为“未发现 P0/P1，两项 P2，修完再合并”。第 3–6 节为上一轮记录，不代表 fix1 后已经重新获得独立放行。本轮复合基线为 HEAD `39f4d959671044124c843fab97ac2c8fc9c65cd1` + 原 `prepared/helper-interval/` 三组；原包与 43 条反证基线已核对并备份，未覆盖原包。新增修改为 9 个源码文件、1 个测试文件、规范与本交接共 2 个文档。

### 7.1 回复体积与来源边界

`FanControlHelperReply.decodeFromTransport` 在 JSONDecoder 前检查 Data 总字节 ≤64 KiB；生产 `FanControlCoordinator` 的 XPC completion 使用该入口，超限抛出 `replyTooLarge`，采样调用沿原错误路径返回 unavailable，不授权、不重试安装、不发布假样本。64 KiB 小于既有 512 KiB 子进程输出上限：合法回复只包含结构化数值、最多 16 簇/风扇、固定枚举、短助手消息，无原始 plist/stderr；最大数量、范围的功率回复和包含三份 16 风扇字典的完整曲线回复测试均低于 8 KiB，留至少 8 倍余量。新限制约束收到 Data 后的 JSON 解析；不声称它能阻止 XPC 框架此前接收 Data 的内存分配。

`Timing.timestampSource` 使用严格白名单 `nativeTimestampStart+elapsed_ns` / `nativeTimestampEnd+elapsed_ns`，并限 UTF-8 ≤64 B。未知、超长、多字节超长、错误类型均不保留来源字符串或 measurementStart/End，而降为 `requestBracketOnly`；功率仍可作诊断。缺失/为 null 的旧可选来源保持原协议兼容；两种正常来源不变。进程内构造同样受 `isWellFormed` 白名单校验。

### 7.2 规范 §4 的历史隐私与 rawPayloadSHA 调整

`helperBootID` 在桥接运行内存仍用于对齐和 `bootID:sampleID` 去重。封存前按本次结果首次出现的助手进程分组为 `helperProcessOrdinal`（1、2…），清空可选 helperBootID；编号不是 UUID 的编码、散列或稳定替代标识，每个结果从 1 重新编号，不能据此判断另一次结果是否来自同一助手。窗口接受运行内身份或本次结果内有效编号，仍要求原来的同域、区间、独立样本、功率与覆盖门禁，封存/历史读回后能效证明可重算。

新 rawPayloadSHA256 对剥离后、展开的规范 JSON 计算，沿用原来排除摘要自身、参考集派生缓存与元数据记账的规则，仍不是压缩存储字节 SHA。保持组关系/其他证据不变而替换所有原助手 UUID，摘要必须相同；原 UUID、UUID 编码/散列均不进入新 payload。压缩 archive 的 payloadSHA256 也覆盖剥离后的证据。

旧历史可选字段兼容解码，仍用其原始展开 JSON 验证原摘要；单纯 load 不改文件。仓库每次 save / replace / delete 写入前清理整个重写集合，包括未被本次操作选中的旧记录，再重新封存摘要；损坏旧文件仍按原流程拒绝写入。v11 原 recordID 和写入预算守卫保留，新增“旧记录无 recordID 不能让新 v11 记录绕过身份/记账”的回归。没有批量扫描或主动改写用户已有历史。该隐私边界已同步补入 `BENCHMARK-V11-SPEC.md` 第 4 节。

### 7.3 fix1 实际验证与反证

| 检查 | 结果及证据（路径相对本批 scratch） |
|---|---|
| 最终 Debug + tests targets 构建 | PASS，exit 0，25.18 s；`logs/helper-interval-fix1-build-validated-2.log`。首轮有 Swift throwing-expression 编译错误，已修；不把失败轮次省略为一次通过 |
| 最终定向（29 类 + v6 冻结指纹单方法） | exit 1，275 项、5 次断言失败（1 unexpected）、0 skipped；`logs/helper-interval-fix1-targeted-final.log`。与上轮相同的 4 个沙箱受限方法，未删/改/跳过断言 |
| 新边界 / 新隐私回归 | PASS，`HelperReplyBoundaryTests` 5/0，`MSeriesV11TelemetryPrivacyTests` 4/0；含超限有效 JSON 与非 JSON、64 KiB 精确边界、正常最大数量回复、Coordinator unavailable、来源降级、明文/压缩历史无标识/派生值、旧 SHA 兼容、三种历史改写及 nil recordID 拒绝 |
| 相关兼容 | PASS；原 helper-interval 新增 10 项、桥接/窗口/runner/compact/storage/scoring、新旧 XPC、旧 v7 历史、风扇协议/启动协调器、v6 冻结指纹均在定向中通过 |
| private API / diff whitespace | PASS；7 条既有 allowlist；`logs/helper-interval-fix1-static.log` |
| 反证静态检查 | PASS；现有 43 条对象保持不变、before 精确命中各 1 次；新增 4 条，总 47；所有测试 filter 方法存在。变异执行 NOT RUN，交主会话 |
| 特权/实机/全量/安装/提交 | NOT RUN；没有真实 powermetrics、sudo、安装/更新助手、启动应用、硬件写入或真实用户数据读取；不把编译或单测写成 root XPC / 原生时间字段已验证 |
| fix1 后独立安全复核 / JEV | 独立安全复核 NOT RUN，主会话需复核修复；JEV BLOCKED，`logs/helper-interval-fix1-jev.json`：`MCP tool call requires approval, but approval policy is never`，未取得模型判断 |

沙箱外复跑方法同第 4 节：`BenchmarkV7HistoryPresentationTests/testDeletingLastConfirmedRecordCannotRevealRevokedLateSuccess`、`HelperPowerMetricsMonitorTests/testScanStoreWiringDegradesWithoutRequestingOrAuthorizing`、`TestPreferenceHygieneTests/testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory`、`TestPreferenceHygieneTests/testTemporarySuiteCanBeReopenedOnAWorkerThread`。前者及后两者为 CFPreferences 的 `sandbox_extension_issue_file ... Operation not permitted`，Monitor 为家目录操作夹具创建被拒；未放宽路径或偏好卫生要求。

新增反证对应两项 P2：

- `helper-fix1-reply-cap-bypass`：移除解码前字节门禁，超限有效 JSON 应触发测试变红。
- `helper-fix1-source-whitelist-bypass`：绕过来源降级，未知/超长来源应触发质量/区间断言变红。
- `helper-fix1-boot-id-retained`：保留原 UUID，明文及展开压缩历史中的标识应触发测试变红。
- `helper-fix1-legacy-rewrite-not-redacted`：旧记录写入前不重新封存，save/replace/delete 剥离测试应变红。

这些是具体变异方案与绿测依据，没有在沙箱执行变异；主会话须实际运行、恢复源码并验证 SHA，再记录反证结果。没有改写任何既有断言，9 个新增方法均保留真实阈值。

复跑命令：

```zsh
cd /Users/developer/Developer/sc-worktrees/r2-bench-v11
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
scratch=/Users/developer/Developer/.sc-build/r2-bench-v11
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path "$scratch/debug" --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
swift test "${F[@]}" --skip-build --filter "$(cat "$scratch/prepared/helper-interval-fix1/targeted-filter.txt")"
python3 script/check_private_api.py
git diff --check
python3 "$scratch/prepared/helper-interval-fix1/commit-prepared.py" --check-only
```

### 7.4 fix1 prepared 与安全边界

`prepared/helper-interval-fix1/` 为增量四组：01 reply-boundaries（3 源码）、02 telemetry-privacy（6 源码）、03 regression-tests（1 测试文件）、04 docs（2 文档）。包含逐组 patch/提交说明、all.patch、manifest 的复合基线/前后与产物 SHA、before 快照、原三组前置 patch/说明、47 条反证及原 43 条副本、定向清单、static-checks、提交脚本。`--check-only` 在临时文件副本验证原三组 + fix1 四组可应用性与最终 SHA，不写真实 index；`--validated` 仅主会话验证/复核后执行，若原三组尚未提交会先提交原三组，再提交 fix1，若已提交则核对内容后只提交 fix1。不应在含 fix1 的工作区直接使用原包的最终 SHA 校验脚本。本轮没有执行 validated 或创建提交。

prepared 只读校验实际 PASS，exit 0：原三组与 fix1 四组在隔离副本顺序应用，复合基线/最终文件/产物 SHA 与改动范围匹配；原 prepared 产物哈希全部保持，真实 index 与 HEAD 未改。记录见包内 `prepared-verification.json`。

攻击面变化仅为已有只读回复的字节/来源校验及封存字段剥离。固定命令与参数、子进程环境/路径、5 s、512 KiB、≥2 s、单条在途、等待者上限、授权/签名校验、D5 系统充电暂停和可见消费者行为均未扩大或改变。本轮剩余：沙箱外复跑受限四方法、47 条变异、完整门禁及 fix1 独立安全复核；原有实机 timestamp 格式/精度/边界语义、root XPC/正式签名放行的待验证事项仍保留，绝不以测试夹具宣称生产实测完成。
