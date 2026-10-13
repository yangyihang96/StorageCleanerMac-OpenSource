# r2-lf2-b4-p2：B4 合并后的两项 P2 收尾

## 基线与范围

- 日期：2026-10-10；worktree `/Users/developer/Developer/sc-worktrees/r2-lf2-b4-p2`，分支 `task/r2-lf2-b4-p2`。
- 基线 `a674de6a01fe006d2f2c9f70e74e548d604819c5`，开始时工作区干净，已含 B4 合并。
- 已读公共说明 `lf2-pages-common.md`、`codex-build-common.md`、`common.md`，以及 RULES、相关 DECISIONS、BOARD。BOARD 没有本次 P2 独立行；批次依据本轮派工和 B4 复核日志末尾。
- 复核依据：`/Users/developer/Developer/.sc-build/r2-lf2-b4/logs/codex-review.log` 末尾两项 P2。冻结稿：`approved-20261009/renders/a/uninstall-result-{night,day}.png` 与对应共用 HTML/JS。
- 仅修改呈现与测试；`ScanStore.swift`、卸载选择／归属检查／预览／执行与更新安装确认均保持原实现；无新增 Store 字段需求。

## 改动

### 1. 窄宽统计完整字形

- `LightfieldMetricGroup` 的 inline 呈现移除 13→8 pt 线性缩字及数字缩放／裁剪。标签固定 13 pt，数字固定 24 pt；单位仍为 15 pt。
- 共用组件新增 `LightfieldInlineMetricsLayout`、`LightfieldInlineMetricLayout`：测量原生未压缩 Text 的固有尺寸，选择能容纳完整标签与数字的等宽列数。六项使用 6／3／2／1 列，行间距 12 pt；单元格至少 48 pt，组高度随行数增长。单元格放得下时沿用数字＋标签的横向基线，否则标签移到数字下方。
- 结果与上次检查两处现有调用共同获益，继续使用各自已有独立滚动区。标准宽度／普通计数仍锁定 48 pt 一行。原 stacked 展示保持既有字号和布局用途。
- 标签／数字探针放在 `.fixedSize()` 后、任何外层裁剪前，报告固有文本几何；新测试用 CoreText 独立整串塑形，并用 AppKit 文本布局断言完整 glyph range 和无 truncatedGlyphRange。标签与数字均断言完整文本宽度 ≤ 列宽、文本探针匹配未缩字宽度、无省略号与越列。
- `FeatureLightfieldApplicationP2Tests` 覆盖七尺寸对应 landing/result 宽度、中英文、日夜、400 pt 详情（内容宽 352 pt）、普通计数与 20 位长数字。现有页面测试继续覆盖七尺寸三态骨架和滚动边界。

### 2. 卸载列头

- 在生产卸载结果页的控件与行之间接入已有 `LightfieldApplicationListHeader(kind: .uninstall)`，显示“应用 / 版本、应用路径、可审阅大小”。
- 列头继续使用与行完全相同的 `LightfieldApplicationColumns`，增加 debug 几何探针。组件测试覆盖七尺寸 × 中英文 × 日夜，逐列锁定 minX/maxX 误差 ≤ 0.5 pt，并确认列头 28 pt、首行紧接其后。生产页面骨架测试也逐列比较实际列头与实际行。

## 旧断言迁移及依据

本轮用户明确要求放不下时换行或减少列数，禁止继续缩小字号；该具体要求优先于旧 B2“所有宽度固定 48 pt”的实现契约。

1. `FeatureLightfieldApplicationPageTests.testApplicationPagesKeepProductionSkeletonAcrossThreeStatesSevenSizesAndTwoSchemes`：宽屏仍断言 48 pt；窄宽改为至少 48 pt，并由完整字形／多行布局测试锁定结果。
2. `testSixInlineMetricsContainLongValuesAndReadTheirCompleteLabels`：撤换“给数字固定列宽后裁剪”的源码守卫，改为 native 固有尺寸探针、完整 Text 固定字号／尺寸、禁止 inline 缩放／截断／裁剪。长数字宿主高度从 80 改为 420 pt，以容纳最多六行；组、列、文本的 0.5 pt 包含断言和完整 AX 文本仍保留。
3. `ConceptLandingNativeLayoutRegressionTests.testActualInertUpdaterLastCheckKeepsFiveStatisticsAndManageButtonAtNarrowWidths`：统计组不再硬锁窄宽 48 pt；原五项＋unknown、完整 AX 文本、统计不重叠、管理按钮尺寸／可操作／可见／不重叠、独立滚动可达性与只读状态断言全部保留。

## 本轮验证

| 验证 | 结果与 exit code | 证据（scratch 相对路径） |
|---|---|---|
| `swift build "${F[@]}" --build-tests` | **PASS**，exit 0，261.45 秒 | `logs/build-r1.log` |
| 新类独立 `--filter FeatureLightfieldApplicationP2Tests` | **PASS**，4 测试／0 失败／0 跳过，exit 0 | `logs/p2-r1.log` |
| `targeted-classes.txt` 11 类 | **BLOCKED**（XCTest 总体 FAIL），149 测试，136 个通过、13 个失败用例、14 条失败记录（11 unexpected），0 跳过，exit 1 | `logs/targeted-r1.log` |
| 两项偏好持久化单独复跑 | **BLOCKED**，2 用例／3 条失败记录，exit 1；同样出现沙箱扩展授权 EPERM | `logs/preferences-isolated-r1.log` |
| 源码私有 API 检查 | **PASS**，exit 0，7 项已列白名单 | `python3 script/check_private_api.py` |
| `git diff --check` | **PASS**，exit 0 | prepared `static-checks.json` |
| 分组补丁反向校验／提交助手默认只读核对 | **PASS**，exit 0；基线／分支／空索引／8 个最终文件及产物 SHA-256 一致 | prepared `all.patch`、`manifest.json`、`static-checks.json` |
| 反证 | **NOT RUN**，8 项配方，替换次数与筛选器静态核对 | `counterexamples.json` |
| 全量／Release 构建／严格并发／重拍／提交／安装 | **NOT RUN** | 由主会话继续 |

