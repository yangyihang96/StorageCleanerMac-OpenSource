# 竞品功能补齐验证记录（2026-10-20）

工作区 `~/Developer/sc-worktrees/feature-parity`，Debug 编译含测试（Xcode 27.0.0 Beta 工具链，`swift build --scratch-path ~/Developer/.sc-build/feature-parity --build-tests`），全部通过。

## 本组测试

| 测试类 | 数量 | 结果 |
|---|---|---|
| `ExtensionManagerTests` | 11 | 通过 |
| `SystemMaintenanceTests` | 12 | 通过 |
| `SystemProcessNotesTests` | 5 | 通过 |
| `DuplicateCloneMergeTests` | 7 | 通过（家目录 APFS 上真实 `clonefile` 和 `RENAME_SWAP`） |
| `BrokenPreferencesRuleTests` | 4 | 通过 |
| `QQBrowserPrivacyProviderTests` | 2 | 通过 |
| `ChatFilesTests` | 8 | 通过（四种目录布局夹具） |
| `ToolboxRenderReviewTests` | 2 | 通过（离屏渲染：扩展页、扫描页、聊天文件权限引导页） |
| `ToolboxWindowReviewTests`（副屏） | 1（27 个窗口） | 通过，见下 |
| `ToolboxLiveReadOnlyTests` | 2 | 默认跳过；本机只读核对见下 |

最后一次改动后（菜单标签、聊天文件左栏、筛选菜单样式，以及新增的权限引导页渲染），本组加上随改的规则、浏览器隐私、界面一致性、删除不变量测试共 298 个复测：0 失败，3 个按设计跳过（需显式开启的本机核对）。

## 非副屏全量

- 第 1 次（22:17–22:23）：5437 个，9 处断言失败，分布在 5 个用例，都是本次改动的连带：注册 Provider 数（2 处）、需确认规则清单、规则表文档（升版本号后要再生成）、“会移到废纸篓的文件不得含删除调用”（聊天文件的复制改成单独文件）、Views 不得写本地按钮样式和颜色。均已修正。
- 第 2 次（22:30–22:40，其他会话同时大量编译，负载 60–70）：5437 个，6 处断言失败，只在 3 个计时用例：`FileAnalysisTrashCostTests` 两个耗时预算、`MacBenchmarkKernelTests.testStandardQuickKernelsCompleteWithinDeclaredLimits`（15 秒限时）。负载降到 11 后单独重跑全部通过（该文件写明：繁忙机器上超预算的重跑，不放宽）。第 2 次之后只改了视图样式和一条渲染测试，已由上面 298 个复测覆盖。

## 副屏（D106）

- `ToolboxWindowReviewTests` 在“虚拟屏 1 · Codex”上（22:32–22:33）：扩展、维护任务、聊天文件三个面板 × 1070×735、1024×734、780×540 × 中文深色/中文浅色/英文深色，共 27 个窗口；面板、主按钮、已选合计都在窗口内。门禁日志 `display_gate_log.py --check` 通过（27 placed / 27 moved）。截图逐张看过，发现的三处样式问题已改。
- 改完样式后的复跑（22:57–22:58，同一块虚拟屏，用最终编译）：27 个窗口全部通过，门禁日志通过（27 placed / 27 moved）；截图确认“排序：大小 / Sort by: Date”显示完整、聊天文件左栏先写大小、筛选改为“类型：全部 / Kind: All”菜单。截图存在 `~/Claude 好玩的/清理软件全功能对比-2026-10-20/截图/`。

## 仓库检查

- `script/check_deletion_process_inventory.py`：通过（172 条，264 处）；本组新增登记 12 条。
- `script/display_bound_tests.py --check`：通过（59 in-process、1 out-of-process、1 exempt）。

## 本机只读核对（`STORAGE_CLEANER_RUN_LIVE_TOOLBOX_SCAN=1`，只打印数量和用时）

- 扩展：0.59 秒；第三方应用扩展 62 个、Safari 扩展 1 个、`/Library` 里音频插件 4 个、内核扩展 3 个，Apple 自带 502 个只计数。
- 维护任务：0.32 秒读完 9 项状态；这台 Mac 没有周期维护脚本（标“无需运行”）。

## 没做的

- 没装测试版；没在本机实际运行加速邮件、刷新“打开方式”数据库、克隆合并、移到废纸篓、复制到外置盘。
- Release 编译、严格并发、守卫、打包和测试版组装：合进 v2.0.1 后由 2.0.1 会话按它的全量流程跑。
