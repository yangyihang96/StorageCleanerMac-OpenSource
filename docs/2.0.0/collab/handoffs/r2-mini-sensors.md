# 批次 r2-mini-sensors：D57 小窗数值接口补全

- 分支 `task/r2-mini-sensors`，基于集成分支 `d490207`；worktree `~/Developer/sc-worktrees/r2-mini-sensors`。复核轮先合入集成分支 `45b13a8`（带进 D57 补充 `bd26cd2`），后按主会话通知合入测试卫生批 `cb20ca5`（集成分支 `4fea34d`，含 `6e77b6e`）。已合并进集成分支 `454b493`；增量复核的 3 个 P2 在同一分支补修（快进到 `454b493` 后，第 14 节）。
- scratch `~/Developer/.sc-build/r2-mini-sensors/`：`debug/`（定向测试）、`strict/`（严格并发）、`verify/`（小窗性能脚本的 Release 编译缓存）、`commitcheck/`（逐个提交的索引编译检查）、`mutsrc/`＋`mutscratch/`（复核轮在 `git archive HEAD` 导出的副本上做突变，不碰 worktree）、`logs/`（全部日志，`logs/mutations/` 为第一轮、`logs/mutations-review/` 为复核轮的红灯与反证）、`shots/`（截图）、`perf/`（离屏延迟审计）、`tools/`（本批脚本）、`before-src/`（`d490207` 的 `--shared` 克隆）、`review-before-src/`（`14f3c0a` 的 `--shared` 克隆）、`before-overlay/`（只含截图场景的叠加补丁）、`dist-before/`、`dist-review-before/`、`dist-after/`。依赖从 `r2-u1-preselect/debug` 只读复制，全部构建带 `--skip-update --disable-automatic-resolution`。截图包编译缓存按 `build_and_run.sh` 的要求放在 `/tmp/storage-cleaner-r2ms-{before,review-before,after}`（本批专用名）。
- 实现：Claude 子代理（Claude Opus 5.5）。来源：DECISIONS D57（含复核后补充；另守 D2、D4、D14、D16、D39、D41、D43、D44⑤、D48、D49）、只读调研 `StorageCleanerMac-evidence/round2/mini-sensors/research-20261007.md`（第七至十节）及其 `probe/` 原始输出。
- 没有改 `ControlPaletteViews.swift`、`SafeCleanupExecutor.swift`、`CleanupExecutionViews.swift`、`Stores/ScanStore.swift`、主窗口文件、`DECISIONS.md`、`BOARD.md`，也没有改风扇辅助程序 `Sources/FanControlHelper`。

## 结论

| 项 | 结果 | 依据 |
|---|---|---|
| 数据层（SMC 按键／平台解码、范围校验、Energy Model 采样、背光核对、光照、USB-C 对外供电、SMC 电池键、后台采样） | PASS | 第 3、5 节；本机只读实测见第 9 节 |
| 界面（功耗卡五行、芯片三级拆分、电池悬停三项、传感器页修正与新增、错误注释删除、术语） | PASS（演示数据与本机真实数值截图） | 第 2、8 节 |
| 无值规则（隐藏／“本机不支持”／“—”＋“读数无效”／合法 0） | PASS（M1–M5 缺键夹具） | 第 5 节 |
| 复核必修 P1（Ultra 通道名、缺 CPU 不显示合计）、2（背光 ±20% 边界）、3（电池行统一 `B0AP`） | PASS | 第 13 节 |
| 复核建议 4–9（最长采样间隔、USB-C 缺值端口、历史兼容、零值正号、核心簇层级、平均按传感器计） | PASS（6 项全部修复） | 第 13 节 |
| 定向测试（复核轮，合入测试卫生批之后，先跑守卫类） | PASS：守卫类 6 项；定向 284 项（1 项既有条件跳过）；相关集合 1179 项（3 项既有条件跳过）；均 0 失败、exit 0 | 第 6 节 |
| 红 → 绿 → 反证 | PASS：第一轮 26 次、复核轮 24 次突变全部被测试拦下，均已恢复 | 第 5、13 节 |
| `script/verify_menu_bar_performance.sh` | PASS（复核轮最终 `f3bb93f`：exit 0，16 项，preparation P95 80.8／79.2 ms）；过程中一次 Release 测试编译失败（本批新测试引起，已修）、一次在负载 24 下 125.8 ms 超预算 | 第 7 节 |
| 小窗端到端打开／主线程（离屏审计，Debug、高负载，第一轮） | 打开时长在预算内；两个版本都有超过 50 ms 的主线程循环，需主会话空闲时用 Release 复测；复核轮没有重跑 | 第 7 节 |
| 严格并发（含测试目标） | PASS：第一轮与复核轮（`6244f9e`）均 exit 0、0 错误、0 并发警告 | 第 7 节 |
| 私有接口检查 | PASS（6 项登记用途，没有新增条目） | 第 4 节 |
| `git diff --check 4fea34d HEAD`（本批相对集成分支的全部改动，含本交接） | PASS（exit 0，无输出） | — |
| 真实数据文件 | 复核轮测试前后 `~/Library/Application Support/StorageCleanerMac/` 下 `SystemEnergySession-v1.json`、`Monitoring/MenuBarPowerHistory.json` 修改时间不变 | 第 6 节 |
| JEV | 第一轮 `jev_review` escalate；复核轮 `jev_decide` 选本批做法（0.74），均不视为批准 | 第 10、13.5 节 |
| 实机（已安装测试版）核对 | NOT RUN（按 RULES 由主会话做） | 第 11 节 |
| 增量复核 P2-1（历史全字段往返）、P2-2（缺 `B0AP` 时口径一致）、P2-3（“整机”说明）、演示 `PPBR` | PASS：守卫 6、定向 289、相关 1184 项 0 失败；35 次突变全部被拦下。P2-3 按实测写成“不含给电池充电的部分”，与复核建议相反，请主会话核对 | 第 14 节 |

## 1. 提交

第一轮：

| 提交 | 内容 |
|---|---|
| `01283be` | 数据层：SMC 按键／平台解码与范围校验、SMC 功率／电池／背光读数、背光核对、亮度与光照、USB-C 对外供电、电池电气改读 SMC、Energy Model 读取与按计数更新时刻对齐的功率估算、通道到部件的映射；白名单理由更新；解码、节奏与本机只读测试 |
| `363a6f0` | 温度：`PMU tdie*` 不再算 CPU、改为“电源管理芯片”探头；“CPU”行与一级圆环同值；新区域“充电电路”（`TCHP`）；掌托改 `Ts0P/Ts1P`、掌托与雷雳标“依据键名推断”；热采样顺带读光照；按 D57 修改锁定旧映射的测试 |
| `8ea4b49` | 界面：功耗卡五行与芯片三级、电池电气行隐藏规则、电池悬停新增项、传感器页 CPU 行三级（最高＋平均）、推断说明、充电电路行、光照行；电源页需求驱动的后台采样；参考几何改为五行；演示数据 |
| `f3cecc8` | 仅 Debug／Beta：新三级的截图场景 |
| `3f6f3f7` | 复核自查：分钟级系统负载改回用电池控制器同节奏的 V×I 核对（实时 `B0AP` 会让核对失败，本机只读测试发现）；相隔不足 0.5 s 的计数更新不做除法；“尼特”等中文措辞；live 审计截图可只拍传感器与电源页、电源页等第一个完整计数窗口 |
| `20bf737` | Energy Model 后备窗口从最后一次精确更新起算 |
| `8b6e60a` | 演示数据一致性（CPU 行＝一级圆环 53 °C）、零电流不带符号、来源写“IOReport 能耗计数” |
| `34d5fab` | 电池悬停“USB-C 对外供电”单独成组（原两列里被截成“USB-C…”）；演示历史补新区域 |
| `14f3c0a` | 电源历史三级“当前电气读数”：实测输入（`PDTR/VD0R/ID0R`）与“协商功率”分开（原来把协商值标成输入功率） |
| `41b65d2` | 交接 |

复核轮（详见第 13.1 节）：`79dd8f3`、`949ef61`、`1e56827`、`3b481bd`、`e90a970`、`85ccd97`、`45adb12`、`decfb7b`、`6244f9e`、`f3bb93f`，合并 `45b13a8`、`cb20ca5`，以及本次交接更新。

第一轮每个提交都单独编译过（`tools/check-index.sh` 把暂存区导出到 `commitcheck/src` 连测试目标一起编译，`logs/commitcheck-c1…c4.log` 均 exit 0；之后的小提交在工作区直接编译与测试）。复核轮每个提交前都在工作区编译并跑了对应的定向测试。

## 2. 条目对照表（条目 → 接口 → 本机值 → 无值行为）

本机值为 2026-10-07 本批只读实测（Mac17,9，接 65 W 电源，电量约 80%，其他会话负载波动），取本机只读测试（`MiniSensorsLiveReadingTests`）与 live 截图的范围；与调研值的对照见第 9 节。复核轮改动的行在“接口”或“无值行为”里注明。

### 2.1 电源页

