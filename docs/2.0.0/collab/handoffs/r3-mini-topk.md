# r3-mini-topk：第三轮菜单栏数据与展示

## 交付边界

- worktree：`/Users/developer/Developer/sc-worktrees/r3-mini-topk`；分支：`task/r3-mini-topk`；基线：`52f722aca8b735904c21c542b13bb501d4e5de99`。
- 已读取本批 `common.md`、`codex-build-common.md`、协作规则、D5/D48/D55/D60/D74–D76、BOARD，以及用户指定静态逆向报告第④⑤节和第三轮计划 R3-1/R3-2/R3-3。只采用数据组织与显示思路，未复制竞品代码或素材。
- D79/D80/D81 三行加入 DECISIONS 最上方的新表格。D74–D76 的预存即显、采样档位、顶部时间、电池级联、公网 IP 规则没有改动；没有增加采样、子进程或硬件写入。
- `.git` 只读，交付 scratch `prepared/`；没有提交、安装、启动产品 App、推送或发布。未改 ScanStore、AppUpdates 或清理规则。
- 两处历史字段和三处传感器依赖必须同步：`NativeDiskIOMonitorService.NativeDiskIOPoint`、`MenuBarAuxiliaryMonitorState.MenuBarPowerHistoryPoint` 仅加可选统计字段；`SystemMonitorModels` 加可选来源元数据并保留 0°C；`HIDTemperatureMetadataCache` 保留物理身份；`SMCFanSpeedService` 仅提供已用键的来源说明与 0°C 校验。没有改这些服务的采样频率。

## 五组补丁

| 顺序 | 文件 | 内容 |
|---|---|---|
| 01 | `01-r3-1-process-topk.patch` | 独立 CPU／磁盘／能耗榜单；演示数据复用生产选择器 |
| 02 | `02-r3-2-history-statistics.patch` | 可选桶统计、多分辨率压缩、图表均值／峰值和缺口投影 |
| 03 | `03-r3-3-sensor-identity.patch` | SMC/HID 身份、保守命名、来源帮助与 23 项上限 |
| 04 | `04-r3-tests.patch` | 三个新测试类和 D81 对应旧断言更新 |
| 05 | `05-r3-docs.patch` | D79/D80/D81 与本交接 |

部分文件由不同功能拥有不重叠的改动，补丁必须依次使用；`all.patch` 是相对基线的完整补丁。manifest 记录组顺序、最终文件 SHA-256 和产物 SHA-256。主会话完成门禁及复核后，才运行 `python3 prepared/commit-prepared.py --validated`。本轮没有运行提交脚本。

## R3-1：候选集合独立

`MenuBarPreparedProcesses` 从同一 `snapshot.apps` 的应用集合分别选择，默认 K=5，可传入独立 limit：

- 能耗：原显著能耗条件（功率 ≥0.5 W 或 CPU ≥5%），按当前功率降序。
- CPU：有限且正的 CPU%，按 CPU% 降序。
- 磁盘：正的读＋写速率，按速率降序；不受功率或 CPU 门槛限制。转 Double 后相加，避免 Int64 计数和溢出。
- 并列：名称的 literal 排序、最小 PID、应用 ID；使用当前快照的对象和名字，没有新增 PID 名称缓存。已有底层进程身份／启动时间防复用逻辑保留。

七应用反例包含五个高能耗应用、能耗前五之外的 CPU 第一名，以及低 CPU／低功率的磁盘第一名；另测三份榜单并列、库存次序变化、相同 PID 的新应用和零活动。演示入口走相同准备逻辑。

## R3-2：桶统计与图表口径

保留原 JSON checkpoint/journal 格式、文件路径、版本号、28 天保留期及 16 MiB 上限；每个点增加可缺省的 `bucketStatistics`。每个数值通道保存时间加权 mean、真实 peak/minimum、最后有效 last、峰值／末值源时间、样本数和分段 coverage。CPU 总峰值还保留同一真实样本的 user/system，避免拼出并不存在的峰值分量。

