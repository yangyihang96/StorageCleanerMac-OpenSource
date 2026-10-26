# 2.0.0 协同工作规则（Claude 调度 + Codex 实现）

本文件约束所有参与 2.0.0 测试版开发的会话，包括 Claude 主会话与它派出的 Claude 子代理（原计划的 `ocx-gpt-6-astra` Codex 子代理在本会话不可用，见 DECISIONS D9）。
用户的产品决定见 `DECISIONS.md`，任务状态见 `BOARD.md`，每批交接写在 `handoffs/`。

## 1. 唯一源码位置

- 仓库：`/Users/developer/Developer/StorageCleanerMac`（不在 iCloud／Google Drive 同步范围）。
- 集成分支：`integration/2.0.0-beta`。只有 Claude 主会话合并到这里。
- 旧目录 `~/Documents/好玩的/StorageCleanerMac-v199` 只是迁移前的只读备份，不得修改、构建或提交。

## 2. 每个批次的工作方式

1. 从集成分支最新提交建 worktree：`git worktree add ~/Developer/sc-worktrees/<批次> -b task/<批次> integration/2.0.0-beta`。
2. 只在自己的 worktree 里改动；不碰其他 worktree、集成分支工作区和旧目录。
3. 构建和测试使用本 worktree 专属的 scratch 目录，例如 `--scratch-path ~/Developer/.sc-build/<批次>/debug`，不要共用 `/tmp/storage-cleaner-*` 默认目录。
   随时清缓存（用户 10-07 要求）：反证、改前包、严格并发、Release 等临时构建和截图用的 `.app` 副本，用完即删，只留日志、截图和证据；批次合并后由主会话删掉该批 scratch 构建产物（带 `CACHEDIR.TAG` 的目录）和 `/tmp/storage-cleaner-<批次>*`。离线依赖统一从 `~/Developer/.sc-build/r2-u1-preselect/debug/{checkouts,repositories,artifacts,workspace-state.json}` 复制，这份保留。
4. 在本分支做小而清楚的提交，提交信息说明“改了什么、为什么”。
5. 完成后写 `handoffs/<批次>.md`：改动清单、实际运行的命令与 exit code、测试数量与跳过、未解决问题。
6. 由另一方复核（见 `BOARD.md`），意见处理完，Claude 合并并跑完整门禁。

并发限制（D60 起，10-08 更新）：实现一律交 Codex，模型 `openai/gpt-6.1-sol`（含较难任务，不再用 Astra），可多条并行，各用自己的 worktree；Claude 子代理主要做复核和必须在沙箱外完成的工作（截图、录屏、实测）；`Sources/StorageCleanerMac/Stores/ScanStore.swift` 同一时间只允许一个批次修改。

Codex 沙箱（10-08 补）：用户的 `~/.codex/config.toml` 默认 `sandbox_mode = "danger-full-access"`。新会话一律带 `-s workspace-write -C <worktree> --add-dir <scratch>`；续接（`codex exec resume`）没有 `-s`，不会沿用原会话的沙箱，必须写成 `codex exec resume -c 'sandbox_mode="workspace-write"' -c 'sandbox_workspace_write.writable_roots=["<scratch>","<prompts>"]' <会话 id> "<消息>"`，并在日志头核对 `sandbox: workspace-write`。只读复核用 `-s read-only`。`-i` 附图时在提示词前加 `--`。