| 条目 | 位置 | 接口与换算 | 本机值 | 无值行为 |
|---|---|---|---|---|
| 整机 | 二级“功耗”；三级说明按供电写（增量复核 P2-3） | SMC `PSTR`（`flt`，W，0–1000）。实测 `PSTR ≈ PDTR − B0AP`：整机耗电，不含给电池充电的部分，电池补电时含电池放电（第 14.3 节） | 37.4–87.1 W（live 截图 52.91 W） | 键不存在：行隐藏；超范围：“—”，三级“读数无效”；0 照常显示 |
| 电源输入（接电时） | 同上；三级给输入电压、输入电流、协商功率 | `PDTR`；`VD0R`（0–60 V）、`ID0R`（0–20 A）；协商值来自 `IOPSCopyExternalPowerAdapterDetails` | 34.1–63.4 W（live 47.87 W）；19.43–19.72 V；1.89–3.26 A；协商 65 W | 同上；用电池时不显示该行 |
| 电池 | 同上；三级给“方向”与“电池轨（SMC）” | **复核轮（D57 补充）**：`B0AP`（`si32` 小端 mW，SMC 约每秒更新的 V×I），正负按 `B0AC` 的方向；`B0AC` 缺失或绝对值 < 5 mA 时保留 `B0AP` 自身符号。**增量复核 P2-2**：没有 `B0AP` 而有 `B0AV`、`B0AC` 的机型用 `B0AV × B0AC`（正负即 `B0AC` 的），三级来源写“电压 × 电流（SMC）”，历史与积分同值。三级“方向”：充电中／放电中／电流约为 0（依据电流方向）；“电池轨（SMC）”为 `PPBR` 原值，只作参考 | 第一轮 `B0AP` −23.8…0 W（接电时电池补电）；复核轮只读测试时系统正在充电：+19.56 W（`B0AC` +1.520 A），同一时刻 `PPBR` +2.39 W | `B0AP` 不存在：行隐藏（`PPBR` 单独不成行）；超范围：“—”；三级缺键写“本机不支持” |
| 屏幕背光 | 同上；三级给亮度（尼特）、背光电流、12 V 供电轨与核对结果 | 先找 `PBwo` 再找 `PDBR`（`flt` W，0–200）；核对 `IDBR × VP0R`，偏差 ≤ ±20% 才显示；两者都 < 0.05 W 算合法 0；亮度 `AppleARMBacklight.IODisplayParameters.BrightnessMilliNits.value ÷ 1000` | 4.68–5.23 W（live 5.03 W；`IDBR` 0.375–0.417 A × `VP0R` 12.22–12.53 V，偏差 ≤ 0.01%）；381.8 尼特 | 两键都没有：隐藏；核对不过或缺电流／轨电压：“—”，三级写明原因；暗屏 0 W 照常 |
| 芯片合计 | 同上；三级拆分 | IOReport “Energy Model” 各部件之和；三级另列 `PZC0` 作校验。**复核轮**：通道名以 `CPU Energy` 结尾即为 CPU（Ultra 为 `DIE_0_CPU Energy`、`DIE_1_CPU Energy`），其余通道去掉 `DIE_<n>_` 前缀再分类、两个芯片相加 | 15.8–47.7 W（live 27.69 W；`PZC0` 18.9–49.4 W，采样时刻不同） | Energy Model 读不到：隐藏；第一个窗口“更新中…”；任一部分无效：“—”；某部件没有通道：不列，三级“本机不支持：…”。**复核轮**：没有 CPU 部分时不显示合计——该行保留作三级入口，值写“本机不支持”，三级列出能读到的部件，“本机不支持”以 CPU 开头（见第 13.5 节 JEV） |
| 三级：CPU | 芯片合计三级 | `CPU Energy`（没有时为各簇之和） | 20.5–38.5 W | — |
| 超级核心簇 | 同上，**缩进在 CPU 下**（CPU 已含各簇，复核 8） | `PCPU`（有 `MCPU*`、或 perflevel 名为 Super 时） | 16.5–23.4 W | 通道不存在不列 |
| 性能核心簇 | 同上，缩进 | `MCPU0`＋`MCPU1`（M1–M4 为 `PCPU`） | 3.0–15.2 W | 同上 |
| 能效核心簇 | 同上，缩进 | `ECPU*`（M1–M4、M5 基础款） | 本机没有 | 同上 |
| GPU | 同上 | `GPU Energy`（nJ）；没有时 `GPU0` | 0.03–0.53 W | 同上；缺失列入“本机不支持” |
| 神经网络引擎 | 同上 | `ANE*` | 0–0.0005 W（合法 0） | 同上 |
| 内存 | 同上 | `DRAM*` | 0.78–2.43 W | 同上 |
| 内存控制器 | 同上 | `AMCC*`＋`DCS*` | 2.1–4.3 W | 同上 |
| 显示引擎 | 同上 | `DISP*`＋`DISPEXT*` | 0.25–0.49 W | 同上 |
| 媒体 | 同上 | `ISP*`＋`AVE*`＋`MSR*` | 0.05–0.07 W | 同上 |
| 片上互连 | 同上 | `FAB*`＋`AFR*` | 0.81–1.30 W | 同上 |
| 电池电流 | 二级“电池电气” | `B0AC`（`si16` 小端 mA ÷ 1000，−30…30 A）；SMC 没有该键时退回 AppleSmartBattery 并注明“约每分钟才更新一次” | −1.94…0 A（live −0.16 A） | 键不存在且无后备：行隐藏；超范围：“—” |
| 电池电压 | 同上 | `B0AV`（`ui16` 小端 mV，1–30 V） | 12.23–12.43 V（live 12.32 V） | 同上 |
| 电芯电压 | 电池悬停三级“电芯电压”组 | `BC1V…BC4V`（`ui16` 小端 mV，2–5 V），只列存在的键 | 4.08–4.14 V ×3 | 都没有：“电芯电压 本机不支持”；超范围：“读数无效” |
| 电池温度 | 电池悬停三级“健康”组；简洁密度与电源历史三级同源 | `TB0T`（`flt` °C）→ `B0AT`（`ui16` 小端 0.1 K − 273.15）→ AppleSmartBattery `Temperature`（macOS 27.2 没有）。**偏离 D57**：D57 写的后备是 HID 电量计，本批没有接，理由见第 11 节第 14 条 | 36.3–36.6 °C | “本机不支持”／“读数无效” |
| USB-C 对外供电 | 电池悬停三级单独一组，按“端口 N” | AppleSmartBattery `PowerOutDetails[].Watts`（mW ÷ 1000，0–240 W），只列 > 0 的端口 | 端口 2 1.19–1.37 W；端口 3 0.03–0.04 W | 键不存在：“本机不支持”；**复核轮**：缺 `Watts` 的端口只跳过，所有端口都缺时“本机不支持”；`Watts` 不是数字或超范围：“读数无效”；全为 0：“0.00 W” |
| 电源历史三级“当前电气读数” | 电源页 | 输入功率／电压／电流为实测 `PDTR/VD0R/ID0R`；适配器额定值叫“协商功率”（无实测时才列协商电压／电流）。电池电流、电池功率与“电池功率”历史来自电池电气快照，**复核轮起为 `B0AP`（按 `B0AC` 定正负）**；零值不带“+”（复核 7） | live：47.87 W、19.61 V、2.44 A，协商 65 W | 无实测：只显示协商值并如实命名 |

### 2.2 传感器页

| 条目 | 位置 | 接口 | 本机值 | 无值行为 |
|---|---|---|---|---|
| CPU 行 | 温度卡 | 与一级圆环同值（M5 为最热的 `Tp*` 核心）；三级给“最高”和“平均（N 个传感器）”（复核 9：M1–M4 是每簇几个探头，不是每核一个） | 83–88 °C（live 85 °C，一级圆环同为 85 °C）；平均 80.7–83.5 °C（18 个传感器） | 无芯片温度：行不出现 |
| 超级核心／性能核心 | 温度卡 | `Tp00…Tp0K` 最高／`Tp0O…Tp0y` 最高（不变） | 84.2 / 82.1 °C | 同前 |
| 充电电路 | 温度卡（电池之后） | `TCHP`，仅 Apple 芯片；历史里写在新键 `addedTemperatureReadings`（复核 6） | 52–55.7 °C | 键不存在：不出现 |
| 掌托 | 温度卡；三级注明“依据键名推断” | `Ts0P`/`Ts1P` 均值（不再用 `TDeL/TDeR`），仅 M5 拓扑完整时 | 32.2–32.4 °C | 同上 |
| 雷雳左／右 | 同上 | `TaLT`/`TaRT`，三级注明“依据键名推断” | 45–46.3 / 37–37.9 °C | 同上 |
| 电源管理芯片 | 三级“硬件探头” | HID `PMU tdie*/tdev*` 最高（`PMU tcal` 除外）；HID 没有时用 SMC `TPDX/TRDX/TUDX` 最高 | 80.7–82.0 °C | 都没有：不列 |
| 光照 | 页末“环境”卡 | 任一带 `CurrentLux` 属性的服务（`IOPropertyExistsMatch`），0–200 000 lx | 62–172 lx（随环境光变化） | 没有传感器：整卡不出现；超范围：“—”＋“读数无效”；0 lx 照常 |

不显示（D57 ⑤）：SSD 功耗、Wi-Fi 功耗、主板温度、外接适配器本体温度、外接显示器功耗——代码里没有任何对应读数或行。

## 3. 关键实现

### 3.1 SMC：按键、按平台解码

- `SMCValueDecoder`（`SMCFanSpeedService.swift`）：`ui8/si8` 无字节序；`ui16/si16/ui32/si32/ui64/si64` 的字节序按键和平台决定——Apple 芯片上电池类（`B0AC B0AV B0AP B0AT B0RM B0CT B0FC B0DC B0TF BC1V…BC4V`）为小端、`#KEY` 为大端、其他多字节整型键返回 nil（不猜）；Intel 一律大端。`flt` 按主机小端，非有限值返回 nil；Intel 定点格式 `fpe2/sp78/spf0` 保持原写法。平台按硬件判断（`hw.optional.arm64`），不按编译架构。
- 原 `decodeDouble`（第 614–648 行）把 `ui16/ui32` 一律按大端，已删除并由上面替换；现有读取（`FNum` `ui8`、风扇与温度 `flt`）结果不变。
- `SMCConnection` 改为 internal。实际调用的选择子只有 2（内核索引）、5（读字节）、9（键信息）；**更正：8（按序号取键 `readIndex`）只是在原有的 `Command` 枚举里声明（本批之前就有），没有任何调用**；没有写选择子 6。新增 `readRaw` 区分“键不存在”（本机不支持）与“存在但读不出”（读数无效）。`SMCMeasurementSpec` 负责换算与合理范围，超范围一律无效、不截断。
- 本批没有任何写入 SMC、IORegistry 或系统设置的代码；风扇、充电、电源、亮度都没碰。

### 3.2 Energy Model：按计数更新时刻对齐