| 指标 | 历史曲线／柱 | 峰值／统计／末值口径 |
|---|---|---|
| CPU total/user/system、GPU 使用率 | 有效时间加权均值 | 真实样本最大值；CPU 峰值分量取总 CPU 峰值所在样本；当前数值仍取真实末次读数 |
| 网络下载／上传 | 有效时间加权均值 | 单通道真实峰值；峰值卡及 hover 摘要使用保存的峰值；末值独立 |
| 磁盘读／写、读／写操作率 | 实测计数区间加权均值 | 各通道真实峰值、末值；不同区间长度不按样本数平均 |
| 电池功率 | 有效时间加权的有符号 W | 保存真实最大、最小和末值；负的放电尖峰由 minimum 保留，不把最大有符号值称为最大耗电 |
| 电量百分比 | 末值，保留原电量展示语义 | 均值、极值也持久化供统计使用；充电状态／电源来源转换不并入同一个桶 |
| 内存已用／压力%、交换字节、内存组成字节与百分比 | 支持均值的历史图走均值 | 数值通道保留均值、真实极值和末值；压力等级继续保留原最严重等级，类别不作算术平均 |
| CPU/GPU/SoC/各区域温度、平均风扇 RPM／目标 RPM | 支持历史的图走均值 | 保留真实极值与末值；单独物理温度探头和单个风扇列表仍是当前快照，没有新增探头历史 |
| 助手 CPU/GPU/ANE 功率／频率 | 现有当前读数 | 本来没有进入该历史点，本轮不虚构这类历史，也不把 CPU 功率当整机功率 |

有效覆盖采用保守规则：磁盘有实测 intervalStart 时使用该区间并裁掉已覆盖前缀；其余通道只在相邻有效源时间间隔 ≤180 秒且不跨已知睡眠／暂停缺口时，建立以后一读数结束的区间。GPU／传感器使用原硬件源时间，重复发表缓存值不多计样本或权重。无前驱的孤立旧点保留峰值／末值，覆盖为零长度；缺失值打断覆盖，长间隔不补 0。统计 last 表示最后有效读数，点上原可选标量仍能表达最后一轮缺失。

近期原始点仍保留；进入分钟桶、5 分钟桶、容量降档的 30 分钟桶时，合并已有充分统计量，均值按覆盖时长合并。同一时间的重放不增权。碎片很多时按合并双方 coverage 数量提前拆桶，保证每项 ≤256 个片段；不截断片段，不因二次压缩生成不可解码的 checkpoint。16 MiB 下仍沿用原降档／拒写行为，拒写不删内存中的有效历史。

图表的汇总、网络峰值卡、CPU 平均／峰值柱、磁盘与功率准备均读取统计字段。已有桶覆盖投影到图上，空缺口保持空白，不用 nearest fill 拉过睡眠。CPU 的短范围与长范围都能显示保存的均值／峰值。帮助说明“该时段平均按有效记录时间加权；峰值来自真实样本”，并说明未记录、睡眠和暂停不按 0 计。

原始 CPU 长历史保留直接字段准备路径，仅压缩点查询桶统计；压缩存在性只扫描一次并复用。Release 44,000 点准备测试首次 P95 164.8 ms，独立复跑 176.7 ms，超过原 100 ms 预算，因此修复这条数据路径后重新构建及验证，预算和原断言保持不变。最终数值以实际运行证据表为准。

编码复用桶内相同的末次源时间、样本数和 coverage 上下文；每项数值用紧凑 JSON 数组保存均值、极值、末值、峰值时间和上下文索引，CPU 峰值分量仍完整保留。这样避免 32 个通道重复日期／覆盖使 28 天统计字段本身超出 16 MiB。解码同时接受原完整 metrics 对象；共享上下文、索引和所有数值同样执行结构校验，损坏数据仍交原恢复路径。新增实际容量夹具覆盖 28 天全部 32 个通道、最近一小时每秒数据、编码字节数与最早桶、均值和峰值恢复；没有为容量丢通道或放宽上限。

旧字段可缺省，旧有效文件继续解码；迁移后保留原 legacy 文件。原损坏隔离、journal 恢复和容量限制路径没有改写。旧版本已经压缩丢失的尖峰无法从末点恢复，迁移不会宣称恢复这些数据。

## R3-3：物理身份和保守显示

`MenuBarTemperatureChannel` 分开保存来源、原始键／服务、序号、原始标签、位置、单位和命名可信度；稳定 ID 是来源＋原始身份＋序号的 SHA-256 标识，显示标签不参与去重。

