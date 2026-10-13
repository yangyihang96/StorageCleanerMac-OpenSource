# r2-hygiene-4 第六轮交接：只优化源码守卫性能

## 交付状态与基线

第六轮最终源码已写入本 worktree，补丁在 `~/Developer/.sc-build/r2-hygiene-4/prepared-r6/`。补丁基线是已提交第五轮的 **dd23535b014e3914042e15ab935e7034477e0721**，分支 `task/r2-hygiene-4`。本轮只改两份守卫源码与本文，共三文件、两组；不累计重交第五轮补丁。

已读完 `review/review-2.md`，报告及 `r2-hygiene-4-review/r2/` 的证据哈希保存在 `review-inputs.json`。复核已确认第五轮功能和精度通过：320文件零违规，Hygiene-3 124条、Hygiene-4 182条预期吻合；五个允许写法和B1–B4结果正确，19条只读／逃逸探针的预期正确（其中3允许、16拒绝）。复核的12组交替CPU比值中位数约1.16，高于1.10；a7b7aeb与dd23535的三组CPU比较也未见第五轮收益。主机负载较高，报告不构成空闲机器正式验收。

**本轮没有编译、XCTest、反证执行、性能量测或提交。** `_prompts/common.md` 明确禁止沙箱中构建／测试。`static-checks.json`只记录静态审查、脚本语法、样例与补丁哈希验证；源码反证、34项变异、等价比较、2秒复杂度和耗时验收均为 `NOT RUN`。此前通过的功能结果不能代替本轮验证。`timing-status.json`的中位数、比值和passed均为null。

原第五轮交接（含早期23文件审计和生命周期修正依据）逐字节保存在 `prepared-r6/baseline-handoff.md`；历史prepared目录冻结哈希见 `round-five-inputs.json`。本轮未改真实偏好／文件系统测试注入、清理生命周期、产品源码、ScanStore、任何测试断言或阈值，也未增删两个目录样例。

## 优化与预期收益

复核已有 `sample-head.txt` 指向 isStatementBody 在Debug下占约9.7%（基线2.2%）、unsafeStorageSources约4%、singleton约1%。本轮阅读这份采样并补静态分配分析，没有在沙箱重跑采样。inclusive调用树存在重叠，不能把父子百分比相加；这些比例也不是本轮已经获得的收益。

| 位置 | 改动与预期收益 | 保持语义的依据 |
|---|---|---|
| isStatementBody及字符热循环 | 全部24处数值字符数组contains换成switch；主热点直接switch，消除按字符创建数组和Sequence遍历。 | 原字符集合、游标推进、括号跳过、500单位窗口、缓存和正则完全保留。 |
| argumentLabelLocations | 复用空白switch，不再每次扫描创建四元素Set。 | 保留9、10、13、32四个UInt16值；不扩大空白集合。 |
| unsafeStorageSources | 新增按文件缓存的来源标记预判，缺少全部相关标记时跳过绑定循环及属性赋值正则。至少59/320个原始Swift文件可走此路径。 | 复用旧表达式预筛的全部code/literal标记；来源只能在本文件建立或经绑定继承。`Directory`、`userDomainMask`、`pw_dir`、`defaultURL`、`HOME`、`..`等均保留；不是只看UserDefaults。 |
| mayHaveStorageSource | 标记数组静态共享，code已经命中时不复制literal子串。 | 标记原文、顺序、`direct || hasBinding`和完整别名传播原样。 |
| static/class和shared绑定 | 先查正则命中必须存在的文本，再调用原正则。 | 正则及类型判断不变，只跳过不可能命中的分支。 |
| constructors | 无显式类型名／别名时仅跳过对应正则；无`.init`时跳过标签正则；标签字典静态共享。 | 上下文标签、注解、赋值、返回类型和别名推断仍执行；不能因缺少类型名提前返回整个方法。 |
| func/init前缀 | 使用Foundation反向找最后非空白字符，省掉每个函数复制并trim整个前缀。 | 使用同一whitespacesAndNewlines补集；仍只跳过以点结尾的前缀。 |
| 闭包前缀 | startsValue先短路，其余反向定位160单位窗口内最后分隔符，只复制最后一段。 | 原分隔字符、窗口、startsValue与正则相同，不再创建components数组。 |
| binding查询 | filter改为lazy.filter，保留原max(by:)。 | 原谓词、候选顺序、比较器和并列选择不变；消除中间候选数组。 |
| 类型／函数作用域查询 | 用已建立的openings字典替代线性firstIndex。 | 查询的非根花括号位置唯一且大于0；不新增索引。 |
| 参数默认位置 | 保存初始化时已经计算的Set，在存储分析中复用。 | 后续只移除非声明赋值，参数默认位置集合不变；减少一次全bindings过滤及建Set。 |
| 用户目录后缀 | 把六元素字典放入已有userDomainMask分支。 | 原字典内容、消费循环和判定不变；无该标记的facts不分配字典。 |
| lexicalViews遮罩 | 保留Character扫描；复用一／二UTF16单位空格，宽字素按宽度缓存。 | 每次替换保持UTF16宽度；换行、双视图和原字符流保留；减少String转换和重复空格创建。 |
| lexicalViews前缀 | 注释、转义、闭引号先比较首Character；插值opening每个字符串只拼接一次。 | 首字符是原begins成立的必要条件；原begins、raw hash、递归和转义顺序不变。 |