新增 P2 类在定向清单中再次 4／0；UIConsistencyRegressionTests 46／0，ComponentTests 19／0，ComponentGeometryTests 17／0，ComponentSourceTests 6／0，ApplicationPresentationTests 5／0，ReleaseIsolationTests 1／0。没有尚未解释的产品断言失败；不能将这项分类写成完整门禁已通过。

### 沙箱阻塞清单

| 类 | 阻塞用例数 | 依据 |
|---|---:|---|
| `ConceptLandingNativeLayoutRegressionTests` | 3 | 家目录 `~/.storage-cleaner-scan-store-UUID/home` 创建失败；NSCocoaErrorDomain 513／NSPOSIXErrorDomain 1 `Operation not permitted` |
| `FeatureLightfieldApplicationPageTests` | 2 | 同上；包含新扩展的生产卸载结果列头／行边界检查，须沙箱外复跑 |
| `FeatureLightfieldContractTests` | 6 | 同上；尚未进入页面或交互断言 |
| `TestPreferenceHygieneTests` | 2 | 临时绝对路径偏好域的 `synchronize()`／plist 落盘失败；日志同域反复报 `sandbox_extension_issue_file ... Operation not permitted` |

精确的 13 项 class/method 筛选器见 scratch `blocked-tests.txt` 与 `validation-results.json`。偏好失败为 `testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory`（308–309 行）和 `testTemporarySuiteCanBeReopenedOnAWorkerThread`（324 行）；已单独启动测试进程复现，且 `TestPreferenceHygieneTests.swift`、`TestPreferenceDomain.swift`、`TestFileSystem.swift` 与基线逐字节相同。临时域源码卫生检查仍通过；未改路径安全检查、偏好工厂、断言或跳过测试。

## 主会话复跑命令

```zsh
cd /Users/developer/Developer/sc-worktrees/r2-lf2-b4-p2
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path /Users/developer/Developer/.sc-build/r2-lf2-b4-p2/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
FILTER=$(paste -sd '|' /Users/developer/Developer/.sc-build/r2-lf2-b4-p2/targeted-classes.txt)
swift test "${F[@]}" --skip-build --filter "$FILTER"
```

Release／严格并发／完整门禁按项目 `script/verify.sh` 的等同步骤由主会话完成；不在本沙箱跑全量。

## 红／绿／反证

- 红：旧版 400 pt 详情中英文 Authorization 即使缩到 8 pt，完整字形 52.87 pt 仍超过 48.89 pt 列宽；新的固定 13 pt 完整字形断言会拒绝旧缩字方案。卸载旧结果页缺列头，生产接入守卫／实际列头探针应失败。
- 绿：编译与可运行定向结果见本轮验证段。不能用完整 AX 标签或已裁剪边框代替完整字形证据。
- 反证：scratch `counterexamples.json` 有 8 项独立替换（强制六列、标签缩到 8、数字缩到 12、标签加省略号、恢复数字缩放、组裁为 48、移除卸载列头、列头使用更新列宽）。沙箱只核对替换恰好一次和测试筛选器存在；按 `codex-build-common.md` 由主会话逐项执行、确认失败、恢复原文并清理临时反证构建。

## 需重拍场景

1. 更新结果页与带“上次检查”统计的更新起始页：七尺寸 `820×560、1000×700、1280×763、1680×1050、2400×1350、677×390、1280×390`，中英文、日夜；重点核对窄宽列数切换、所有标签与数字完整、管理入口可滚动到达、主按钮和状态行不位移。
2. 更新起始页额外 400 pt 详情宽度，英文 `Authorization`、普通计数及 20 位数字；确认固定字号、多行高度与滚动末尾。拖动到列数切换临界宽度复核没有裁剪闪现。
3. 卸载结果页：上述七尺寸 × 中英文 × 日夜；重点标准 `1280×763` 对照冻结日夜稿三列头、列头与行边界、短高 `677×390／1280×390` 内容滚动、长路径中间省略与主按钮位置。

截图／安装与正式 C-UI2 验收仍由主会话进行；本批不启动已安装应用、不安装、不清理、不修改硬件设置。

## Prepared 与后续

- scratch `/Users/developer/Developer/.sc-build/r2-lf2-b4-p2/prepared/`：三组 `01-readable-statistics`、`02-uninstall-header`、`03-regressions-handoff`，包含组补丁／提交说明、all.patch、SHA-256 manifest、static-checks.json、counterexamples.json、targeted-classes.txt、commit-prepared.py。
- `.git` 为只读，不在沙箱提交。主会话完成验证／反证／复核后执行 `python3 .../prepared/commit-prepared.py --commit --validated`；脚本默认仅核对基线、分支、改动范围、哈希与暂存区，不做安装／推送。
- JEV `jev_decide` 调用被自动审批拒绝，原文为 `MCP tool call requires approval, but approval policy is never`；没有取得模型判断。工具未暴露 model 参数，未替换模型或重试绕过。
