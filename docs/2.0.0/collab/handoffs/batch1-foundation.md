# 批次 1 交接：地基与门禁

- 实现：Claude（主会话）　复核：只读子代理。**更正**：原记为“Codex（gpt-6-astra）”，子代理记录显示实际模型是 `claude-haiku-4-5-20251001`（本会话调不到 gpt-6-astra，见 DECISIONS D9）；合并提交信息里的“Codex reviewed”同样应读作“Claude Haiku 4.5 子代理复核”
- 分支：`task/batch1-foundation`（`5629df0`…`b55cd70`），2026-10-04 合并为集成分支 `0428609`

## 改动

| 项 | 内容 | 文件 |
|---|---|---|
| 私有接口检查 | 旧 grep 只看单行，`dlopen(` 换行后的私有框架路径能漏过。改为 `script/check_private_api.py`：去掉空白后匹配 `dlopen`（非公开框架或非字面量）、`dlsym`、`NSClassFromString`、`NSSelectorFromString`/`Selector("…")`、`*Private` 导入和 `PrivateFrameworks` 链接；结果必须与 `script/private-api-allowlist.txt` 逐项一致（含理由），多出或过期都失败（exit 12） | `script/check_private_api.py`、`script/private-api-allowlist.txt`、`script/verify.sh` |
| 冲突副本 | 删除 9 个 iCloud 冲突副本（内容保留在 `a4afc22`），移除 `Package.swift` 排除表；门禁发现 `Name 2.swift`、`Name 10.swift` 这类文件即失败（exit 14） | `Package.swift`、`Sources/**`、`Tests/**`、`script/verify.sh`、`Tests/.../R2ProductionSource.swift` |
| 构建脚本 | 非 Beta 模式使用正式版身份。原来会 `pkill` 正在运行的正式版，现在改为拒绝运行（exit 3）；只有设置 `STORAGE_CLEANER_QUIT_RUNNING_APP=1` 时才请求正常退出，20 秒内没退出就停止，不强杀。`--bundle-only` 不受影响 | `script/build_and_run.sh` |
| 废纸篓测试 | 本进程不能读 `~/.Trash` 时，卸载往返测试显式 `XCTSkip`，不再失败，也不在真实废纸篓留夹具 | `Tests/.../SystemUtilitySafetyTests.swift` |
| 文档 | AGENTS.md 指向新位置、`--beta` 流程、白名单和协作目录；PROJECT_STATE 顶部加当前状态 | `AGENTS.md`、`docs/PROJECT_STATE.md` |

## 复核意见与处理（Claude Haiku 4.5 子代理）

1. P1：冲突副本检查的 `'* [0-9].*'` 只匹配一位数字编号。已改为先 `find -name '* [0-9]*'`，再 `grep -E ' [0-9]+\.[^/]+$'`；负例测试中 `Foo 2.swift`、`Foo 10.swift` 被拦下，`Bar 2D.swift` 不误报。
2. P2：`NSSelectorFromString` 没有纳入清单。已按文件纳入（与 `dlsym` 相同口径），白名单理由列出 9 个 PowerUI 方法；负例测试 `NSApp.perform(NSSelectorFromString("_secret"))` 被拦下（exit 12）。

## 门禁（`script/verify.sh`，HEAD `b55cd70`）

| 运行 | 结果 |
|---|---|
| 第 1 次（11:46–11:58） | Release 3014 项／跳过 21／0 失败；严格并发通过；Debug 3101 项／跳过 22／**1 失败**：`NetworkCompatibilitySpeedTestServiceTests.testStoreCancellationWaitsForRealCompatibilitySessionShutdownBeforeLeaseRelease`（`stopCount` 0 < 1）。`set -e` 使后续步骤没有执行 |
| 失败项单独重跑 | 12/12 通过 |
| 第 2 次（11:59–12:02） | **全部通过**：Release 3014／21／0；Debug 3101／22／0；私有接口检查通过（6 处白名单）；无冲突副本；小窗性能 p95 66.2 ms；`git diff --check` 通过；`Repository verification passed.` |

日志：`~/Developer/.sc-verify/batch1/verify-20261004-114647.log`、`verify-20261004-115927-rerun.log`。
合并提交在 `b55cd70` 之上只多了协作文档；合并后另跑了私有接口检查、冲突副本检查和 `git diff --check`，均通过。

## 遗留

- 上面那个网络测速取消测试有竞态：全量运行时偶发失败，与本批改动无关（本批没有改网络代码）。它测的是“取消后，租约释放前请求已真正停止”，失败说明负载下可能先释放了租约。列为 P2，待批次 4a 或 5 查清。
- 落地页尺寸扫描测试移到批次 3b，与截断修复一起提交。