- HID 同名服务、双 die、PMU 双 die 独立保留。缓存只保存身份和名字，每轮仍发现当前服务图并读取当前事件，缺失事件不回放旧值。保留服务的序号不随图枚举次序改变；服务移除后新服务取新序号，避免对象地址复用串名。
- 原始 HID RegistryID 可读时写入帮助；不可读时用连接 UUID＋保留服务序号区分。此 fallback 只保证该连接存活期身份，不能声称跨重启恒定；本轮没有按探头 ID 建跨重启历史。
- 标签识别只接受完整匹配的有限已知标签。只过滤明确的 PMU tcal 校准标签；名称中碰巧含 tcal 的未知有效探头仍保留。未知通道显示“未识别温度通道 N”，原始键／服务和原始名称留在帮助；总览 CPU/SoC 也使用同一明确标签分类，不凭名称碎片猜区域。PMU 保留各 die，仍不当 CPU。
- 有限 0…130°C 合法，0°C 保留；空事件、非有限值、源时间超过 180 秒或未来超过 5 秒的样本不列入当前结果。既有服务重连和采样档位保持。
- 默认上限是合并后 ≤23 行：已验证 SMC 拓扑 → 明确认出的 HID 标签 → 未知通道，各档按 literal 显示名、身份稳定排序；不按更热的读数抢占或合并。同名行加序号，SMC 已命名位置保留。
- 现有两个 SMC GPU 区域均值是明确命名的组合指标，保留原拓扑和平均算法，帮助披露全部原始键；未将组合均值包装成独立物理探头。SMC PMU fallback 帮助披露 TPDX/TRDX/TUDX，HID PMU 细项存在时不用该 fallback 挤占行数。
- “硬件探头”说明 SMC/HID 温度来源；“系统助手”说明特权助手的 CPU/GPU/ANE 功率或频率，并明确 CPU 功率不是整机功率。未改变助手授权流程。

## 测试与旧断言调整

新测试共 25 项：`MenuBarIndependentTopKTests` 4 项、`MenuBarBucketStatisticsTests` 13 项、`MenuBarSensorIdentityTests` 8 项。共用 fake/辅助类型均在 Debug／Release 可见，没有放进 `#if DEBUG`。

旧断言按 D81 调整，未删测试、跳过测试或放宽阈值：

1. `HIDTemperatureMetadataCacheTests` 的图次序变化和对象复用两项：原完整 Reading 与无身份夹具的 equality 改为原名字、原值加固定服务序号断言；所有发现／事件／名称调用次数断言保留。
2. `SensorDetailIntegrationTests.testHIDDetailsKeepFiniteChannelsWithConservativeUnknownNames`：原“同名较热一个、只取已识别”两项，改为同名 53/54 两个、两个未知通道、总五个独立 ID；GPU 值、无效值检查保留。
3. `MiniSensorsNoValueRuleTests` 的 PMU 断言：原单一 88.7°C 汇总行改为 82.4/88.7°C 两个物理 die，明确中文命名且无 CPU 区域；“PMU 不当 CPU”断言保留。
4. `SystemMonitorServiceTests` 的温度归一化：原固定点 256 被拒改为合法 1°C，并加合法 0°C；其余温度归一化断言保留。

完整定向清单在 scratch `targeted-classes.txt`，30 类，含新旧相关类及 UIConsistencyRegressionTests、TestPreferenceHygieneTests、MenuBarPerformanceRegressionTests。没有过滤掉下面失败的测试。

### 实际运行证据

| 检查 | 结果 | 实际证据 |
|---|---|---|
| 最终 Debug `--build-tests` | PASS，exit 0 | `debug-perf-build.log`，性能修复后的冻结源码，79.40 s |
| 最终 Debug 新功能及相关 CPU／均值／缺口回归 | PASS，exit 0；58 项、0 skip、0 failure | `debug-final-feature-tests.log`，22.331 s；含全部 25 项新测试，实际容量 11,684,497 / 16,777,216 字节 |
| Debug 30 类回归 | FAIL，exit 1；592 项、8 skip、6 次失败 | `targeted-tests.log`，187.759 s；环境／未确认原因见下表 |
| 最终 Release 编译 | PASS，exit 0 | `release-native-build.log`，902.16 s，冻结源码；native/-O/分文件，参数与限制见下文 |
| 最终 Release 30 类定向 | 本轮未跑（Codex）；见文末“修复轮 1”的实际结果 | 修复轮 1 已补跑 |
| 私有 API 守卫 | PASS，exit 0 | `python3 script/check_private_api.py`；7 allowlisted uses |
| diff 空白检查 | PASS，exit 0 | `git diff --check` |
| 反证配置及定向清单 | PASS 静态校验；实际反证 NOT RUN | 16 条 before 均恰好出现一次，目标测试方法存在；30 类定义存在且无重复 |