- 本机 IOReport “Energy Model” 的 mJ 通道约每 2.1 s 批量更新，nJ 的 `GPU Energy` 每次采样都更新（调研 §4.2）。用采样窗口去除会出现 0 W 和 2–3 倍尖峰（测试 `testTheNaiveWindowDivisionWouldHaveFlickered` 复现了这一点）。
- 每个简单通道的 `RawElements` 是一个 `IOReportElement`（公开头文件 IOKit/IOReportTypes.h：provider_id、channel_id、channel_type、timestamp、values），第 24 字节起是驱动最后一次更新该计数的 `mach_absolute_time`，第 32 字节起是值。读取时先核对该值与 `IOReportSimpleGetIntegerValue` 一致、时间戳不晚于读取时刻，否则视为不可用。
- 功率 = 两次计数更新之间的能量 ÷ 两次更新的时间差，按各通道自己的单位标签换算（mJ／uJ／µJ／nJ／J，其他单位不用）。这与采样间隔无关：2 s、抖动的 1.7–2.5 s、1 s、5 s 采样在 ±30 ms 抖动的 2.1 s 批量下，显示值都在真值 ±1% 内，从不出现 0 或尖峰。
- 没有新计数的窗口沿用上次值并标“更新中”；第一个窗口没有值（显示“更新中…”）；计数变小视为复位，重新取基线；相隔不足 0.5 s 的更新不做除法；超过 1000 W 为无效。离开电源页时重置基线（在后台线程做），保留上次值标“更新中”，直到新窗口产生。
- **复核轮（建议 4）**：两次采样相隔超过 10 s（`maximumSampleGap`）也重新取基线——离开电源页的暂停没及时到、或系统睡眠时，第一个窗口不再是整段间隔的平均。间隔按 `mach_continuous_time` 计（睡眠时计数自己的 `mach_absolute_time` 不走）；只看采样间隔，不看单个通道两次更新的间隔，免得长时间不更新的通道永远拿不到值。
- **复核轮（P1）**：通道名以 `CPU Energy` 结尾即为 CPU 合计；`DIE_<n>_`（或 `DIE_<n> `）前缀去掉后再按原规则分类，Ultra 两个芯片的同类通道相加；`DIE_X_…`、`DIE__…`、`DIE_0PCPU` 等不认。没有 CPU 部分时没有芯片合计。
- 读不到时间戳时退回“计数变化时刻＋至少 8 s 窗口”（D57 允许 ≥ 4 s；8 s 让 2 s 采样下的量化误差约在四分之一内），并从最后一次精确更新起算；长时间不动的计数视为测得的 0。
- 一次 Energy Model 采样本机约 6–8 ms（过滤到 17 个通道也一样，内核整组采集），所以不做亚秒级快采，只在电源页每 2 s 采一次，与处理器遥测同频。

### 3.3 采样位置与电池口径

- 新需求位 `needsPowerTelemetry`，只有电源页（`section == .power`）打开时为真。`MenuBarAuxiliaryMonitorState.refreshPowerTelemetry` 每 2 s 在 `Task.detached(priority: .utility)` 里读 SMC（约 3–5 ms）、亮度与 Energy Model，主线程只发布结果；取消时在后台重置 Energy Model 基线。卡片指纹 `.battery`、`.levelThree` 加入 `powerTelemetryRefreshedAt`。
- 光照随现有热采样一起读（约 0.3–0.5 ms），热采样本身只在小窗可见（2 s）或菜单栏需要温度／风扇时（15 s）运行。
- 电池的 SMC 键随现有电池采样读取（可见时 2 s、后台 30 s）。D49 的接电能耗积分仍用电池控制器每分钟一次的 `SystemLoad`，其一致性核对改回与之同节奏的控制器 V×I（`3f6f3f7`）。
- **复核轮口径变化**：电池功率历史与用电池时的能耗积分改用 `B0AP` 瞬时值（按 `B0AC` 定正负），来源标签改为 `smc-battery-power-b0ap`（无 SMC 键时 `battery-controller-voltage-current`），详见第 13.2 节。

### 3.4 复用

没有新造采样系统：IOReport 复用 `CPUPerformanceStateService.swift` 里的 `IOReportSymbols`／`IOReportClient`（新加两个可选符号，缺失时只隐藏芯片拆分、不影响频率）；采样复用辅助监视器的需求机制；界面复用 `geekSensorReadoutCard`、`GeekHoverDetailTarget`、`GeekSensorMetricHoverDetail`、`GeekBatteryCompactValueGrid`、`liveCard`；温度历史复用 `MenuBarTelemetryChannel`（新增 `chargingCircuitTemperature`）。

### 3.5 历史兼容（复核 6）

- 旧版本按合成的 `Codable` 严格解码 `temperatureReadings`：只要一条区域不认识，这个点、`BoundedMonitoringArray` 乃至整份历史文件都读不出来。
- 现在 `MenuBarTelemetryPoint` 自写编解码：`SystemTemperatureZone.addedAfterOriginalHistoryFormat`（目前只有 `chargingCircuit`）写在新键 `addedTemperatureReadings`，旧版本忽略这个键、整份历史照常读出（只是看不到充电电路的历史）；其他字段与原合成实现逐字段相同，没有新区域的点不多出键。本版本读两个键合并，遇到不认识的区域跳过、不再整份失败。
- 以后再加温度区域，要放进 `addedAfterOriginalHistoryFormat`，否则旧版本会再次整份读不出。
- 影响面：只有 `14f3c0a` 一类第一轮构建会把 `chargingCircuit` 写进原键；本批没有安装，正式和测试版用户的历史文件里不会有这种点。

## 4. 私有接口白名单

- 没有新增条目：Energy Model 写在 `CPUPerformanceStateService.swift` 里，新文件（`SoCPowerTelemetry.swift`、`SMCPowerTelemetryService.swift`、`HardwareReading.swift`）没有 `dlopen`／`dlsym`；SMC 与注册表读取不加条目（调研第八节）。复核轮新加的 `mach_continuous_time` 是公开 API。
- 只改了该文件两条已有条目的理由，写明 Energy Model 用途与实际调用的函数。
- `python3 script/check_private_api.py` → exit 0，“private API check passed (6 allowlisted uses)”（第一轮与复核轮 `6244f9e` 相同，`logs/review-private-api.log`）。

## 5. 测试：红 → 绿 → 反证

第一轮新增测试：`MiniSensorsDecodingTests`（15 项，SMC 夹具是 Mac17,9 调研探针的原始字节，不含序列号等私人信息）、`SoCPowerEstimatorTests`（15 项）、`MiniSensorsNoValueRuleTests`（19 项，含 M5 Pro、M5 基础款、M1–M4 无背光键、台式机、超范围、合法 0、首个窗口／过期、Energy Model 不可用、电池电气缺键、电池悬停、PMU、CPU 行、掌托与充电电路、光照、只在电源页且在后台采样、只读契约、电源历史三级）、`MiniSensorsLiveReadingTests`（1 项，本机只读读一遍并打印，读不到 `PSTR` 时跳过）。复核轮后为 20／19／25／1 项（第 13 节）。测试不写真实 `~/Library/Preferences`、`~/Library/Caches`：语言只改测试进程的 volatile argument domain（沿用 `MiniWindowLogicLanguageScope`，在 `TestPreferenceHygieneTests` 的白名单里），没有直接建 `UserDefaults(suiteName:)`；碰到电池功率历史、能耗积分的测试都用注入的空存储（`powerHistoryURL: nil`、`SystemEnergyAccumulator(fileURL: nil, …)`），不写真实的 `SystemEnergySession-v1.json`、`Monitoring/MenuBarPowerHistory.json`。

第一轮的红灯与反证用 `tools/mutations.py` 做：每次对一个源文件做唯一的文本替换（红＝恢复改前行为，反证＝换一种方式破坏修复），编译、跑对应测试、按字节恢复，结束后核对工作区干净（日志 `logs/mutations/*.log`、`summary*.json`）。

| 项 | 红（改前行为） | 反证 | 绿 |
|---|---|---|---|
| SMC 字节序 | 整型一律大端：7 个测试失败 | 有符号数不做符号扩展：6 个失败 | 通过 |
| 背光核对 | 不核对：2 个失败 | 容差 200%：2 个失败（**更正**：±20% 的边界当时没有用例，复核员把容差改成 50% 后全部通过；复核轮已补 ±19%／±21% 四个用例，容差 50% 与 10% 都被拦下，见第 13.3 节） | 通过 |
| Energy Model 节奏 | 窗口能量 ÷ 窗口时长：3 个测试、284 处断言失败 | 忽略时间戳：4 个失败；无新计数不标“更新中”：1 个失败 | 通过 |
| 小间隔更新 | 不设下限：1 个失败 | 下限 0.005 s：1 个失败 | 通过 |
| 后备窗口起点 | 仍从首个基线起算：1 个失败 | — | 通过 |
| 无值规则 | 缺键显示“—”行（旧卡片做法）：4 个失败 | 无效显示成数字：3 个失败 | 通过 |
| PMU 不算 CPU | 恢复旧映射：3 个失败 | CPU 行恢复旧规则（有核心区域时不出现）：1 个失败 | 通过 |
| 掌托／推断说明 | 掌托回到 `TDeL/TDeR`：4 个失败 | 不标推断：2 个失败 | 通过 |
| 充电电路 | 不读 `TCHP`：2 个失败 | — | 通过 |
| 电池改读 SMC | 只用电池控制器：2 个失败 | 功率用 V×I 而非 `B0AP`：1 个失败 | 通过 |
| USB-C 对外供电 | — | 把 mW 当 W：1 个失败 | 通过 |
| 分钟负载核对 | 用实时 `B0AP`：1 个失败 | 不计电池：1 个失败 | 通过 |
| 采样位置 | 电源页不请求：1 个失败 | 在主线程采样：1 个失败 | 通过 |
| 光照行 | 没有传感器也出行：1 个失败 | — | 通过 |
| 电源历史三级 | 协商值仍标“输入功率”：1 个失败 | — | 通过 |

注：“红”的那次 `red-novalue` 里还额外失败了本机只读测试 `testTheLocalSystemLoadOnExternalPower`，由此发现分钟负载核对的问题并在 `3f6f3f7` 修复（见“分钟负载核对”一行）。

### 按 D57 修改的锁定测试

- `SystemMonitorServiceTests.testAppleSiliconTemperatureServicePrefersRealtimeDieSensors`：原断言 `PMU tdev8` 为芯片温度；改为 PMU 不算、`PMGR SOC Die Temp` 仍算，只有 PMU 时为 nil。
- `testAppleSiliconTemperatureServiceGroupsOnlyRealRegionalReadings`：去掉由 PMU 形成的 `.chip` 区域。
- `testSMCFanSpeedServiceDoesNotPresentM5SSDControllersAsPalmRest` → 改名 `testSMCFanSpeedServiceReadsM5PalmRestFromTs0PAndTs1P`（D57 推翻“Ts0P/Ts1P 是 SSD 控制器”）；`testSMCFanSpeedServiceGroupsM5AndPeripheralTemperatureZones` 的夹具改用 `Ts0P/Ts1P`。
- `GeekPowerViewTests.testSecondarySurfaceMatchesReferenceCardGeometry`：功耗卡参考高度按五行（`secondaryContentHeight` 492 → 538，电源模式偏移 390 → 436、台式机 163 → 209，所需高度 547 → 593）。
- `SystemEnergyACTelemetryTests.testThePowerRowsShowOnlyWhatIsMeasured`：N16-6 的“整机 · 系统负载／电池侧”行由 D57 的 `PSTR` 等取代，改为新行，仍保留“没有读数不出行”。
- 复核轮：`SoCPowerEstimatorTests` 原第 242 行只测 `DIE_1 CPU Energy`，现两种写法都测；`MiniSensorsNoValueRuleTests` 电池行期望值由 `PPBR` 的 −11.43 W 改为 `B0AP` 的 −10.75 W，CPU 平均的标题改为“个传感器”；`SystemEnergyACTelemetryTests` 电池样本的来源标签与界面文字按新标签；`GeekSensorsPowerHoverDetailTests` 锁定的“当前 +0.00 W · 空闲”改为“当前 0.00 W · 空闲”（复核 7 指出的正号问题本身）。