详细逐项理由见 `optimization-plan.json`，50步源码替换记录见 `optimization-transforms.json`。静态检查从dd23535逐步重放这些替换，与最终两份源码逐字节相等；所有规则raw-string正则的多重集合相等；TestPreferenceHygieneTests中lexicalViews之前的全部规则和断言逐字节不变。`uncachedFacts`内部唯一变化是目录字典移入原消费分支，原来源事实与写入污染传播不变。只读默认参数证明原样保留。

此外检查了仍存在的分配：Character／双输出数组、每参数一次的components、正则完整匹配数组和递归visited集合。本轮保留这些表示与完整结果，避免把性能优化扩成Unicode词法器或数据流模型重写。静态判断不代替Swift编译和运行期等价验证。

若仍以复核1.16作粗略起点，需要削减约 **5.2%的当前总耗时** 才能达到1.10；仅把9.7%热点减半约为4.9%，因此还处理了词法屏蔽、前缀复制和重复分析。此为条件推算，绝非收益承诺。新文件预判也有文本检查成本，最终净收益必须实测。

## 反证与等价验证

两个目录逐字节保留：Hygiene-3 **124条**，Hygiene-4 **182条（107拒绝／75允许）**。外部源码反证仍 **367条（241拒绝／126允许）**，每个惰性源码文件及预期与第五轮完全相同，已生成到 `source-counterproofs-r6-final/`。B1–B4、五个复核误报样例及第五轮只读默认参数样例均未删除、修改或改预期。110类定向清单逐字节不变。惰性probe只供守卫读取文本，禁止编译或执行其业务语句。

运行期共 **34项**：原32项全部保留，31项的全部字段原样保留；`unmasked-statement-prefix`因原数组判断改为switch，仅适配needle到同一括号跳过分支，replacement仍关闭该跳过，原方法、执行数和S1诊断不变。记录见 `runtime-anchor-updates.json`。另加两项预判反证：

| 变异 | 必须得到的实际断言失败 |
|---|---|
| narrow-file-storage-preflight | 把全文件预判错误缩成UserDefaults文本，H4目录的静态defaultURL、Directory API和passwd home三个旧拒绝样例必须失败。 |
| skip-contextual-constructor-preflight | 类型名缺失就错误地返回，H3原`r3-contextual-health-init-rejected`必须失败，证明仍分析computerHealthStore标签的上下文.init。 |

runner仍先对当前构建运行4个未变异方法绿对照，再在各自隔离包中应用变异；独立构建1200秒、测试300秒，超时单报TIMEOUT并非零退出。只有指定方法实际执行且出现指定断言诊断才算变异PASS；构建错误、零测试、崩溃、已有失败均不算反证成功。runner及四个对照门禁与第五轮逐字节相同，未重新解释旧通过结果。

新 `run-equivalence.py` 供主会话编译两份纯源码守卫harness，以 **dd23535与本轮最终源码** 读取同一批 **718个文本输入**：当前320文件、全部367反证、复核只读／逃逸19条、12条Unicode／CRLF／raw string／插值等词法边界文本。逐项比较code与literal视图SHA-256及完整诊断数组，再核对所有带预期输入。12条附加文本仅用于新旧词法等价比较，不改变目录允许／拒绝预期。harness只编译守卫本身，输入样例绝不作为Swift源码编译。构建／运行分别1200／300秒，TIMEOUT单独失败；该比较不充当耗时验收。

## 补丁与静态结果

1. `01-guard-performance.patch`：TestSourceFacts.swift、TestPreferenceHygieneTests.swift。
2. `02-handoff.patch`：本文。

`all.patch`相对dd23535，`manifest.json`保存基线、分支、组顺序、最终文件和全部交付产物SHA-256；`commit-prepared.py`仅供主会话完成验收及复核后按组提交。本轮静态检查包括反向apply检查、在新建非git临时目录从基线逐组重放及SHA比对、所有Python脚本AST、50步精确源码变换、24处字符判断、34个唯一变异锚点、旧样例与历史交付哈希、产品源码与暂存区未变。没有Swift执行结果。

## 主会话命令（沙箱外）

先构建一次最终源码，再执行守卫、110类定向、源码反证、等价比较和运行期变异。每次使用新scratch目录；不安装或启动产品。R6 runner导出dd23535再应用all.patch。下列SC变量不覆盖系统环境变量。

