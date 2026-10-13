# r2-bench-v11 / B1 交接

日期：2026-10-10。分支 `task/r2-bench-v11`，基线 `3e5eead099fb60487a47dc54647b6524d1979bc2`，worktree `/Users/developer/Developer/sc-worktrees/r2-bench-v11`，scratch `/Users/developer/Developer/.sc-build/r2-bench-v11`。本轮按D72只写文档和JSON，未改Swift、Package.swift、打包脚本、BOARD、DECISIONS或旧断言。

## 1. 实际交付

| 文件 | 内容与理由 |
|---|---|
| `docs/2.0.0/BENCHMARK-V11-SPEC.md` | 冻结v10 Core18夹具/算法/哈希；新能效/持续/压力时间轴、功率对齐、CV/取消/热/预算；D72几何评分、标签、参考/重算、兼容结果模型；全部运行ID中文映射；UI和打包契约 |
| `Resources/Benchmark/AppleSiliconCatalog.json` | 20个型号、39个CPU/GPU SKU；每个非null叶字段有官方URL，null附unverified原因；带宽/内存按SKU与机型限制读取，保留super/performance/efficiency核型及部分型号的未知字段 |
| `docs/2.0.0/apple-silicon-catalog-sources.md` | 逐型号入口、字段来源规则、精确节点/能力等缺项、官网冲突与来源纠错、资源hash；供主会话逐字段核对 |
| 本交接 | 验证边界、B2–B4输入、主会话需做的检查和prepared使用方法 |

读取输入包括两份批次prompt、RULES、D5/D48/D55/D60/D72、计划、BOARD（当前没有r2-bench-v11专门行）；MSeries协议/runner/scoring/CPU扩展与实际CPU/GPU/存储内核；加速器服务/适配器、3D/光追/MPS/视频内核；SoCPowerTelemetry、CPUPerformanceStateService、PowermetricsSample、应用侧HelperPowerMetricsMonitor；benchmarks README；三态HTML及真正提供内容的shared.js；Package.swift/现有资源复制流程。没有把旧效果图演示数值或v6基线当作v11参考。

## 2. 初稿轮验证与明确未运行项（历史；当前状态见第7节）

| 状态 | 命令 / 证据 | 结论 |
|---|---|---|
| PASS | `git status --short --branch`、`git rev-parse HEAD`（exit0） | 开始时干净；正确分支和基线；最后只新增4个目标文件 |
| PASS | 网页search/open，来源见JSON指针与来源审计 | 已起草逐字段官方来源；最终人工逐字段复核仍属于主会话，不代表生产已启用 |
| PASS | `python3 <scratch>/validate-b1.py`（exit0），`evidence/static-validation.json` | JSON结构、18型号覆盖、源pointer/合规域名、每个null原因、CPU总数/配对、全部ID映射、Core契约hash、D72权重、固定写入预算和文档空白检查 |
| PASS（仅夹具） | 用户提供的brand/Metal/tier/GPU/memory tuple静态匹配 | 唯一m5-pro、18CPU/20GPU；不是完整实机回读 |
| PASS（仅GPU） | `system_profiler SPDisplaysDataType -json`（exit0） | Apple M5 Pro；`sppci_cores="20"`；证据 `evidence/hardware-identification.json` |
| BLOCKED | 12条逐项 `sysctl -n`（各exit1） | `Operation not permitted`；未读到brand/hw.model/perflevels/memsize；不绕过沙箱 |
| NOT RUN | Metal API探针 | 未编译探针/启动app；profiler名称不充当已验证MTLDevice.name |
| BLOCKED | `mcp__jev__jev_decide` | 工具返回 `MCP tool call requires approval, but approval policy is never`；没有JEV供应商判断，不能声称已复核 |
| NOT RUN | Swift build、Swift/XCTest、`script/verify.sh`、Release校准、压力 | B1文档/数据，不运行高负载；无需在本批为了JSON改Swift或新增形式化测试 |
| NOT RUN | 安装、git commit、合并、上传、发布 | .git按本会话权限只读；提交由主会话在验证后执行 |

prepared/static-checks.json在最后生成，包含实际静态检查和补丁预检状态。静态来源校验只证明URL域名/指针完整，不能证明每个页面的字段内容正确；来源核对记录与结构检查不能混为一项“规格已入库”。

## 3. 主会话必须复核的具体事项