## 6. 定向测试命令与结果

第一轮（`14f3c0a`）：

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
swift build --scratch-path ~/Developer/.sc-build/r2-mini-sensors/debug --jobs 4 --skip-update --disable-automatic-resolution --build-tests
swift test --scratch-path ~/Developer/.sc-build/r2-mini-sensors/debug --skip-update --disable-automatic-resolution --skip-build \
  --filter 'Sensor|Power|Battery|Temperature|Fan|MiniWindow|MenuBar|SystemMonitor|CPUPerformance|GPU|Energy|Telemetry|MetricHistory|ControlPalette|Geek|PanelChart|HardwareControl|SMC'
```

- exit 0，1171 项，0 失败，3 项跳过（`logs/related-final.log`）：`EnergyImpactServiceTests.testLiveEnergySnapshotWhenEnabled`（既有环境变量开关）、`MenuBarPerformanceRegressionTests.testOptimizedLongHistoryPreparationAndCachedDeliveryBudgets`（Debug 下既有跳过，由第 7 节的 Release 脚本执行）、`SystemMonitorServiceTests.testAppleSiliconTemperatureServiceCanProbeLocalChipTemperatureWhenAvailable`（既有硬件条件跳过：改前它在本机能跑，是因为把 HID `PMU tdie` 当成了芯片温度；D57 之后 M5 没有 HID 的 CPU 传感器）。

复核轮（合入测试卫生批之后，`tools/review-tests.sh`：同一编译缓存，先跑守卫类，再跑定向类，最后跑与第一轮相同的相关集合；前后各记一次真实数据文件的修改时间）：

```bash
# tools/review-tests.sh final（摘录）
swift test … --filter 'TestPreferenceHygieneTests'
swift test … --filter 'MiniSensorsDecodingTests|MiniSensorsNoValueRuleTests|MiniSensorsLiveReadingTests|SoCPowerEstimatorTests|SystemEnergyACTelemetryTests|SystemEnergyAccumulatorTests|GeekPowerViewTests|GeekSensorsPowerHoverDetailTests|MenuBarTertiaryDetailTests|MenuBarPowerHistoryStoreTests|MenuBarHistoryGapTests|MiniWindowPressureHistoryCompactionTests|MiniWindowMemoryPressureLevelTests|MiniWindowKeptHistoryTests|MiniWindowDemoDataTests|SensorDetailIntegrationTests|SystemMonitorServiceTests' \
  --skip 'testMenuBarMonitorStatePublishesWithoutInvalidatingScanStore'
swift test … --filter '（与第一轮相同的相关集合）' \
  --skip 'MenuBarSimplePanelQuitTests|MiniWindowMemoryQuitSelectionTests|testMenuBarMonitorStatePublishesWithoutInvalidatingScanStore'
```

| 运行（`6244f9e`，2026-10-07 20:18–20:19） | exit | 结果 | 日志 |
|---|---|---|---|
| 守卫类 `TestPreferenceHygieneTests` | 0 | 6 项，0 失败 | `logs/review-tests-final-guard.log` |
| 定向（17 个类） | 0 | 284 项，0 失败，1 项跳过（`testAppleSiliconTemperatureServiceCanProbeLocalChipTemperatureWhenAvailable`，既有硬件条件） | `logs/review-tests-final-targeted.log` |
| 相关集合 | 0 | 1179 项，0 失败，3 项跳过（与第一轮同样的三项既有条件） | `logs/review-tests-final-related.log` |

- 真实数据文件（只看修改时间与大小，不读内容）：运行前后 `SystemEnergySession-v1.json` 均为 19:30:24／255 B，`Monitoring/MenuBarPowerHistory.json` 均为 19:58:08／17 366 B，`Monitoring/MetricHistory-v1.json` 均为 10-04 15:17:05——本批测试没有写它们（19:30、19:58 的修改不在本次运行内，来源未查明，可能是其他会话的测试，见 N26）。汇总 `logs/review-tests-final.log`。
- 过程中每个修复提交前的定向运行（同一编译缓存）均 0 失败；其中一次在 `45adb12` 前失败 1 项，是旧测试锁定了“当前 +0.00 W · 空闲”，按复核 7 改为“当前 0.00 W · 空闲”。
- 之后的 `f3bb93f` 只把一个演示数据测试放进 `#if DEBUG || STORAGE_CLEANER_BETA`，Debug 下编译内容不变；在 `f3bb93f` 上重跑 `MiniSensorsNoValueRuleTests` 25 项 0 失败。

- 跳过说明：`--skip` 去掉的三处会建默认 `ScanStore()`，按 BOARD N26 会改写本应用 Application Support 下的真实数据（`MenuBarSimplePanelQuitTests`、`MiniWindowMemoryQuitSelectionTests`、`SystemMonitorServiceTests.testMenuBarMonitorStatePublishesWithoutInvalidatingScanStore`），都与本批无关；其余“跳过”为上面三项既有条件。Debug 全量没有跑（按任务由主会话在集成分支跑）。

## 7. 性能、严格并发

- 第一轮：`STORAGE_CLEANER_VERIFY_ROOT=~/Developer/.sc-build/r2-mini-sensors/verify SWIFT_BUILD_JOBS=4 script/verify_menu_bar_performance.sh` → exit 0；源路径约束通过；`MenuBarPerformanceRegressionTests` 16 项 0 失败；`MENU_PERF preparation_p95_ms=75.8 cached_delivery_p95_ms=0.0015`（预算 100 ms／100 ms）（`logs/perf-1.log`，代码 `14f3c0a`）。
- 复核轮（同一命令、同一 `verify/` 缓存，`logs/review-perf*.log`）：
  1. `6244f9e`：exit 1，Release 测试编译失败——本批 `6244f9e` 新加的测试读只在 Debug／Beta 编译的 `MiniWindowDemoData`（“cannot find 'MiniWindowDemoData' in scope”）；`f3bb93f` 修复（`logs/review-perf-red-release-build.log`）。
  2. `f3bb93f` 第一次：exit 1，`testOptimizedLongHistoryPreparationAndCachedDeliveryBudgets` 的 preparation P95 125.8 ms > 100 ms（`logs/review-perf-run1-load24.log`）。当时负载 22–25（另一批次的截图应用、其他会话的 xctest 与编译、Finder、fseventsd 各占一个核以上）。该测试只测 `GeekPreparedLineFrame`／`MenuBarDerivedCache`（`MenuBarPreparedChart.swift`、`MenuBarDerivedCache.swift`），本批没有改这两个文件，也没有改 `MenuBarTelemetryPoint` 的存储字段（只加了编解码扩展）。没有放宽预算。
  3. `f3bb93f` 立即重跑两次：exit 0，16 项 0 失败，`MENU_PERF preparation_p95_ms=80.8 cached_delivery_p95_ms=0.0017`；再一次 79.2／0.0018 ms（`logs/review-perf-run2.log`、`logs/review-perf-run3.log`），负载仍在 18–21。第一轮为 75.8 ms。负载高时这一项会超预算，建议主会话在空闲时以集成分支复测。
- 端到端（第一轮，`tools/latency-run.sh`：`--menu-bar-performance-audit` ＋ `--menu-bar-latency-script=phases=first,openclose,modules,steady;iterations=5;settle=10;steady=30;maxLoad=100`，面板在所有屏幕之外、不激活应用、不发输入事件；Debug 包、隔离身份；本机负载 8–24）。同条件改前 `d490207`／改后 `14f3c0a`（`perf/{before,after}/audit.jsonl`，`tools/latency-summary.py`）。**更正**：样本只有 1–10 个，原表标成“P95”的其实是样本最大值，现改为中位数＋最大值：

| 指标（样本数） | 改前 中位数／最大 | 改后 中位数／最大 | 预算 |
|---|---|---|---|
| 打开 warm（6） | 16.1／18.6 ms | 18.4／36.0 ms | 100 ms |
| 打开 cold（5） | 83.1／89.2 ms | 58.4／106.4 ms | 250 ms |
| 首次打开（1） | 68.3 ms | 83.1 ms | 250 ms |
| 电源页二级首绘（10） | 44.2／58.3 ms | 45.5／64.9 ms | 100 ms |
| 传感器页二级首绘（10） | 44.7／62.1 ms | 46.6／79.8 ms | 100 ms |
| 超过 50 ms 的主线程循环（整次运行） | 61 次，最长 137.9 ms | 58 次，最长 134.5 ms | 50 ms |
| 其中电源页切换时 | 5 次，最长 66.9 ms | 7 次，最长 78.0 ms | 50 ms |

  - 两个版本在 Debug、高负载下都超过 50 ms（改前已有），停顿段落统计里没有本批的采样（采样在后台）；电源页次数与最长时间略多，在噪声范围内但不能据此判定通过。**需主会话在空闲时用 Release 复测主线程阻塞。** 复核轮只改了后台估算、三级行内容与格式，没有重跑端到端审计。
- 严格并发：第一轮 `swift build --scratch-path …/strict --skip-update --disable-automatic-resolution --build-tests -Xswiftc -strict-concurrency=complete` → exit 0，0 错误，0 并发警告（`logs/strict-concurrency.log`、`logs/strict-concurrency-final.log`）。复核轮（`6244f9e`，同一 `strict/` 缓存增量编译，121.6 s）→ exit 0，0 错误，0 并发警告；只有 `--skip-update` 弃用提示和既有的 `BrowserPrivacyRecoveryTests.swift:467` “no calls to throwing functions” 警告（`logs/review-strict.log`）。

## 8. 截图

- 第一轮并排图（左改前 `d490207`，右改后 `14f3c0a`）：`~/Developer/.sc-build/r2-mini-sensors/shots/pairs/`，20 张：