## 3. 构建与测试命令

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build --scratch-path <scratch>/debug --jobs 4
swift test  --scratch-path <scratch>/debug --jobs 4 --filter '<相关测试类>'
```

完整门禁由 Claude 在集成分支上跑（`script/verify.sh` 的同等步骤）：Release 全量、Debug 全量、严格并发、源码守卫、小窗性能、`git diff --check`。
已知环境限制：本机 Claude 进程不能读取 `~/.Trash`；计时类测试在机器高负载时可能超预算，须在空闲时重跑，不得放宽阈值。

测试夹具位置（D48、N13）：偏好域一律用 `TestPreferenceDomain` 的临时目录绝对路径域；JSON 存储、解析等纯数据夹具用 `TestFileSystem.uniqueRoot` 或 `TestFileSystem.makeHome(for:)`，根为系统临时目录中的 `StorageCleanerMac-Tests-<用途>-<UUID>`。凡是经过移到废纸篓、写回执（`CleanupReportJournal`）、恢复、卸载移动或迁移来源校验的夹具，用 `TestFileSystem.uniqueOperationRoot` 或 `TestFileSystem.makeOperationHome(for:purpose:)`，根为 `~/.storage-cleaner-<用途>-<UUID>`；需要家目录结构时注入根内的 `home`。不得手写唯一根或改进程 `HOME`，不得在真实 `~/Library/Caches`、`~/Library/Preferences`、本应用数据目录或真实 `.Trash` 中建夹具；产品安全检查保持不变。

测试中的 `ScanStore` 一律通过 `try ScanStore.makeForTests(for:)` 构造。`makeHome`、`makeOperationHome` 自动在创建前登记本测试的所有权及 teardown 清理；`uniqueRoot`、`uniqueOperationRoot` 只返回地址，由调用方负责部分创建失败时回收和测试结束时严格清理。自建根或其子路径要覆盖传入工厂时，必须先用 `TestFileSystem.registerCleanup(of:for:)` 登记；若夹具已有自己的严格收尾，可用 `registerOwnership(of:for:)` 仅登记所有权。工厂对数据根、操作 home、journal、trash 等覆盖路径执行 `requireOwned` 检查，根必须属于当前 `XCTestCase`，不能仅凭位于 HOME／temp 或带 UUID 视为安全。收尾用 `TestFileSystem.remove` 报告删除错误；有后台操作或记录刷新时先打开 gate、取消并等待相关任务退出，再删除，不吞错、不固定 sleep、不重试删除。 测试工厂必须持有 store 到收尾完成，不能因弱引用失效跳过。默认整体等待上限 30 秒；超时或等待取消必须报告未结束任务并保留本测试的根和偏好域，不能当作任务完成。主会话处理保留夹具时，先根据日志确认根的本测试所有权，再确认对应任务/测试进程已经退出，最后严格删除该根及其绝对路径偏好域并核对残留；任务仍在运行时不得删除，不自动清扫或重试。

## 4. 子代理禁止事项

- 不安装、不复制到 `/Applications` 或 `~/Applications`，不启动或退出已安装的测试版、正式版；实机操作只由 Claude 主会话执行。
- 不在真实文件、真实应用上执行清理、卸载、恢复、清空废纸篓；只用项目自带的隔离夹具。
- 不写风扇、充电、电源等硬件设置。
- 不 push、不打 tag、不发布，不改更新源（appcast）、服务器或 CI。
- 不读取钥匙串、凭证、令牌、`.env`；不输出私人路径、进程清单等原始数据到交接文档以外的地方。
- 不 `git reset --hard`、不 `git clean`、不删除别人的分支或 worktree。
- 不为了让测试通过而删断言、放宽阈值或跳过测试。源码契约测试锁定的是既有决定：要改它，必须在 `DECISIONS.md` 里有对应决定，并在交接中写明。

## 5. 必须遵守的项目规则

- `AGENTS.md`：扫描只读；清理必须是显式 UI 操作并优先移入废纸篓；绿／黄／红分级边界不变。
- 复用现有实现，不新造平行系统：`AppDesignTokens`、`MiniWindowStyleTokens`、`ModuleThemeCatalog`、`AppSymbolGlyph`、`SystemFanSpeedFormat`、`ByteFormat`、唯一的 `CleanReportStore`／回执日志、`HeavyWorkCoordinator`、`MetricHistoryStore`。
- UI 不偏离原概念图（`artifacts/concept-comparison-20261001/references/`）太多；日间暖象牙白、主窗口夜间默认“深空”（D56，纯黑为可选）、小窗夜间纯黑等后续明确要求优先于旧图。
- 中文界面不出现英文术语和内部枚举名；单位与精度走统一出口。
- 真实未知、过期、不支持要和“0”区分，不用假数据填补。

## 6. 汇报口径

- 每项结论标 PASS / FAIL / BLOCKED / NOT RUN，并附命令、exit code、日志路径或截图。
- 构建、测试、安装、提交分别报告；没跑的不写成通过。