1. **每个规格叶字段**：按sources pointer逐一打开URL，检查值属于正确型号/CPU bin/GPU bin、单位与更新日期。优先M5核型、Max低/高带宽、NE TOPS、媒体引擎数、各Mac散热和内存历史上限。null只在取得直接官方证据后填值；不要用同代/Ultra倍数补。目录是草案，reviewStatus未获批。
2. **新型号与历史配置复核**：M5 Ultra本轮以当前Mac Studio技术规格明确的SKU字段更新，36C核型拆分仍未知，其余未核实字段不自动启用；M6保留部分行和原冲突记录。M3 Ultra家族512GB历史公布上限与当前SKU256GB选项分开，不互相覆盖。
3. **评分组内细化已确认**：主会话本轮确认三个CoreGPU与30s3D各1/4；规范升为v11.2并冻结可复算SHA。持续仍使用末30s实际吞吐，无完整依赖不重新分配权重。此项不再待确认。
4. **M1具体配置留在B5**：D72锁8CPU/8GPU=1000，机型/内存/SSD/散热由B5再定，不阻塞B2–B4；B5之前使用本机M5 Pro暂定基准策略。当前无有效冻结v11参考数值仍待校准，不以识别成功或旧v6基线估算。
5. **助手时间戳**：现有sample只有duration，sampledAt为完成时间；不能算能效。B2补实际单调测量区间并按2s请求起点节流，仍共享单条进程。每份通常覆盖1s，不宣称连续2s；缺助手/不真实对齐只保留吞吐。
6. **ANE可行性**：≤2MiB固定模型、合法来源/权重、CPUOnly与cpuAndNeuralEngine输出一致；配置/时延差不是实际ANE执行证明。MLComputePlan可用性/计划分配与真实执行证据分清；验证失败保留待实现，不给假的ANE加速比。
7. **新媒体/Metal family**：ProRes/AV1位流/profile/许可/hash尚需B2冻结，HEVC等新方向不能软件回退；当前光追枚举只apple9/10，不能据此把新芯片判无硬件。完整默认7–8分钟与持续段3分钟、压力600s另计准备/排空要一致。
8. **资源打包**：根Resources/Benchmark现在不会自动进app；B2/B3改复制流程并在实际bundle回读存在、SHA/结构与安全降级。本轮不改Package.swift或脚本。
9. **本机SKU识别已由主会话回读**：品牌M5 Pro、Super6/Performance12、physical18、GPU20、memsize51539607552唯一匹配m5-pro-18c-20g。当前状态PASS（主会话回读＋本轮匹配）；Metal API名称/logicalcpu未提供仍单列未知，不再阻塞已取得证据的SKU识别。本Codex未自行绕过沙箱。

## 4. B2–B4 输入清单

| 阶段 | 直接输入 | 实现/验证重点 |
|---|---|---|
| B2 内核与编排 | 规范§1–5/§8–9，既有Core内核和加速器adapter，PowermetricsSample/Monitor，目录门控字段 | 不改Core fixture/hash；3×10sCPU＋30sGPU、2×90s/5s点、可选300+300s；单调对齐/实际1s区间；取消/超时排空与热中止；媒体/ANE闸门；中文ID和阶段进度 |
| B3 评分/目录/历史 | 规范§6–8/§10/§12，目录和逐字段审计，现有MSeriesScoring与history repo | 单一常量权重/方向；CV5/10%与比值闭区间；受限与不可比；缺参考不出分；版本/hash与幂等历史重算；旧schema decodeIfPresent/原字节保护；目录资源包内回读 |
| B4 UI | 规范§9/§11，approved-20261009的三态HTML/shared.js及光场令牌 | 在既定视觉骨架生成新三态mockup并由用户确认；标准7–8分钟；真实已用时间/分项名；峰值/持续/能效分口径；单位分轴、unknown空值；无排名/百分比/默认上传 |

B5受控采集的输入是最终实现与冻结契约，按benchmarks README两个冷却session各≥4有效run；不要运行现有v6采集命令并改报告名冒充v11。B4会修改Views，届时遵D48运行TestPreferenceHygieneTests与UIConsistencyRegressionTests；B1没有修改Views，不能以未运行这两个Swift类假称界面已验收。

## 5. 主会话命令与红/绿/反证

本B1无改写旧断言。以下静态脚本在scratch，只有读取源码/JSON、写检查报告，不改git索引或运行负载：

```bash
python3 /Users/developer/Developer/.sc-build/r2-bench-v11/validate-b1.py
python3 /Users/developer/Developer/.sc-build/r2-bench-v11/prepared/commit-prepared.py --check-only
```

静态绿：完整JSON/来源pointer、SKU矩阵、所有必需ID、Core和scoring契约hash、主会话本机回读唯一匹配通过。红/反证建议在scratch副本上操作（不要改已验证交付）：删除必需型号/叶source、填未核实process、改变CPU总数或伪造18/40 M5Pro配对，应被结构校验拒绝；把Core契约改一字节应失配；变brand/Metal为互相冲突时识别不得唯一；更改交付文件/补丁一个字节，提交脚本须先拒绝hash。确认取消、超时、热保护、曲线对齐、旧历史迁移和幂等重算是B2/B3实现后的行为反证，B1没有可执行Swift实现，不能宣称这些反证已运行。

B2/B3定向类名由实现者以实际存在的测试类列出；本轮未虚构不存在的v11类或给现有v6校准harness传新协议。集成门禁由主会话跑（私有verify root）：