| 内容 | 夜间纯黑 | 日间石墨 |
|---|---|---|
| 电源页二级 | `menu-power-secondary-dark.png` | `menu-power-secondary-light.png` |
| 芯片合计三级（改前没有，左为旧功耗卡第一行三级） | `menu-power-chipBreakdown-dark.png` | `…-light.png` |
| 屏幕背光三级（改前没有，同上） | `menu-power-backlightDetail-dark.png` | `…-light.png` |
| 电池悬停三级（电芯电压、电池温度、USB-C 对外供电） | `menu-power-batteryDetail-dark.png` | `…-light.png` |
| 电源历史三级（实测输入与协商功率） | `menu-power-liveElectricalReadings-dark.png` | `…-light.png` |
| 传感器页二级（CPU 行、充电电路、掌托、雷雳、光照） | `menu-sensor-secondary-dark.png` | `…-light.png` |
| CPU 行三级（最高＋平均） | `menu-sensor-cpuRowDetail-dark.png` | `…-light.png` |
| 掌托行三级（依据键名推断；改前演示数据没有掌托，左为占位） | `menu-sensor-palmRestDetail-dark.png` | `…-light.png` |
| 硬件探头三级（电源管理芯片） | `menu-sensor-hardwareProbes-dark.png` | `…-light.png` |
| 光照三级（改前没有，左为占位） | `menu-sensor-ambientLightDetail-dark.png` | `…-light.png` |

- 复核轮并排图见第 13.4 节（同一目录，文件名以 `review-` 开头）。
- 原图：`shots/{before,after}-mini-{dark,light}/`、`shots/review-{before,after}-{dark,light}/`；脚本 `tools/capture-mini.sh`（沿用 `evidence/tools/capture-mini-demo.sh` 的做法，但语言、首次启动、更新设置改用启动参数，不写共用偏好域；集成根目录在 `~/Library/Caches/StorageCleanerIntegration-r2ms-*`，每次拍完删除；复核轮加了 `场景#电池状态` 写法，传 `--debug-battery-state=`）、`tools/make_pairs.py`、`tools/make_pairs_review.py`、场景表 `tools/scenarios.txt`、`tools/scenarios-review.txt`。改前包 = 对应提交加只含截图场景的叠加补丁（`before-overlay/d490207-debug-capture-overlay.patch`、`before-overlay/review-14f3c0a-debug-scenarios.patch`；构建信息 dirty=true，产品代码就是该提交）。改后包 dirty=false。日间小窗按 D44⑤ 仍是石墨深色。高负载下单个场景偶尔超时没拍到，用更长等待（`MINI_WAIT_STEPS=120／200`）补拍（`logs/capture-review-*.log`）。
- 演示数据：数值取本机实测量级（不用 0，合法 0 示例除外）；演示处理器沿用原夹具的 “M4 Pro”，所以芯片拆分显示性能核心簇／能效核心簇；本机的超级核心簇／性能核心簇见 live 截图与测试。
- **本机真实数值**（第一轮）：`shots/live-dark/`。本批自建 Debug 包（`14f3c0a`）、隔离身份 `com.local.StorageCleanerMac.integration`，参数 `--capture-menu-bar-live-audit --capture-menu-bar-live-audit-sections=sensors,power`（只拍这两页），语言与外观用 `-app.language zhHans -menuBar.miniWindowAppearance dark` 启动参数传入，不写共用偏好域；拍完立即 TERM，脚本核对进程已退出；截图走离屏绘制，没有激活或跨屏移动窗口。为不留应用名单，电源页图裁掉了“使用显著能耗”列表：`live-power-secondary-cards.png`、`live-power-history-detail.png`、`live-sensors-secondary.png`、`live-sensors-history.png`。复核轮没有重拍 live 截图（电池行在 live 图里仍是 `PPBR` 口径），本机 `B0AP` 口径的数值来自复核轮的本机只读测试（第 9 节）。

## 9. 本机真实数值与调研值对照

| 项 | 调研（同机，另一时刻） | 本批 | 说明 |
|---|---|---|---|
| 整机 `PSTR` | 57.1 W（重负载）／38.3 W | live 52.91 W；另一次 live 37.42 W；只读测试 41.2／46.7／87.1 W | 同一量级，随负载变化 |
| 电源输入 `PDTR`／`VD0R`／`ID0R` | 54.3 W／19.5–19.8 V／1.3–3.1 A | live 47.87 W（19.61 V × 2.44 A）；另一次 34.08 W；37.3–63.4 W；19.43–19.72 V；1.89–3.26 A | 一致；协商值 65 W／20 V／3.25 A 与实测分开显示 |
| 电池（复核轮起 `B0AP`，按 `B0AC` 定正负）／`PPBR` | `B0AP` −5.5…0 W／`PPBR` 2.6 W | 第一轮：`B0AP` −23.8…0 W，`PPBR` 0.55–18.6 W（live 截图按旧口径显示 −0.98 W）；复核轮（接电、系统正在充电）：`B0AP` +19.563 W、`B0AC` +1.520 A，电池行 +19.56 W／“充电中”，`PPBR` +2.387 W | 补电与充电两个方向都与 `B0AC` 一致；充电时 `PPBR` 只有 `B0AP` 的约八分之一，说明它不是电池充放电功率，只作三级参考是对的 |
| 屏幕背光 `PDBR`／`IDBR`／`VP0R` | 4.47–5.00 W／0.36–0.40 A／12.4–12.5 V | live 5.03 W；另一次 4.87 W；4.68–5.23 W；0.375–0.417 A；12.22–12.53 V | 核对偏差 ≤ 0.01%，全部通过 |
| 亮度 | 381.8 nits | 381.8 尼特 | 相同 |
| 光照 `CurrentLux` | 161 | 172 lx（live）；62、78、115、138 lx | 随环境光变化 |
| 芯片合计／`PZC0` | 32.1／31.5 W（空闲段） | live 27.69 W；另一次 15.78 W；24.5–47.7 W／18.9–49.4 W | 量级一致；两者不是同一时刻（`PZC0` 每秒，Energy Model 约 2.1 s 一批） |
| 超级核心簇／性能核心簇 | 19.55／4.52 W | 16.5–23.4／3.0–15.2 W | 一致 |
| GPU／神经网络引擎／内存 | 0.53／0／1.2–2.2 W | 0.03–0.53／0–0.0005／0.78–2.43 W | 一致 |
| 内存控制器／显示引擎／媒体／片上互连 | 2.1–3.6／0.44–0.52／约 0.06／0.8–1.1 W | 2.1–4.3／0.25–0.49／0.05–0.07／0.81–1.30 W | 一致 |
| 电池电流／电压 | −0.44…0 A／12.34–12.37 V | live −0.16 A／12.32 V；−1.94…0 A／12.23–12.43 V | 一致 |
| 电芯电压 | 4.095／4.100／4.102 V | 4.08–4.14 V | 一致 |
| 电池温度 `TB0T` | 36.0–36.8 °C | 36.3–36.6 °C | 一致；AppleSmartBattery 仍没有 `Temperature` |
| USB-C 对外供电 | 端口 2 1.26 W、端口 3 0.03 W | 端口 2 1.19–1.37 W、端口 3 0.03–0.04 W | 一致 |
| CPU（`Tp*` 最高） | 85–102 °C | live 85 °C；83–88 °C；与一级圆环同值 | 一致 |
| GPU（`Tg*` 均值） | 78.6–83.6 °C | 62–71 °C | 负载较低 |
| SSD／电池区／散热气流 | 46–47／36–37／57–63 °C | 47–50／36–37／53–58 °C | 一致 |
| 掌托 `Ts0P/Ts1P` 均值 | 34.1／31.8 °C | 32.2–32.4 °C | 一致 |
| 雷雳左／右 | 46／38 °C | 45–46.3／37–37.9 °C | 一致 |
| Wi-Fi／充电电路 | 65–67／57–59 °C | 55–62／52–55.7 °C | 负载较低 |
| 电源管理芯片（HID `PMU tdie*` 最高） | 66–89 °C | 80.7–82.0 °C | 一致 |

来源：`logs/live-probe-1.log`、`logs/green-related-2.log`、`logs/related-final.log`、复核轮 `logs/review-tests-final-targeted.log` 的 `LIVE:` 行与 `shots/live-dark/`。成本（同一测试计时）：SMC 功率一轮 3.3–4.7 ms，`CurrentLux` 0.3–0.5 ms，Energy Model 一次 6.4–7.7 ms。

## 10. JEV

- 第一轮 `jev_review`（jev-latest，只提交需求摘要、改动摘要与关键代码片段、测试摘要，不含私人信息）：action=**escalate**，safe_to_apply=0.52，composite=0.79；correctness 1.91（置信度 0.86）、spec_match 1.90（0.86）、test_gap 0.35（0.47）、blast_radius 1.98（0.97）。**不视为批准**；影响面评分高，与第 11 节的历史口径变化一致，需主会话复核。
- 复核轮 `jev_decide`：见第 13.5 节。

## 11. 未解决问题与需主会话实机核对

