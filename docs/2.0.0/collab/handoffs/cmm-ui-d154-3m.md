# 交接：D154 第三批 M（智能扫描“运行”只跑确认过的维护任务）

日期：2026-10-22。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线树 `815bc3b0`（= 第三批 L 结果树，与 v2.0.1 的 `f631daec` 代码相同；v2.0.1 现为 `5d5375a0`，另多 DECISIONS 记录）。工具链 Xcode 27.1。未提交、未安装、未推送。

## 1. 来由

2.0.1 会话审阅第三批 L 时提出（记在 D154⑭ 的“留意”）：`runMaintenance()` 跑的是运行那一刻维护任务页的勾选，不是确认时的那一组。用户如果在清理期间去维护任务页改了勾选，实际执行的就会和确认过的不同。建议在确认时记下任务，只跑那几个。2.0.1 会话同意本批改法。

## 2. 改了什么

- `SystemMaintenanceStore` 新增 `run(_ tasks:)`：只跑传进来、并且此刻仍能运行的任务，按列表顺序。`runSelected()` 改成调用 `run(selectedTasks)`，维护任务页的行为不变。
- 智能扫描：用户在维护任务确认框上点“运行”的那一刻，记下 `selectedTasks`。它经 `SmartCareCoordinator.run(cleanup:maintenanceTasks:)`（原来是 `maintenance: Bool`）传给 `SmartCareRunning.runMaintenance(_ tasks:)`，只跑这几个。
  - 清理期间新勾的任务不会被带上；
  - 确认过、但到时已经不能运行的（比如状态变了）会被跳过；
  - 确认过的任务一个都不能运行时，记为失败。
  - 编排者另外公开 `confirmedTasks`，记录这次确认的是哪几个。

## 3. 测试

- `SystemMaintenanceTests.testRunningConfirmedTasksIgnoresALaterChangedSelection`（新增）：确认后取消原来的勾、勾上别的任务，`run(confirmed)` 仍只跑确认那组，新勾的没有跑。
- `SmartCareTests`：“运行”的几条测试改用新接口（`maintenanceTasks:`）。“先清理后维护”那条加了检查：执行器收到的正是确认的任务，`confirmedTasks` 也记着它们。原有期望没有放宽。

## 4. 验证

全部在 Xcode 27.1 上：

- debug 编译通过；release 编译、release 测试目标（`--build-tests -Xswiftc -enable-testing`）编译通过。
- 非窗口全量（10-22 04:18–04:22）：XCTest 5487 个（多了新增的 1 个）0 失败（27 个跳过），swift-testing 135 个通过。
- release 下的非窗口测试（04:18–04:47）：XCTest 5234 个 0 失败（26 个跳过），swift-testing 135 个通过。
- 窗口类：只跑受影响的。`CareStudioWindowReviewTests`（11 个，其中 2 个截图测试未设截图目录而跳过）、`ToolboxWindowReviewTests`（1 个）在虚拟屏 2 上通过。`CareStudioToolboxWiringTests` 不是窗口类，在非窗口全量里通过。本批只改了“运行”传参和维护任务的执行入口，没有动版式，所以没有重跑整套窗口测试。
- 未核对：真实的维护任务没有在本机运行。

## 5. 下一步

无（D168 两部分加这处修正都已交付）。仍推迟：智能扫描起始页第一次显示“欢迎使用…”。