```bash
DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer \
STORAGE_CLEANER_VERIFY_BUNDLE=0 STORAGE_CLEANER_UI_SMOKE=0 \
STORAGE_CLEANER_VERIFY_ROOT=/Users/developer/Developer/.sc-build/r2-bench-v11/verify-main \
script/verify.sh
```

此命令不表示本B1已构建/测试，也不安装；B2–B4合并后的实际bundle、UI/设备验证各自记录结果。

## 6. prepared 分组与提交

scratch `prepared/`：`01-spec.patch`（规范）、`02-catalog.patch`（目录＋来源文档）、`03-handoff.patch`（本交接），各配message，另有 `all.patch`、`manifest.json`（基线/分支/顺序/全部最终文件与补丁SHA）、`static-checks.json`、`commit-prepared.py`、README。补丁含新增文件，不能用普通git diff漏掉untracked JSON/文档。

先按主会话流程完成人工来源与协议复核、必要验证；源码和补丁hash未改变时才执行：

```bash
python3 /Users/developer/Developer/.sc-build/r2-bench-v11/prepared/commit-prepared.py --validated
```

脚本明确要求--validated、正确repo/分支/精确基线、空暂存区、最终文件hash及全部prepared产物hash；按组三次apply-to-index/commit。它不替代构建/实机/来源核对，不安装/合并/push。若主会话修改目录/规范或基线变化，旧prepared即失效，须重新生成、核对，不能绕过hash或删掉保护。

## 7. 主会话评审修订 r2（2026-10-10）

### 实际修改

1. 规格目录升schema v2，39个CPU/GPU SKU取代configurationPairs/memoryBandwidthOptions。逐芯片网页查询官方技术规格，全部Pro/Max/Ultra和M5已查；带宽/内存上限进入SKU，M3/M4/M5 Max低高配不再共享最大值。缺明确SKU带宽仍null，并在需要时保留有说明的芯片单值；不可继承为当前SKU。M4 Pro/M5 Pro的MacBook Pro与Mac mini上限差异保存memoryLimitsByMac。
2. 规范§6.2写入主会话已确认的GPU峰值四项各1/4；scoringVersion升mseries-d72-geomean-v11.2，精确canonical JSON与SHA写在规范并验证。Core18算法/契约hash不变，没有改Swift。
3. §7删除固定M1 Mac mini/16GB/512GB及B5前确认阻塞，改为B5待办；B5之前本机M5 Pro作为暂定基准策略，有效参考数值未采到时仍待校准。
4. §10按品牌＋命名CPU物理层级＋GPU核数识别具体SKU；已采用用户转交的主会话沙箱外回读，唯一m5-pro-18c-20g。Metal/logicalcpu缺值保留但不阻塞；旧沙箱查询失败记录归档而不抹掉。
5. 来源审计改为逐SKU表、逐芯片检索表、芯片单值保留表与遗留；M5 Ultra采用当前官方规格可确认的SKU字段，36C类型分拆未知不猜。旧r1四个文件、prepared、证据已完整保存scratch/revisions/b1-r1。

### 本轮验证口径

静态结构、来源pointer、SKU配置与带宽/内存差异、fallback不继承、主会话回读匹配、scoring hash、空白、补丁应用和SHA的实际结果见更新prepared/static-checks.json。GPU已确认、M1选择延期和本机PASS分别按主会话明确输入记录，不将上一轮pending/BLOCKED当当前结论。没有Swift构建/定向测试、跑分或参考采集；这轮仍只文档/数据。JEV本轮再次调用mcp__jev__jev_review，仍返回审批策略never，未取得供应商判断；证据evidence/jev-review-r2.json，不称其复核通过。

### B2–B4新增输入与反证

- B2使用SKU门控及CPUOption的核型完整性；遇到未知36C拆分不猜，保持原生工作负载可运行。新模型/API名未知不拿其他字段伪填。
- B3按schema v2读skus；SKU缺带宽不能从chip单值补。已知机型用memoryLimitsByMac，家族历史上限不能覆盖SKU。参考/结果manifest记录新的scoringVersion/SHA与catalogVersion/SHA，幂等重算仍保留原始值。
- B4的档案与理论条从当前SKU取值，未核实带宽显示原因；本机Super6/Performance12，不能写12E。GPU细分口径已确认，不再做待确认弹窗；M1具体机型不作为起始页阻塞。
- 本轮静态反证：故意将M3 Max低配带宽设400、M4 Max低配设546、M5 Max低配内存设128、用家族单值填未知SKU，应被复核夹具拒绝；故意改确认权重/契约一字节，SHA检查应拒绝；品牌/CPU/GPU冲突不能匹配SKU。实际运行的静态反证/提交守卫结果记录在prepared；硬件行为反证留给B2/B3实现后，不称已运行。

prepared仍按01-spec→02-catalog→03-handoff生成全量基线补丁，主会话复核后使用commit-prepared.py --validated；最终文件/产物SHA已更新，旧prepared不再对当前文件有效但保留归档。未提交、安装、合并、上传或发布。