所有日志均在 `/Users/developer/Developer/.sc-build/r3-mini-topk/`；上表明确区分最终功能复跑与此前 30 类 Debug 回归。最终 Release 30 类回归用于覆盖随后边界与性能修正后的完整定向集合。Debug 最终功能复跑的 filter 为 `MenuBarIndependentTopKTests|MenuBarBucketStatisticsTests|MenuBarSensorIdentityTests|GeekHistoryAveragingTests|MenuBarHistoryGapTests|MiniWindowCPUChart1011Tests`。

Debug 30 类回归已有一次：592 项，8 跳过，6 次失败（2 unexpected），exit 1，日志 `targeted-tests.log`。新功能 23 项通过；恒定网络均值的浮点尾差在根因计算修复，原断言保留并通过。该次运行之后，又补了 CPU 短范围压缩、保守总览标签及二次压缩片段边界，最终复跑见上方证据表。

现有沙箱／未确认原因的失败（原断言全部保留）：

| 测试方法 | 观察与处理 |
|---|---|
| `EnergyProcessNamingTests.testAPathPrintedWithoutAUTF8LocaleIsReadFromTheKernel` | 现有夹具用复制的 `/bin/sleep` 构造合成路径，出现 NSPOSIXErrorDomain 1 Operation not permitted；不是启动产品 App。主会话沙箱外复跑进程路径读取 |
| `SystemMonitorServiceTests.testMenuBarMonitorStatePublishesWithoutInvalidatingScanStore` | 原家目录操作夹具创建返回 NSCocoaErrorDomain 513 / Operation not permitted。未改路径或 ScanStore，主会话沙箱外复跑 |
| `TestPreferenceHygieneTests.testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory` | 临时绝对路径偏好域出现 sandbox_extension_issue_file Operation not permitted，synchronize／文件存在两个断言失败。未改偏好工厂或使用真实偏好域 |
| `TestPreferenceHygieneTests.testTemporarySuiteCanBeReopenedOnAWorkerThread` | 同上，synchronize 断言失败。主会话沙箱外复跑 |
| `SystemMonitorServiceTests.testLightweightMemoryStatusSnapshotSkipsProcessEnumeration` | pressureFreePercentage 为 nil，原 XCTAssertNotNil 失败；独立进程复跑仍失败（`isolated-memory-status.log`，1 项，exit 1）。调用的 MemoryOptimizerService/MenuBarMemoryStatusSampler 未改，具体原因为未确认，不能一律归因于沙箱，也未证明基线同样失败。交主会话定位 |

Debug 跳过 8 项均为既有条件：优化代码性能 1 项、live energy opt-in 1 项、本机不可读 SMC/HID 6 项。Release 必须实跑优化代码性能测试；本机硬件缺失不能计为真实设备验收。

## 主会话复跑与反证

命令（路径均为本批专用；不启动 App）：

```bash
cd /Users/developer/Developer/sc-worktrees/r3-mini-topk
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
export LC_ALL=en_US.UTF-8
R3_FILTER=$(paste -sd '|' /Users/developer/Developer/.sc-build/r3-mini-topk/targeted-classes.txt)
F=(--disable-sandbox -Xswiftc -disable-sandbox --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --scratch-path /Users/developer/Developer/.sc-build/r3-mini-topk/debug --build-tests
swift test "${F[@]}" --scratch-path /Users/developer/Developer/.sc-build/r3-mini-topk/debug --skip-build --filter "$R3_FILTER"
swift build "${F[@]}" --build-system native --scratch-path /Users/developer/Developer/.sc-build/r3-mini-topk/release/native -c release --build-tests -Xswiftc -enable-testing -debug-info-format none -Xswiftc -no-whole-module-optimization
swift test "${F[@]}" --build-system native --scratch-path /Users/developer/Developer/.sc-build/r3-mini-topk/release/native -c release -Xswiftc -enable-testing -debug-info-format none -Xswiftc -no-whole-module-optimization --skip-build --filter "$R3_FILTER"
```