1. **iStat 名称**：`Ts0P/Ts1P`（掌托）、`TaLT/TaRT`（雷雳）仍是依据键名推断，三级已注明；需在 iStat 界面核对显示名。
2. **充电方向**：电池行现在是 `B0AP`、按 `B0AC` 的方向定正负（D57 补充）。复核轮的本机只读测试恰好赶上系统在充电（本批没有改充电状态）：`B0AC` +1.520 A、`B0AP` +19.563 W，电池行 +19.56 W、方向“充电中”，与按电流定方向一致；同一时刻 `PPBR` +2.387 W，说明 `PPBR` 不是电池充放电功率。D57 补充要求“正负号和 `PPBR` 与 iStat 的差别装机后实机核对”，这一步仍需主会话做。
3. **背光随亮度变化**：只在 381.8 尼特下核对通过；改亮度对照没做（不允许改设置）。
4. **其他机型**：M1–M4、M5 基础款、Ultra 未实测（`PBwo`、M2/M3 是否有 `PDBR`、`ECPU` 通道名、HID PMU 名称、Ultra 的 `DIE_<n>_` 通道名按 macmon 源码）。无值规则由夹具覆盖，真实键名以实机为准。
5. **神经网络引擎**：只见到空闲 0 W，负载下未验证。
6. **风扇曲线（更正）**：实际驱动风扇的自定义曲线在辅助程序 `Sources/FanControlHelper` 里，读的是它自己的 SMC 键表（`curveTemperature`：`cpuTemperatureKeys` 等），本批没有改它，**风扇转速不变**。变化的只是应用里的预览温度：应用侧 `.cpu`／`.chipMaximum` 原来取到的 `.chip` 区域在 M5 上是 PMU 温度，修正后只看核心。第一轮交接里“空闲时曲线可能给出更低转速”的说法是错的，已删除。
7. **历史口径**：M5 上升级前的 “CPU” 行历史（`.chip` 区域）是 PMU 温度，升级后是核心温度，图上会有一处跳变。
8. **非 M5 机型的芯片温度后备键**：SMC 后备列表里的 `TPD*/TRD*/TUD*`（电源管理芯片）和 `TCHP`（充电电路）在没有 M5 拓扑、也没有 `TCMz/TCMb` 的机型上仍可能被当作芯片温度；本批未改（未在 M1–M4 实测），建议后续。
9. **“更新中”的频率**：2 s 采样对 2.1 s 批量，约每 40 s 有一次窗口没有新计数，芯片相关行会显示一次“更新中”（按 D57 规则）。请实机确认观感是否可接受。
10. **主线程阻塞**：见第 7 节，需空闲时 Release 复测。
11. **台式机**：总览 “AC” 环仍是协商功率（调研第十节建议改用实测，D57 未要求）；台式机电源页“功耗”卡按键存在与否显示，未在台式机实测。
12. **既有 live 测试跳过**：见第 6 节。
13. **缺 CPU 时的芯片合计行**：按 D57 补充不显示合计；为了让“本机不支持”里的 CPU 和其余部件仍看得到，该行保留、值写“本机不支持”（JEV 0.74，见第 13.5 节）。若主会话要整行隐藏，只需把 `GeekPowerReadouts.chipRow` 的条件改回“有合计才出行”。
14. **电池温度后备链偏离 D57**：D57 写“`TB0T`／`B0AT`（HID 电量计后备）”，本批实际为 `TB0T` → `B0AT` → AppleSmartBattery `Temperature`，没有接 HID 电量计（`gas gauge battery`）。理由：电池悬停的温度来自 `NativeBatteryElectricalService` 的电池采样，这条路径原来就以 AppleSmartBattery 为来源、不走 HID；HID 电量计目前只喂传感器页的“电池”温度区域；本机 `TB0T` 存在，后备链走不到第三级。是否在 `TB0T`、`B0AT` 都缺时改用 HID 电量计，请主会话决定（实现很小：复用传感器页已读的 `.battery` 区域值）。
15. **能耗积分口径**：见第 13.2 节；长时间与旧口径（控制器每分钟 V×I）的对照没做。
16. **测试改写真实数据（N26）**：本批测试不写；复核轮的相关集合用 `--skip` 去掉了三处会建默认 `ScanStore()` 的既有测试，那三处仍待测试卫生第二批处理。
17. **“整机”是否含充电功率（增量复核 P2-3，与复核结论不同）**：复核按一个样本（`PSTR` 60.55 W、`B0AP` +12.72 W）判断 `PSTR` 含给电池充电的部分；本批两次只读连续采样的回归是 `PSTR ≈ PDTR − B0AP`，即**不含**。说明按实测写，请主会话核对（第 14.3 节）；用电池时“全部由电池供电”是物理事实，用电池时的数值关系没有实测（不允许拔电源）。

实机核对清单（安装测试版后，用 LCU）：电源页五行数值与 iStat 的整机、背光功率对照；电池行（`B0AP`）的数值与正负、三级“方向”和“电池轨（SMC）”与 iStat 的差别；芯片合计三级各项与 `PZC0` 校验、核心簇缩进；电池悬停电芯电压、电池温度、USB-C 端口；接电／拔电时“电源输入”行出现与消失、电池行方向；传感器页 CPU 行与一级圆环一致、三级最高／平均（N 个传感器）；充电电路、掌托、雷雳（推断说明）、光照；硬件探头里的电源管理芯片；电源历史三级实测输入与协商功率、零值无“+”；关闭再打开电源页、睡眠唤醒后芯片合计先“更新中”再出值。

## 12. 没有做的事

没有安装或复制到 `/Applications`，没有启动或退出已安装的测试版、正式版、iStat、Stats；截图与审计只运行 scratch 里自建的 Debug 包副本（隔离身份），每次结束即退出，并在其他批次的隔离 QA 运行结束后才开始。没有用 `sudo`、`powermetrics`，没有安装工具或运行第三方二进制。本批在 scratch 的 `probe/` 自写并运行了 4 个只读小程序（IOReport 采样成本、样本字典键、元素更新时间戳、符号是否存在），只调用 copy／subscribe／sample／读值函数。没有写风扇、充电、电源、亮度；SMC 只用读选择子。没有 push。没有读钥匙串、凭证、`.env`。夹具与交接里没有序列号等私人信息；live 截图裁掉了应用名单。复核轮的测试没有写真实偏好、缓存与 Application Support 数据（第 6 节记录了修改时间）。

## 13. 复核修复（第二轮，“修后可合并”的必修 P1、2、3 与建议 4–9）

复核结论“修后可合并”，硬件安全无问题。按主会话在 D57 里的补充（集成分支 `bd26cd2`）在同一 worktree 修复：先 `git merge integration/2.0.0-beta`（`45b13a8`），完成后按主会话通知再合入测试卫生批（`cb20ca5`，集成分支 `4fea34d`，含 `6e77b6e`）。

### 13.1 提交

| 提交 | 复核项 | 内容 |
|---|---|---|
| `79dd8f3` | P1、8 | Energy Model 通道按“以 `CPU Energy` 结尾”判 CPU，其余通道先去掉 `DIE_<n>_`（或 `DIE_<n> `）前缀再分类，两个芯片的同类通道相加；没有 CPU 部分时 `total = nil`，`unsupportedComponents` 以 `.cpu` 开头；芯片三级里各核心簇缩进在 CPU 行下（CPU 已含各簇，说明里写明） |
| `949ef61` | 2 | 只加测试：背光核对 +19%／−19% 显示，+21%／−21% 判“读数无效” |
| `1e56827` | 3 | “电池”行统一为 `B0AP`、以 `B0AC` 的方向定正负（`SMCBatteryTelemetry.rowPowerWatts`），卡片、电池电气快照（电源历史与其三级、能耗积分都从这里取）同一口径；`PPBR` 只在电池行三级作“电池轨（SMC）”参考，单独不再成行；说明改为“正负号与方向依据电池电流（B0AC）”，三级“方向”写“充电中／放电中／电流约为 0”；能耗积分来源标签改为 `smc-battery-power-b0ap`／`battery-controller-voltage-current`，旧会话里的 `native-battery-voltage-current` 仍正确显示 |
| `3b481bd` | 4 | `SoCPowerEstimator.maximumSampleGap = 10 s`：两次采样相隔超过 10 s（离开电源页时暂停没及时到、或系统睡眠）就重新取基线，旧值标“更新中”沿用到下一个完整窗口；间隔按 `mach_continuous_time` 计（睡眠时 `mach_absolute_time` 不走） |
| `e90a970` | 5 | USB-C 对外供电：缺 `Watts` 的端口只跳过；所有端口都缺时为“本机不支持”（不当成 0）；`Watts` 不是数字或超范围仍判“读数无效” |
| `85ccd97` | 6 | 历史兼容：`chargingCircuit` 写在新键 `addedTemperatureReadings`，旧版本忽略该键、整份历史照常读出；本版本读两个键，遇到不认识的区域跳过而不是整份失败；其他字段与原来逐字段相同，没有新区域时文件不多出键 |
| `45adb12` | 7 | `HardwareReadingText.signed(_:decimals:unit:)`：四舍五入为 0 的值不带符号；电源历史三级、简洁电源面板、历史提示统一使用；原先锁定“当前 +0.00 W · 空闲”的测试改为“当前 0.00 W · 空闲” |
| `decfb7b` | 9 | CPU 行三级“平均（N 个核心）”改为“平均（N 个传感器）”（M1–M4 是每簇几个探头，不是每核一个），数值不变 |
| `6244f9e` | 截图 | 仅调试截图场景：`menu.power.batteryRowDetail`、`menu.power.chipBreakdownUltra`、`menu.power.chipWithoutCPU`；演示芯片通道移到 `MiniWindowDemoData.powerChannelWatts`（数值不变） |
| `f3bb93f` | 自查 | 上一提交新加的演示数据测试读 `MiniWindowDemoData`（只在 Debug／Beta 编译），使性能脚本的 Release 测试编译失败（`logs/review-perf-red-release-build.log`：“cannot find 'MiniWindowDemoData' in scope”）；改为与其他演示数据测试一样放在 `#if DEBUG \|\| STORAGE_CLEANER_BETA` 里 |
| （本文件） | 交接更正 | 第 3.1、5、7、11 节更正与本节 |

### 13.2 口径变化（需主会话知悉）

- **电池功率历史与电池侧能耗积分改用 `B0AP` 瞬时值。** 有 SMC 电池键（`B0AV`、`B0AC`、`B0AP`）的 Mac 上，`NativeBatteryElectricalSnapshot.powerWatts` 是 `B0AP`（SMC 约每秒更新的 V×I），正负按 `B0AC`：电源历史（可见时 2 s、后台 30 s 一个点）与其三级、用电池时的能耗积分（`SystemEnergyAccumulator` 每 30 s 取一次绝对值做梯形积分）都用它。D57 之前用的是电池控制器约每分钟更新一次的 `Voltage × Amperage`。瞬时值反应快，但 30 s 一取对突发负载有抽样误差；长时间平均应一致，未做长时对照。没有 SMC 电池键的 Mac 仍用电池控制器的 V×I，来源标签为 `battery-controller-voltage-current`、界面写“电池电压与电流实测”；SMC 来源界面写“电池功率实测（SMC，约每秒更新）”。
- **电池行数值**：改前卡片是 `PPBR` 的大小配 `B0AP` 的方向（调研夹具 −11.43 W），三级与历史是 `B0AP`（同一时刻 −10.75 W），两处不一致；现在三处都是 `B0AP`。复核轮本机只读测试时系统正在充电：`B0AP` +19.563 W、`B0AC` +1.520 A，同一时刻 `PPBR` 只有 +2.387 W——`PPBR` 不是电池充放电功率，只在三级参考。演示数据把 `PPBR` 设为 `B0AP` 的 1.06 倍（按调研夹具那一刻的比例），只为让三级两个数不同。
- **接电时的分钟负载核对**（N16-5）仍用电池控制器同节奏的 V×I，不受上面影响。

### 13.3 定向测试与反证

见第 6 节（复核轮命令与数量）和下表。红与反证用 `tools/mutations_review.py`，在 `git archive HEAD` 导出的副本 `mutsrc/` 上逐个做唯一文本替换、编译、跑定向测试、按字节恢复（编译缓存 `mutscratch/`，不碰 worktree）；日志 `logs/mutations-review/`。