```bash
cd ~/Developer/sc-worktrees/r2-hygiene-4
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
SC_SCRATCH="$HOME/Developer/.sc-build/r2-hygiene-4"
SC_PREP="$SC_SCRATCH/prepared-r6"
SC_CACHE="$HOME/Developer/.sc-build/r2-u1-preselect/debug"
SC_TAG="$(date +%Y%m%d-%H%M%S)"
SC_BUILD="$SC_SCRATCH/debug-r6-$SC_TAG"
SC_RUN="$SC_SCRATCH/logs/main-r6-$SC_TAG"
test ! -e "$SC_BUILD"
mkdir -p "$SC_BUILD" "$SC_RUN"
cp -R "$SC_CACHE/checkouts" "$SC_CACHE/repositories" "$SC_CACHE/artifacts" "$SC_CACHE/workspace-state.json" "$SC_BUILD/"
set -o pipefail
swift build --build-tests --scratch-path "$SC_BUILD" --jobs 4 2>&1 | tee "$SC_RUN/build-tests.log"
swift test --skip-build --scratch-path "$SC_BUILD" --jobs 4 --filter TestPreferenceHygieneTests 2>&1 | tee "$SC_RUN/guard.log"
SC_FILTER="$(paste -sd '|' "$SC_PREP/targeted-classes.txt")"
swift test --skip-build --scratch-path "$SC_BUILD" --jobs 4 --filter "$SC_FILTER" 2>&1 | tee "$SC_RUN/targeted-110.log"
SC_CASES="$SC_SCRATCH/source-cases-main-r6-$SC_TAG"
python3 "$SC_PREP/source-counterproofs.py" "$SC_CASES"
python3 "$SC_PREP/run-source-counterproofs.py" "$SC_CASES/cases.json" --build "$SC_BUILD" --logs "$SC_RUN/source-counterproofs"
python3 "$SC_PREP/run-equivalence.py" "$SC_SCRATCH/equivalence-main-r6-$SC_TAG" --logs "$SC_RUN/equivalence" --build-timeout 1200 --test-timeout 300
python3 "$SC_PREP/run-runtime-counterproofs.py" "$SC_SCRATCH/runtime-main-r6-$SC_TAG" --logs "$SC_RUN/runtime-counterproofs" --offline-cache "$SC_CACHE" --control-build "$SC_BUILD" --build-timeout 1200 --test-timeout 300
git diff --check
```

耗时验收必须仍与原批次 **4b0632cce947c7721b2f0bc578435f1dee077db0** 对比。`prepare-baseline.py`默认是补丁基线dd23535，下面显式传 **--ref 4b0632c**。等构建结束、其他批次编译和重负载停止，在空闲机器上至少各3轮交替测量；可增加runs，不能减少或挑最快一轮。

```bash
SC_TIMING="$SC_SCRATCH/timing-baseline-r6-$SC_TAG"
python3 "$SC_PREP/prepare-baseline.py" "$SC_TIMING/package" --ref 4b0632c
mkdir -p "$SC_TIMING/build"
cp -R "$SC_CACHE/checkouts" "$SC_CACHE/repositories" "$SC_CACHE/artifacts" "$SC_CACHE/workspace-state.json" "$SC_TIMING/build/"
swift build --build-tests --package-path "$SC_TIMING/package" --scratch-path "$SC_TIMING/build" --jobs 4 2>&1 | tee "$SC_RUN/build-timing-baseline.log"
# 编译全部结束并确认机器空闲后执行：
python3 "$SC_PREP/benchmark-guard.py" --baseline-package "$SC_TIMING/package" --baseline-build "$SC_TIMING/build" --current-build "$SC_BUILD" --logs "$SC_RUN/guard-timing" --runs 3
```

benchmark脚本与第五轮逐字节相同，双方读取同一个最终Tests目录，记录语料哈希、每轮XCTest／进程耗时、中位数及比值。验收仍要求 **当前中位数≤10秒、current/baseline≤1.10**；原复杂度断言 **2秒** 不改。任何一项不过就保留证据继续优化，不以CPU估计或本轮静态机会数代替正式验收。不得直接运行旧基线健康／清理业务测试；计时只执行一个源码守卫方法。

完整项目门禁、独立复核、提交、合并仍由主会话负责，按项目要求用独立验证根：

```bash
STORAGE_CLEANER_VERIFY_BUNDLE=0 STORAGE_CLEANER_UI_SMOKE=0 STORAGE_CLEANER_VERIFY_ROOT="$SC_SCRATCH/verify-r6-$SC_TAG" script/verify.sh 2>&1 | tee "$SC_RUN/verify.log"
```

## 未验证部分与已知边界

R6的Swift 6编译、全部绿／红反证、词法等价和实际收益待上述命令验证。此前复核在并发负载下观察到过生命周期测试调度超时，空闲重跑通过；本轮不改该测试及阈值。原词法守卫的跨文件／跨函数、动态路径、复杂类型推断和固定窗口限制保持原状，没有扩展或缩减分析范围。

本轮尝试调用实际可用的JEV决策工具，但工具返回 `MCP tool call requires approval, but approval policy is never`，没有获得判断；本轮未声称JEV复核。调用接口不提供模型选择参数。复核报告中的JEV意见属于上一轮复核员的证据。
