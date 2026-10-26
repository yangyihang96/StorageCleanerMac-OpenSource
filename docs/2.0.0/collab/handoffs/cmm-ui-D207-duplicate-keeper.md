# 交接：D207 重复文件忽略时自动留下一份不勾

日期：2026-10-25。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线是主会话第 15 次候选的最终树 `41d5415f`。结果树和 sha256 见交付消息。工具链 Xcode 27.1。未提交、未安装、未推送。

## 1. 问题

主会话合入 D207 管理器补丁时记下（10-25，不阻塞）：

- 三份一组的重复文件里，如果加入忽略的正是唯一没勾的那份（这一组留下的那份），剩下两份都还勾着。
- 生成清理计划时会报 `noRetainedCopy` 拒绝执行，所以是安全的，但用户得自己去掉一个勾。

## 2. 改法（`Features/DuplicateFiles/Stores/DuplicateFilesStore.swift`）

在 `ignore(_:feedback:)` 里拿出被忽略的文件之后：

- 被动到的每一组，如果还剩两份以上而且都勾着，就按路径排序取第一份，取消勾选。和选择规则“每组至少保留一份未选中的副本”一致。
- 不弹提示。现有的 `selectionMessage` 是一个标题为“无法选择”的弹窗，放在这里意思不对；勾选框本身已经表明了。
- 放回原处：被忽略的那份回来，仍是不勾，和忽略前一样；刚才取消勾选的那份重新勾上，恢复原样。
- 这一组被忽略的文件如果没有回来（仍被列表覆盖），就不重新勾选，避免又全勾上。

## 3. 测试

`D207IgnoreFromManagersTests.testADuplicateLeavesWithTheCopyLeftAloneAndComesBackWithIt` 加了一段，用一个以测试目录为家目录的 `DuplicateFilesStore`：只有家目录里的副本能勾选。

- 三份一组，勾第二、第三份；
- 忽略第一份（留下的那份）后，剩两份里只有一份勾着，没有弹窗；
- 放回原处后三份都回来，勾选和原来一样。

没有改动、删除任何旧断言。

## 4. 验证

Xcode 27.1。树是 `41d5415f` 加本项，在 heavy 锁里增量编译，10-25 10:52–10:54。

- 6 个非窗口类，112 个测试，0 失败：D207IgnoreFromManagersTests、IndependentFeatureWorkspaceStoreTests、D207IgnoreListStoreTests、D207IgnoreScannerTests、ItemListAndDuplicatePresentationTests、UIConsistencyRegressionTests。
- 静态检查：窗口类登记（D106）、删除与进程清单、私有 API 都通过。
- 窗口类不用补跑：没改视图。
- 没装、没提交。

## 5. 建议的 DECISIONS 写法

| # | 决定 | 影响 |
|---|---|---|
| D207 补（重复文件留一份） | 重复文件里加入忽略的正是一组唯一留下的那份时，剩下的若全勾着，自动取消勾选一份（按路径排序的第一份），保证每组留一份，计划不会因 noRetainedCopy 被拒；不弹提示。放回原处时恢复原来的勾选。 | `DuplicateFilesStore`；`D207IgnoreFromManagersTests` |