| 复核项 | 红（改前行为） | 反证 | 绿 |
|---|---|---|---|
| P1 Ultra 通道名 | `red-ultra-names` 旧分类器（要求空格、不认前缀）：3 个测试失败 | `rev-die-prefix` 不去前缀：2 个失败 | 通过 |
| P1 缺 CPU 不显示合计 | `red-total-without-cpu` 其余部件相加当合计：2 个失败 | `rev-cpu-unsupported` CPU 不列入“本机不支持”：2 个失败 | 通过 |
| 8 核心簇层级 | `red-cluster-indent` 与 CPU 同层：2 个失败 | `rev-cluster-indent-view` 视图不缩进：1 个失败（源码断言） | 通过 |
| 2 背光 ±20% 边界 | `red-backlight-50` 容差 50%（复核员的改法）：1 个失败 | `rev-backlight-10` 容差 10%：2 个失败 | 通过 |
| 3 电池行 | `red-battery-row-ppbr` 卡片仍读 `PPBR`：2 个失败；`red-battery-note` 说明恢复“正值为充电”：1 个失败；`red-energy-label` 积分标签仍为 voltage-current：1 个失败 | `rev-battery-direction` 用 `B0AP` 自带符号、不按 `B0AC`：2 个失败；`rev-snapshot-power` 历史／积分快照用原始 `B0AP`：1 个失败 | 通过 |
| 4 最长采样间隔 | `red-sample-gap` 不设上限：2 个失败 | `rev-gap-60` 上限 60 s：1 个失败；`rev-continuous-clock` 采样器传计数自己的时钟（睡眠时不走）：1 个失败（源码断言） | 通过 |
| 5 USB-C 缺值端口 | `red-usb-all-or-nothing` 缺一个端口整组无效：1 个失败 | `rev-usb-none-is-zero` 全缺当成 0：1 个失败 | 通过 |
| 6 历史兼容 | `red-history-one-key` 所有区域仍写原键（旧版本读不出）：1 个失败 | `rev-history-drop-added` 不读新键：2 个失败；`rev-history-strict-zone` 不认识的区域整份失败：1 个失败 | 通过 |
| 7 零值正号 | `red-zero-sign-detail` 三级恢复 `%+`：1 个失败（源码断言） | `rev-zero-sign-helper` `signed()` 保留零的符号：3 个失败 | 通过 |
| 9 平均按传感器计 | `red-cpu-average-cores` 恢复“个核心”：2 个失败 | — | 通过 |

共 24 次突变（12 次红、12 次反证），全部 exit 1 且失败的正是对应测试；每次按字节恢复，第二批结束后逐个被改文件与 `6244f9e` 比对一致（第一批用的副本之后已重新导出）（`logs/mutations-review/run-p1.log`、`run-items.log`、`summary-items.json`）。“源码断言”的三处（视图缩进、连续时钟、三级格式）是读源码文本的契约测试，不是运行行为测试。

### 13.4 截图（改前 `14f3c0a`＋场景叠加补丁，改后 `6244f9e`）

并排图在 `~/Developer/.sc-build/r2-mini-sensors/shots/pairs/`，14 张（左改前、右改后；夜间纯黑／日间石墨各一）：

| 内容 | 夜间纯黑 | 日间石墨 |
|---|---|---|
| 芯片合计三级：核心簇缩进在 CPU 下（复核 8） | `review-menu-power-chipBreakdown-dark.png` | `…-light.png` |
| 芯片合计三级：Ultra 通道名（P1；改前合计 0.88 W 只有 GPU、其余都进了“本机不支持”，改后 20.49 W，含 CPU 13.33 W） | `review-menu-power-chipBreakdownUltra-dark.png` | `…-light.png` |
| 没有 CPU 通道（P1；改前把其余部件相加当合计 5.47 W，改后值为“本机不支持”、三级“本机不支持 CPU”） | `review-menu-power-chipWithoutCPU-dark.png` | `…-light.png` |
| 电池行三级·放电（复核 3；来源 `SMC B0AP`、方向“放电中”、电池轨（SMC），说明不再写“正值为充电”） | `review-menu-power-batteryRowDetail-battery-dark.png` | `…-light.png` |
| 电池行三级·充电（复核 3；+28.00 W、“充电中”） | `review-menu-power-batteryRowDetail-charging-dark.png` | `…-light.png` |
| 电源历史三级·零值（复核 7；“+0.000 A／+0.00 W／当前 +0.00 W” → 不带“+”） | `review-menu-power-liveElectricalReadings-dark.png` | `…-light.png` |
| CPU 行三级（复核 9；“平均（6 个核心）” → “平均（6 个传感器）”） | `review-menu-sensor-cpuRowDetail-dark.png` | `…-light.png` |

- 原图 `shots/review-{before,after}-{dark,light}/`；改前包 `dist-review-before/`（`14f3c0a` 加只含新场景的叠加补丁 `before-overlay/review-14f3c0a-debug-scenarios.patch`，dirty=true），改后包 `dist-after/`（`6244f9e`，dirty=false）。
- Ultra 与“没有 CPU 通道”两个场景只替换三级内容，旁边的二级功耗卡仍是普通演示数据（芯片合计 18.80 W）。
- 改前包在夜间外观下“电源历史三级”“CPU 行三级”两个场景各试了 2–3 次都没拍到（日间同包能拍到，原因未查明），这两张夜间改前图改用第一轮 `14f3c0a` 无叠加包拍的同场景图（`shots/after-mini-dark/`，产品代码相同）。其他场景偶尔没拍到、补拍即成功；当时观察到其他批次的隔离 QA 应用（同一身份）在运行，推测是并发启动冲突，未证实。脚本已改为每个场景前都等其他隔离运行结束，并用更长等待补拍。

### 13.5 JEV

- `jev_decide`（jev-latest）：缺 CPU 时芯片合计行怎么呈现。候选：保留该行、值写“本机不支持”、三级列出能读到的部件并把 CPU 列入“本机不支持”（本批做法）／整行隐藏／值写“—”／改名“芯片各部件”。结果选“保留该行、值写本机不支持”，概率 0.74（整行隐藏 0.16），confidence 0.70；整行隐藏被判为不满足“CPU 可见且其余部件仍可查看”，“—”与改名被判为与现有无值用语冲突。**不视为批准**；第一次调用返回 HTTP 520（服务端错误），隔一段时间重试一次得到上述结果。

## 14. 增量复核补修（第三轮：P2-1、P2-2、P2-3 与演示 `PPBR`）

增量复核结论“可以合并”，本批已合入集成分支 `454b493`。复核另留 3 个 P2 和一项顺手改，在同一分支补修：先 `git merge integration/2.0.0-beta`（快进到 `454b493`）。

### 14.1 提交

| 提交 | 项 | 内容 |
|---|---|---|
| `902ce18` | P2-1 | 只加测试：① 21 个字段全部填上互不相同的值（`Mirror` 核对字段数和非空），新版写、新版读，逐字段比较，文件的键正好是 21 个字段加 `addedTemperatureReadings`；② 改前结构（`d490207` 的同 21 个字段、合成的严格 `Codable`、区域到 `wifi` 为止）读新文件，除充电电路外逐字段相等，再由它写回、新版读回，其他都不丢 |
| `f6f4136` | P2-2 | 有 `B0AV`／`B0AC` 而没有 `B0AP` 时，卡片、三级、历史、能耗积分统一用 `B0AV × B0AC`（正负即 `B0AC` 的；任一无效即无效）；三级来源写“电压 × 电流（SMC）”；积分标签 `smc-battery-voltage-current`；旧标签照常显示 |
| `dd1658b` | P2-3 | “整机”三级说明按供电方式写，依据本机实测（第 14.3 节，**与复核的判断相反**） |
| `e623ac0` | 顺手改 | 演示 `PPBR` 按实测比例（只影响 Debug／Beta 演示）；新增“整机”三级的调试截图场景 `menu.power.systemDetail` |
| （本文件） | 交接 | 本节，以及结论表、第 2.1 节表、第 11 节第 17 条 |

### 14.2 P2-2：缺 `B0AP` 时的口径

- `SMCBatteryTelemetry.rowPowerBasis`：有 `B0AP` 用 `B0AP`；否则 `B0AV`、`B0AC` 都有就用两者相乘；都没有则无电池行。`rowPowerWatts` 跟着它算，卡片、三级、电源历史和能耗积分取同一个值。
- 电池电气快照新增 `powerBasis`：`smcPowerKey`／`smcVoltageTimesCurrent`／`batteryController`（只在没有 SMC 电池键时）／nil（没有功率读数）。积分来源标签按它取：

| 来源 | 积分标签 | 能耗页“当前功率”说明 |
|---|---|---|
| SMC `B0AP`（按 `B0AC` 定正负） | `smc-battery-power-b0ap` | 电池功率实测（SMC，约每秒更新） |
| SMC `B0AV × B0AC`（本次新增） | `smc-battery-voltage-current` | 电池电压 × 电流实测（SMC，约每秒更新） |
| 电池控制器 V×I | `battery-controller-voltage-current` | 电池电压与电流实测 |
| D57 之前保存的会话 | `native-battery-voltage-current` | 电池电压与电流实测（不变） |

- 顺带的变化：有 `B0AP` 但缺 `B0AV` 或 `B0AC` 的情况，历史原来用 V×I（可能混用 SMC 与电池控制器的读数），现在与卡片一样用 `B0AP`；只有一个 SMC 电池键、又没有 `B0AP` 时，回退为纯电池控制器 V×I，不再混用两个来源。这几种组合都只在夹具里出现，本机三个键都有。

### 14.3 P2-3：“整机”说明与实测（请主会话核对）