Release 默认 swiftbuild 引擎首次在生成 MemoryFixtureApp.dSYM 时出现 `Operation not permitted`（`release-build-first-dsym-failure.log`，exit 1）；已核对本地 `swift build --help` 支持 `-debug-info-format none`。关闭符号后的 swiftbuild 构建已通过（`release-swiftbuild-earlier-source.log`，exit 0，3149.50 s），但在源码最终校准标签修正前启动，不用它充当最终文件一致性的证明。native 首次也在编译期间遇到该最后修改，Swift 正确报 input file was modified during the build（`release-native-first-source-change.log`，exit 1）；这是本轮修改时机导致，已冻结源码重编译。

最终构建用本地 SwiftPM 支持的 native 后端，scratch 仍位于本批 release/native。保留 Release `-O`、`--build-tests`、`-enable-testing`，仅关闭符号并用 `-no-whole-module-optimization` 分文件优化编译；没有改项目配置、扩大沙箱权限、定义 DEBUG、删断言或放宽任何性能阈值。description.json 的实参已核对含 `-O`、`-enable-testing`，最后的 `-no-whole-module-optimization` 覆盖默认 WMO，实际日志逐文件编译。最终定向与优化性能证据来自这个构建；标准 shipping WMO 的最终源码门禁仍由主会话补齐，不能把这个构建宣称为最终发布包。

离线依赖按 RULES 从保留的 r2-u1-preselect/debug 复制。主会话在沙箱外复跑失败方法，定位内存压力未确认问题，再做独立复核／全量门禁。门禁使用用户指定 Xcode、`STORAGE_CLEANER_VERIFY_BUNDLE=0`、`STORAGE_CLEANER_UI_SMOKE=0` 和私有 `STORAGE_CLEANER_VERIFY_ROOT`；本批不以定向回归替代完整门禁。

`counterexamples.json` 有 16 条，每条包含 id、相对文件路径、恰好出现一次的完整替换前／后文本和预期失败方法。**NOT RUN**：按共同提示由主会话逐条在隔离副本中执行，不能把未跑反证写成 PASS。

- 红：从基线复核原能耗候选限制、末值覆盖、名称去重／标签猜测逻辑，或逐条应用 counterexamples 的 after（受变更模型新增 API 影响，新测试不能直接拷贝到基线就视为失败证据）。
- 绿：最终新类和相关旧类定向通过；环境阻塞方法在沙箱外补齐；保留实际 skip 与 exit code。
- 反证：分别把 CPU／磁盘候选退回 energy、反转 PID 并列、丢峰值、改样本数均值、跨睡眠补覆盖、UI 用末值、改容量、漏二次压缩片段上限、按名称合并、模糊标签猜区域／芯片、丢 0°C 或扩大 23 项，以及退回逐通道重复时间上下文的完整统计编码。对应测试必须失败，再严格恢复原文本、重新构建及复跑受影响类。

## JEV、未执行与清理

已发现 JEV 决策工具并尝试一次有界方案判断；工具接口未提供 model 参数，未擅自填写或替换模型。调用返回 `MCP tool call requires approval, but approval policy is never`，因此 **BLOCKED**，没有模型推理结果或 JEV 判断。未绕过审批或声称获得复核。

完整测试、实际反证、另一方复核、提交／合并、App 实机打开与真实探头验收：**NOT RUN**。这些留给主会话。所有静态判定／构建／测试都不等于安装或真实设备验收。

Release 临时构建按 RULES 在验证后清理，只留本批日志和 prepared 证据；Debug 本批构建由主会话合并后清理。没有清扫别人的目录或夹具。

## 修复轮 1（Claude 子代理，2026-10-13）

独立复核结论：D79 正确，保持不变；D80、D81 按下列各项返工。仍未提交，由主会话统一提交。没有启动 App、没有读取用户的真实历史文件，D74–D76 采样频率没有改。上文的“旧断言调整”第 4 条（定点 256 当作 1°C）已经撤回，旧断言恢复为 nil。

### 改动

