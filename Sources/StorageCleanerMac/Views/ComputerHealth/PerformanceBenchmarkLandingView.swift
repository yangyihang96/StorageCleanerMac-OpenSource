import SwiftUI

struct PerformanceBenchmarkLandingView: View {
    @Environment(\.colorScheme) private var scheme
    let canStart: Bool
    var explanation: String? = nil
    let onStart: () -> Void
    let onShowSaved: () -> Void
    var identity: AppleSiliconIdentity? = nil
    var catalog: AppleSiliconCatalogLoader.Loaded = .init(catalog: nil, sha256: nil, reason: "notRead")
    var preflight: BenchmarkV7PreflightReport? = nil
    var helperAvailable = false
    var selection: Binding<MSeriesV11Selection> = .constant(.init())
    private var palette: FeatureLightfieldPalette { .resolve(scheme) }
    var body: some View {
        FeatureLightfieldPage(module: .performance, phase: .landing, title: ReviewFilter.performance.sidebarTitle,
            status: L10n.text("固定 18 项＋能效＋持续", "18 Core + efficiency + sustained"),
            safety: L10n.text("保存前可取消 · 芯片过热自动中止", "Cancel before saving · Thermal protection"),
            actionTitle: L10n.text("开始测试", "Start test"), actionEnabled: canStart, action: onStart,
            subtitle: MSeriesV11PagePresentation.chipLine(identity, catalog: catalog), artworkAccessory: AnyView(optionalTests)) {
                FeatureLightfieldPlacementReader { hasAccessory, _ in
                GeometryReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(L10n.text("测试内容 · 18 项核心", "Test content · 18 Core measurements"))
                                .font(.system(size: 13)).foregroundStyle(palette.fg2).padding(.bottom, 14)
                            FeatureLightfieldHairline()
                            PerformanceBenchmarkScopeRows()
                            planRow(L10n.text("能效曲线", "Efficiency curve"), L10n.text("CPU 三档 · GPU 峰值 30 秒", "3 CPU levels · GPU peak 30 s"))
                            planRow(L10n.text("持续性能 · 3 分钟", "Sustained · 3 minutes"), L10n.text("CPU 90 秒＋GPU 90 秒", "CPU 90 s + GPU 90 s"))
                            Text(budget).font(.system(size: 13)).foregroundStyle(palette.fg2)
                                .fixedSize(horizontal: false, vertical: true).padding(.top, 6).lightfieldComponentProbe("performance.budget")
                            Text(preflightText).font(.system(size: 13)).foregroundStyle(palette.fg2)
                                .fixedSize(horizontal: false, vertical: true).padding(.top, 4).lightfieldComponentProbe("performance.preflight")
                            if let explanation { Text(explanation).font(.system(size: 13)).foregroundStyle(palette.warningColor).padding(.top, 4) }
                            if !hasAccessory {
                                optionalTests.padding(.top, 16)
                                Text(MSeriesV11PagePresentation.chipLine(identity, catalog: catalog)).font(.system(size: 13))
                                    .foregroundStyle(palette.fg2).padding(.top, 8)
                            }
                            Button(L10n.text("本机历史", "Local history"), action: onShowSaved)
                                .buttonStyle(FeatureLightfieldRowButtonStyle()).foregroundStyle(palette.fg2).font(.system(size: 13)).padding(.top, 8)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.scrollIndicators(.hidden).lightfieldComponentProbe("performance.landing.scroll")
                }
                }
            }
    }
    private var budget: String {
        let range = selection.wrappedValue.estimatedSeconds
        let estimate = "\(Int(range.lowerBound / 60))–\(Int(ceil(range.upperBound / 60)))"
        let mode = selection.wrappedValue.pressure ? L10n.text("压力观察独立模式，不计分", "Independent pressure observation, unscored") :
            L10n.text("持续 3 分钟单列", "Includes 3 min sustained")
        return L10n.text("约 \(estimate) 分钟（\(mode)） · 写入 ≤512 MB", "About \(estimate) min (\(mode)) · Writes ≤512 MB")
    }
    private var preflightText: String {
        let power = preflight.map { $0.powerSource == .acPower ? L10n.text("交流电", "AC power") :
            $0.powerSource == .battery ? L10n.text("电池", "Battery") : MSeriesV11PagePresentation.unread } ?? MSeriesV11PagePresentation.unread
        let lowPower = (preflight?.lowPowerModeEnabled).map { $0 ? L10n.text("省电模式", "Low Power Mode") : L10n.text("非省电", "Low power off") }
            ?? MSeriesV11PagePresentation.unread
        let thermal = preflight.map { $0.thermalState == .unknown ? MSeriesV11PagePresentation.unread : $0.thermalState == .nominal ? L10n.text("温度正常", "Thermal nominal") :
            L10n.text("温度需关注", "Thermal attention") } ?? MSeriesV11PagePresentation.unread
        let background = preflight?.backgroundLoadRatio.map { $0 < 0.2 ? L10n.text("后台空闲", "Background idle") : L10n.text("后台繁忙", "Background busy") }
            ?? MSeriesV11PagePresentation.unread
        let helper = helperAvailable ? L10n.text("系统助手：可用", "System Helper: available") :
            L10n.text("系统助手：不可用（能效将不显示）", "System Helper: unavailable (efficiency hidden)")
        return [power, lowPower, thermal, background, helper].joined(separator: " · ")
    }
    private func planRow(_ title: String, _ detail: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(palette.fg)
            Spacer(minLength: 0)
            Text(detail).font(.system(size: 13)).foregroundStyle(palette.fg2).lineLimit(1).truncationMode(.tail).help(detail)
        }.frame(height: 44).overlay(alignment: .bottom) { FeatureLightfieldHairline() }
    }
    private var optionalTests: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("可选测试 · 独立选择", "Optional tests · Independent selections")).font(.system(size: 13)).foregroundStyle(palette.fg2)
            choice(L10n.text("10 分钟压力模式", "10 minute pressure mode"), selected: selection.pressure)
            choice(L10n.text("加速单元 · 另计用时", "Accelerators · Additional duration"), selected: selection.accelerators)
            Text(L10n.text("媒体引擎、光线追踪 · 独立展示，不计分", "Media, ray tracing · Independent, unscored"))
                .font(.system(size: 12)).foregroundStyle(palette.fg2).padding(.leading, 32)
            Text(L10n.text("神经网络引擎 · 阶段 2", "Neural Engine · Phase 2")).font(.system(size: 13)).foregroundStyle(palette.fg3).padding(.leading, 32)
                .accessibilityLabel(L10n.text("神经网络引擎，阶段 2，当前不可选择", "Neural Engine, Phase 2, unavailable for selection"))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func choice(_ title: String, selected: Binding<Bool>) -> some View {
        Button { selected.wrappedValue.toggle() } label: {
            HStack(spacing: 12) {
                FeatureLightfieldCheck(selected: selected.wrappedValue, module: .performance)
                Text(title).font(.system(size: 15)).foregroundStyle(palette.fg).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(FeatureLightfieldRowButtonStyle()).accessibilityLabel(title)
            .accessibilityValue(selected.wrappedValue ? L10n.text("已选", "Selected") : L10n.text("未选", "Not selected"))
    }
}

struct PerformanceBenchmarkScopeRows: View {
    var body: some View {
        VStack(spacing: 0) {
            LightfieldOptionRow(title: "CPU", icon: .benchmarkCpu, module: .performance, metadata: L10n.text("4＋4 项 · 单线程/多线程", "4 + 4 · Single/multi thread"))
            LightfieldOptionRow(title: "GPU", icon: .benchmarkGpu, module: .performance, metadata: L10n.text("3 项 · 离屏图形/单精度/半精度", "3 · Offscreen/FP32/FP16"))
            LightfieldOptionRow(title: L10n.text("内存", "Memory"), icon: .benchmarkMemory, module: .performance, metadata: L10n.text("3 项 · 复制/三数组运算/指针追逐", "3 · Copy/Triad/Pointer chase"))
            LightfieldOptionRow(title: L10n.text("存储", "Storage"), icon: .benchmarkStorage, module: .performance, metadata: L10n.text("4 项 · 顺序/4K 单队列", "4 · Sequential/4K QD1"))
        }
    }
}