- 复核的依据：充电时一个样本 `PSTR` 60.55 W、`B0AP` +12.72 W，判断 `PSTR` 含给电池充电的功率，要求接电源时写“含给电池充电的部分”。
- 本批的核对：scratch 里写了一个只读测试（未提交，源码留在 `probe/p2-3-ZZPowerBalanceProbeTests.swift.txt`），每 0.2 s 用 SMC 读选择子读 `PSTR`、`PDTR`、`B0AP`、`PPBR`、`B0AC`。接电源（65 W 适配器）跑了两次：90 s（438 个样本）和 150 s（732 个样本），期间 `B0AP` 在 −13.9…+12.1 W 之间变化，既有充电也有电池补电。原始数据 `logs/p2-3-probe-run{1,2}.log`，分析 `logs/p2-3-analysis.log`。
- 结果：按 10 s 均值做最小二乘，两次分别为 `PSTR = 0.991 × PDTR − 1.005 × B0AP + 0.37 W`、`PSTR = 1.001 × PDTR − 0.955 × B0AP − 0.40 W`；5 s 均值为 −0.98／−0.83。按“不含充电”算的余量（`PDTR − B0AP − PSTR`）均值 +0.14／+0.32 W、标准差约 2.2 W；按“含充电”算的余量（`PDTR − PSTR`）会跟着充电功率变，标准差 5–6 W。
- 结论：`PSTR ≈ PDTR − B0AP`。`PSTR` 是整机耗电，**不含**给电池充电的部分；电池补电时，它包含电池放出的功率。单个样本可以差 10–20 W：各键更新时刻不同，负载起伏时尤其明显。按 65 W 适配器算，`PSTR` 60.55 W 再加 12.72 W 充电已超过输入上限，复核看到的那个样本很可能就是这种时刻错位。演示数据原来就是这样建模的：电源输入 = 整机 + 充电 + 0.3 W。
- 说明文字（中英文）：
  - 接电源（有电池）：“整机耗电功率，约每秒更新；接电源时不含给电池充电的部分：约等于电源输入减去充电功率，电池补电时约等于电源输入加上电池放电”。
  - 用电池：“整机耗电功率，约每秒更新；用电池时全部由电池供电”。这是物理事实；用电池时 `PSTR` 与 `B0AP` 的数值关系没有实测（不允许拔电源），所以不写数值。
  - 台式机或供电来源未知：只留第一句。
- 若主会话决定仍写“含充电”，改 `GeekPowerReadouts.systemNote` 一处，测试 `testComputerRowNoteSaysWhatPSTRIncludes` 同步改；反证 `rev-p2-3-includes` 就是这种改法，会被该测试拦下。

### 14.4 演示 `PPBR`

- 改前演示把 `PPBR` 设为 `B0AP` 绝对值的 1.06 倍：充电 28 W 时三级显示“电池轨（SMC）29.68 W”，与实机不符。
- 实测（同两次采样，按 5 s 均值）：
  - 充电的 26 个窗口：`PPBR` 中位数 1.43 W（0.61–2.80 W），几乎不随充电功率变化，与充电功率的比值在 0.05–1.19 之间。
  - 接电补电的 17 个窗口：`PPBR / |B0AP|` 中位数 1.59（1.03–2.76）。
- 演示改为：充电时 1.43 W，放电时 1.59 × |B0AP|，为 0 时 0（`MiniWindowDemoData.batteryRailWatts`）。

### 14.5 测试命令、结果与反证

`tools/review-tests.sh inc`（先跑守卫类，同一编译缓存，前后记录真实数据文件的修改时间）：

| 运行（`e623ac0`，2026-10-07 21:04–21:06） | exit | 结果 | 日志 |
|---|---|---|---|
| 守卫类 `TestPreferenceHygieneTests` | 0 | 6 项，0 失败 | `logs/review-tests-inc-guard.log` |
| 定向（17 个类） | 0 | 289 项（复核轮 284 项＋本轮 5 项），0 失败，1 项既有硬件条件跳过 | `logs/review-tests-inc-targeted.log` |
| 相关集合 | 0 | 1184 项，0 失败，3 项既有条件跳过 | `logs/review-tests-inc-related.log` |
| 严格并发 `swift build … --build-tests -Xswiftc -strict-concurrency=complete` | 0 | 0 错误；只有既有的 `BrowserPrivacyRecoveryTests.swift:467` 警告 | `logs/inc-strict.log` |
| `python3 script/check_private_api.py` | 0 | 6 项登记用途，无新增 | `logs/inc-private-api.log` |
| `git diff --check 454b493 HEAD` | 0 | 无输出 | — |

- 真实数据文件运行前后不变：`SystemEnergySession-v1.json` 19:30:24／255 B，`Monitoring/MenuBarPowerHistory.json` 19:58:08／17 366 B，`Monitoring/MetricHistory-v1.json` 10-04 15:17:05。
- 本轮新增 5 个测试：`testSavedHistoryRoundTripsEveryField`、`testAnEarlierBuildReadsEveryFieldOfTheNewFileAndWritesItBack`、`testWithoutB0APTheBatteryPowerIsVoltageTimesCurrentEverywhere`、`testComputerRowNoteSaysWhatPSTRIncludes`、`testDemoBatteryRailFollowsTheMeasuredRatios`。另改了 2 处已有测试：
  - `MiniSensorsNoValueRuleTests.testBatteryRowIsB0APWithTheCurrentsDirectionAndPPBROnlyAReference`：“只有 `PPBR` 不成行”改为把 `B0AP`、`B0AV`、`B0AC` 都去掉（只去掉 `B0AP` 时现在按 P2-2 显示 V×I 行），并加上 V×I 行的值、来源、说明和三级断言；
  - `SystemEnergyACTelemetryTests`：标签与界面文字的核对加上新标签和 `B0AP` 标签。

反证（`tools/mutations_inc.py`，在 `git archive HEAD` 导出的副本上逐个做唯一文本替换、编译、跑测试、按字节恢复）：

| 项 | 突变 | 结果 |
|---|---|---|
| P2-1 编码 | 逐个删掉 21 个字段的编码行，外加 `addedTemperatureReadings`（共 22 次；`enc-fanTargetRPM` 就是复核员的改法，即“红”） | 22 次全部 exit 1。被拦下的测试：`testSavedHistoryRoundTripsEveryField` 22 次；`testAnEarlierBuildReadsEveryFieldOfTheNewFileAndWritesItBack` 21 次（删 `addedTemperatureReadings` 时它不受影响，因为改前结构本来就读不到充电电路）；改前就有的 `testSavedHistoryKeepsTheChargingCircuitWhereEarlierVersionsIgnoreIt` 只拦下 11 次；补测试前，删掉 `memoryPressure`、`memoryPressureLevelCode`、四个内存字节数、`swapUsedBytes`、`gpuTemperature`、`fanRPM`、`fanTargetRPM`、`fanReadings` 这 11 个字段的编码都拦不住 |
| P2-1 解码 | `fanTargetRPM`、`memoryPressureLevelCode` 解码改成 nil（2 次） | 2 次 exit 1：两个新测试都失败 |
| P2-2 | 红：`red-p2-2-row-hidden`（不按 V×I，卡片隐藏行）、`red-p2-2-label`（SMC V×I 仍标为 `B0AP`）；反证：`rev-p2-2-sign`（V×I 不带 `B0AC` 的正负）、`rev-p2-2-source-text`（三级来源仍写 `SMC B0AP`）、`rev-p2-2-snapshot`（历史与积分改用电池控制器 V×I）、`rev-p2-2-detail-text`（新标签没有界面文字） | 6 次全部 exit 1。最后一次拦下它的是能耗页已有的 `testAnEmptySessionIsNotShownAsAMeasuredZero`（新标签落到默认的“应用进程归属估算”） |
| P2-3 | 红：`red-p2-3-old-note`（恢复原说明）；反证：`rev-p2-3-includes`（改成复核建议的“含给电池充电的部分”）、`rev-p2-3-desktop`（台式机也写电池）、`rev-p2-3-battery`（用电池时不写电池供电） | 4 次全部 exit 1，`testComputerRowNoteSaysWhatPSTRIncludes` |
| 演示 `PPBR` | `red-demo-ppbr`（恢复 1.06 × \|B0AP\|） | exit 1，`testDemoBatteryRailFollowsTheMeasuredRatios` |

共 35 次（含 5 次红），全部被拦下。每次结束后按字节恢复，最后逐个被改文件与 `e623ac0` 比对一致。汇总在 `logs/mutations-inc/summary-all.json`，第一遍与重跑的日志分别是 `first-pass.json`、`run2.log`。

### 14.6 截图

并排图 8 张，在 `~/Developer/.sc-build/r2-mini-sensors/shots/pairs/inc-*.png`：左为改前（`454b493` 加只含新场景的叠加补丁 `before-overlay/inc-454b493-system-detail-scenario.patch`），右为改后（`e623ac0`）；夜间纯黑、日间石墨各一。

| 内容 | 文件 |
|---|---|
| “整机”三级·充电中（P2-3：说明写明不含给电池充电的部分） | `inc-menu-power-systemDetail-charging-{dark,light}.png` |
| “整机”三级·用电池（P2-3：用电池时全部由电池供电） | `inc-menu-power-systemDetail-battery-{dark,light}.png` |
| 电池行三级·充电中（演示 `PPBR`：29.68 W → 1.43 W） | `inc-menu-power-batteryRowDetail-charging-{dark,light}.png` |
| 电池行三级·放电（演示 `PPBR`：6.67 W → 10.00 W） | `inc-menu-power-batteryRowDetail-battery-{dark,light}.png` |

- 原图 `shots/inc-{before,after}-{dark,light}/`。P2-2 的“电压 × 电流（SMC）”只在没有 `B0AP` 的机型出现，本机和演示数据都有 `B0AP`，没有截图，由测试覆盖。

### 14.7 清理（RULES 第 3 条，集成分支 `f74c912`）

- 已删：
  - 截图用的 `.app` 副本：`dist-before`、`dist-review-before`、`dist-after`；
  - 截图包编译缓存 `/tmp/storage-cleaner-r2ms-{before,review-before,after}`；
  - `commitcheck`（含 `scratch`、`src`）、`verify`（含 `release`）、`strict`；
  - 改前源码克隆 `before-src`、`review-before-src`；
  - 反证结束后再删 `mutscratch`、`mutsrc`、`mutation-backup`。
- 保留：正在用的 `debug`；`logs/`、`shots/`、`perf/`、`probe/`（只读探测源码与结果）、`before-overlay/`（叠加补丁）、`tools/`。
- 过程中的一个失误：`mutscratch` 是从 `commitcheck/scratch` 克隆来的，它的 `workspace-state.json` 仍指向 `commitcheck/scratch/artifacts` 下的 Sparkle 库。我在反证跑到一半时按清理规则删了 `commitcheck`，之后 15 次突变编译失败（`build-failed`，不算结果）。处理：把该文件里的路径改到 `mutscratch` 自己的 `artifacts`（原文件存为 `logs/mutscratch-workspace-state.before-fix.json`），重新导出副本，重跑这 15 次和尚未跑的 4 次。第一遍的有效结果在 `logs/mutations-inc/first-pass.json`，重跑在 `run2.log`。
