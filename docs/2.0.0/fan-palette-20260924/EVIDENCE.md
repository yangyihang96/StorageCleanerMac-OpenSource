# 2.0.0 Beta 风扇控制浮层，2026-09-24

这里的五张 PNG 来自 `ControlPaletteTests.testFanPaletteNativeLayoutMatrixFitsAndKeepsHardwareReadOnly` 对**真实生产 SwiftUI 组件**的只读夹具渲染，模拟数据不会连接或写入风扇。它们不是已安装 App 的实机截图。全部矩阵共生成 64 张并自动检查布局，覆盖 8 种硬件/Helper 状态、中文/英文、明暗外观和紧凑/展开布局；代表画面另作目视检查，这里只保留其中五张供审阅。

执行记录：

- 定向回归：`./script/test.sh --filter 'HardwareControlPresentationTests|GeekSensorsPowerHoverDetailTests|ControlPaletteTests'`，85 项通过。
- Release 全量：2878 项，17 跳过，0 失败。
- 严格并发编译：通过。
- Debug 全量：2933 项，18 跳过，1 失败。失败用例 `MacBenchmarkKernelTests.testStandardQuickKernelsCompleteWithinDeclaredLimits` 在未修改的 15 秒资源限制处报 `BenchmarkKernelError.resourceLimit`；两次单独重跑同样失败。未改阈值、工作量或断言。
- `./script/build_and_run.sh --beta --install` 因上述测试失败以退出码 1 停止，**未安装新版**。当前安装版构建号仍为 `20260924071942`。
- 未执行真实风扇模式切换、转速写入或 Helper 注册。

完整本地构建日志位于 `/tmp/storage-cleaner-fan-palette-build-install-20260924.log`；它可能包含本机路径，不作为可公开发布的附件。