- P0-1：温度区域正则改为接受真实 HID 名 `pACC/eACC/GPU/SOC MTR Temp Sensor<N>`（`( sensor)?`），`PMU2 tdie/tdev` 识别为电源管理芯片，`PMU2 tcal` 识别为校准值。ANE/ISP 不猜区域，按“未识别温度通道”处理。合成名 `… MTR Temp <N>` 的测试保留。
- P0-2：`SystemMonitorService.detailedTemperatures` 在有 SMC 拓扑时恢复为“拓扑原有各行 + 一个 D57 电源管理芯片汇总行”（优先取 HID 的 PMU 最大值，没有时用 SMC 的 PMU 键），独立 HID 通道不再进入默认细项，帮助区也没有加。无 SMC 拓扑时仍按 D81 显示 HID 通道，最多 23 行。
- P1-1：`AppleSiliconTemperatureService`、`SMCFanSpeedService` 的采样下限恢复为 5…130；`SystemMonitorServiceTests` 中被放宽的断言已恢复原文（`git checkout`）。0°C 只在模型层（`SystemMonitorSnapshot`）和历史层（`MetricHistoryStore.isValid`）不当作缺失。
- P1-2：同一时间戳的重放（遥测 `standingForBucket`、磁盘、电量 `bucketRepresentative`）保留已累积的桶统计。
- P1-3：合并后的均值限制在［最小值，峰值］内；`isValid` 改用相对容差 `max(|peak|,|min|,1)·1e-9`。
- P1-4：旧点补统计改在 `MetricHistoryStore.sanitized`（由 `load` 在 actor 内调用）中完成，用新增的 `withBucketStatistics`，截止点与恢复、压缩时一致（最新点往前 1 小时）。ScanStore 没有改。
- P0-3 性能：统计计算按一轮只取一次缺口快照（`statistic/statistics/standingForBucket/bucketRepresentative/preparedForBucket` 都加了 `gaps:` 参数，压缩、归一化、多分辨率、图表准备各取一次）。`telemetryStatistics` 改为单遍流式累加，不再为每个点分配记录。网络帧对每个点只构造一个通道的记录，不再构造两份 32 通道字典。投影中零覆盖点改用二分查找。悬停统计放进 `MenuBarChartPreparation` 预备帧，不在 view body 里算。`GeekHistoryStatisticsRow`（未使用）和 `GeekPrecisionLineChart.statistics(for:)`（未使用）恢复为基线写法。
- P2：电量投影改用 `Dictionary(_:uniquingKeysWith:)`，日期重复时不再崩溃。零覆盖点的投影权重统一用秒（0.001 s 的瞬时权重）。HID 显示序号按原始标签、原始键的数值顺序在同名标题内编号，不再用缓存发现序号；行排序加 `.numeric`。英文名称显示行是 `lineLimit(1)` 加 `.middle` 截断，帮助里有完整来源，这一项只做了静态核对。能耗榜单的并列次序加测试锁定：按 D79，功率相同时按名称、PID、ID 排，不看 CPU%；基线原来用 CPU% 作第二键。
- 测试：`MenuBarSensorIdentityTests` 新增 3 项（真实 MTR/PMU2 标签、按 probe `hid_idle1.tsv` 形态构造的 SMC 行数与 PMU 行、显示序号），改写本批 3 项（新下限、SMC 下不并入 HID）。`MenuBarBucketStatisticsTests` 新增 5 项（同时间戳、大量级、2 万点迁移、真实形态 4 数组 28 天体积、电量重复日期）。`MenuBarIndependentTopKTests` 新增 1 项（能耗并列）。

### 实际结果

| 检查 | 结果 | 证据（/Users/developer/Developer/.sc-build/r3-mini-topk/） |
|---|---|---|
| Debug `--build-tests` | PASS，exit 0 | `fix1-final-debug-build.log` |
| Debug 30 类定向 | PASS，exit 0；603 项、3 skip、0 failure | `fix1-final-targeted-debug.log` |
| Release `--build-tests -Xswiftc -enable-testing`（默认构建系统，WMO） | PASS，exit 0 | `fix1-final-release-build.log` |
| Release 30 类定向 | FAIL，exit 1；595 项、2 skip、1 failure：只有 `testOptimizedLongHistoryPreparationAndCachedDeliveryBudgets` 的绝对预算，P95 122.4 ms 超过 100 ms。同负载下基线也超，见 A/B | `fix1-final-targeted-release.log` |
| 性能 A/B（同机交替，基线 52f722ac 的临时 worktree，各 3 次） | 基线 117.3 / 115.8 / 118.8 ms，本批 112.7 / 133.6 / 122.3 ms；均值 117.3 对 122.9（+4.8%），中位数 117.3 对 122.3（+4.2%），在 10% 以内。机器负载 13–15，两边都超过 100 ms 的绝对预算，属环境问题，需在空闲机器上复跑；阈值未改 | `fix1-ab-perf.log`、`ab-perf.sh` |
| 体积（真实形态 4 数组 28 天＋最近 1 小时逐秒） | 5 分钟档 38,296,734 B，超限；30 分钟档 14,855,719 B（遥测 6.87 MB、内存 3.54 MB、磁盘 1.98 MB、电量 2.46 MB），不超过 16,777,216 B，最终用 30 分钟档。没有为体积删减统计字段 | 测试输出 `R3 realistic …` |
| `git diff --check` | PASS | — |
| 反证（新增 9 条，另改 1 条 `r3-3-zero-as-missing`） | 10/10 RED；`fix1-p1-3-unclamped-mean` 第一次是 GREEN，加强测试后重跑为 RED。每条都恢复了原文 | `fix1-mutations.log`、`fix1-mutations-rerun.log`；`mutations.json` 共 25 条，before 次数已用 python 校验 |

基线临时 worktree 和它的 release scratch 已删除，并执行了 `git worktree prune`。`mutations.before-fix1.json` 是改动前的备份。

### 剩余问题

- 4 数组 28 天的数据必须降到 30 分钟档才能放进 16 MiB，余量约 1.9 MB。温度区更多或 fanReadings 更多的机器可能超限（超限时仍沿用原来的拒写路径）。如需保留 5 分钟档，要另行决定减少哪些统计字段。
- 首次启动时，上次会话最后 1 小时的原始点仍会在主线程补统计（最多约 3600 点/数组）。28 天的大部分迁移已移到 actor。
- 绝对性能预算要在空闲机器上复跑；真实设备上的探头验收没有做（NOT RUN）。

## 修复第 2 轮（合并 integration 后 MiniSensorsDecodingTests 23 项失败）

- 根因：失败只在测试侧，产品的历史文件格式没有兼容问题。`MenuBarTelemetryPoint` 是按键编码的 JSON，旧字段的键名和取值都没变；D80 的 `bucketStatistics` 写在单独的可选键下，`encodeIfPresent` 为 nil 时不写，早期版本的合成 Codable 会忽略这个未知键。`testAnEarlierBuild…` 的 20 处“值错位”是测试拿 `Mirror` 的声明顺序和早期结构逐项 `zip` 造成的：新存储属性声明在第 2 位，没进 `laterFields`，后面的字段整体后移一位（实际读到的 cpuTotal 是 37.25，正确）。`testSavedHistoryRoundTripsEveryField` 的 24/23 和“not filled”，是 fixture 没有填新字段。
- 修复（只改 `Tests/StorageCleanerMacTests/MiniSensorsDecodingTests.swift`，产品代码未改）：字段数 23→24；`everyFieldPoint` 填入压缩桶统计（cpuTotal 峰值 93.75，带 cpuUser/cpuSystem 伴随值，另有 memory，各带覆盖区间）；`bucketStatistics` 加入早期版本忽略的 `laterFields`；新增断言：早期版本写回后 `bucketStatistics` 为 nil，其余旧字段一个不少。字典的打印顺序随实例变化，所以逐字段字符串比较跳过 `bucketStatistics`，改为按值 `==` 比较，并逐一核对 metric 键和伴随值。旧字段的断言和期望值都没有改。
- 反证 `fix2-history-legacy-field-replaced-by-statistics`（已写入 `mutations.json`，共 26 条）：有统计时不再写旧的 `cpuTotal` 键（模拟用统计替代旧列）。`testAnEarlierBuild…` 2 处失败，RED；`testSavedHistoryRoundTripsEveryField` 也失败。之后恢复原文并重新构建。
- 验证：Debug `--build-tests` PASS；定向 `MiniSensors|MenuBar|MetricHistory|Telemetry` 共 448 项，1 skip，0 failure（`logs/fix2-targeted.log`），其中包括 `MenuBarBucketStatisticsTests`（28 天体积上限、2 万点迁移、旧快照迁移）、`MenuBarSensorIdentityTests`、`MenuBarIndependentTopKTests`、`MetricHistoryJournalTests`。全量套件这轮没有重跑（NOT RUN）。
