import SwiftUI

extension MemoryReclaimer.Reading {
    /// The same counters from a memory snapshot (its free bytes include the
    /// speculative pages).
    init(snapshot: MemorySnapshot) {
        let speculative = UInt64(max(0, snapshot.speculativeBytes))
        self.init(
            physicalBytes: UInt64(max(0, snapshot.physicalBytes)),
            freeBytes: UInt64(max(0, snapshot.freeBytes)) - min(UInt64(max(0, snapshot.freeBytes)), speculative),
            speculativeBytes: speculative,
            inactiveBytes: UInt64(max(0, snapshot.inactiveBytes)),
            fileBackedBytes: UInt64(max(0, snapshot.fileBackedBytes)),
            purgeableBytes: UInt64(max(0, snapshot.purgeableBytes)),
            compressedBytes: UInt64(max(0, snapshot.compressedBytes)),
            pressureLevelCode: snapshot.reportablePressureLevel.map { Int32($0.systemCode) })
    }
}

/// D144: the memory module as a CleanMyMac page — pressure, use and cache
/// as the module's lines, "释放" as the round button, the app list behind
/// "查看占用最多的应用" (the classic page, with its own quit confirmation).
struct CareStudioMemoryLanding: View {
    let snapshot: MemorySnapshot?
    let isLoading: Bool
    let canFreeUp: Bool
    let onFreeUp: () -> Void
    let onShowApps: () -> Void

    private var reading: MemoryReclaimer.Reading? { snapshot.map(MemoryReclaimer.Reading.init(snapshot:)) }

    private var bullets: [CareStudioBullet] {
        let pending = isLoading ? L10n.text("正在读取…", "Reading…") : "—"
        guard let snapshot else {
            return [
                CareStudioBullet(id: "memory.pressure", title: L10n.text("内存压力", "Memory Pressure"),
                                 systemImage: "gauge.with.dots.needle.33percent", detail: pending),
                CareStudioBullet(id: "memory.used", title: L10n.text("已用内存", "Memory Used"),
                                 systemImage: "memorychip", detail: pending),
                CareStudioBullet(id: "memory.cache", title: L10n.text("文件缓存", "Cached Files"),
                                 systemImage: "doc.on.doc", detail: pending)
            ]
        }
        return [
            CareStudioBullet(id: "memory.pressure", title: L10n.text("内存压力", "Memory Pressure"),
                             systemImage: "gauge.with.dots.needle.33percent",
                             detail: snapshot.reportablePressureLevel?.title ?? L10n.text("暂时读不到", "Unavailable")),
            CareStudioBullet(id: "memory.used", title: L10n.text("已用内存", "Memory Used"),
                             systemImage: "memorychip",
                             detail: L10n.text("\(ByteFormat.memoryString(snapshot.usedBytes)) / 共 \(ByteFormat.memoryString(snapshot.physicalBytes))",
                                               "\(ByteFormat.memoryString(snapshot.usedBytes)) of \(ByteFormat.memoryString(snapshot.physicalBytes))")),
            CareStudioBullet(id: "memory.cache", title: L10n.text("文件缓存", "Cached Files"),
                             systemImage: "doc.on.doc",
                             detail: L10n.text("\(ByteFormat.memoryString(snapshot.cachedEstimateBytes)) · macOS 需要时会自行收回",
                                               "\(ByteFormat.memoryString(snapshot.cachedEstimateBytes)) · macOS takes it back when needed")),
            CareStudioBullet(id: "memory.swap", title: L10n.text("交换", "Swap Used"),
                             systemImage: "arrow.left.arrow.right",
                             detail: ByteFormat.memoryString(snapshot.swapUsedBytes))
        ]
    }

    private var status: String? {
        guard let reading else { return nil }
        if let level = reading.pressureLevelCode, level != 1 {
            return L10n.text("内存压力已升高：释放缓存帮不上忙，请退出占用多的应用。",
                             "Memory pressure is raised: freeing cache will not help; quit apps that use a lot of memory.")
        }
        let budget = MemoryReclaimer.budget(for: reading)
        guard budget > 0 else {
            return L10n.text("可收回的缓存不多，现在无需释放。", "There is little cache to hand back right now.")
        }
        return L10n.text("最多可让系统收回约 \(ByteFormat.memoryString(Int64(clamping: budget))) 缓存，不退出任何应用。",
                         "Up to about \(ByteFormat.memoryString(Int64(clamping: budget))) of cache can be handed back, without quitting any app.")
    }

    var body: some View {
        CareStudioLandingPage(
            module: .memory,
            title: L10n.text("内存管理", "Memory"),
            subtitle: L10n.text("让系统收回可以直接丢弃的文件缓存和可清除内存，或退出不需要的应用。",
                                "Have the system hand back file cache and purgeable memory it can drop, or quit apps you don't need."),
            bullets: bullets,
            status: status,
            footnote: L10n.text("不退出应用 · 不执行 purge · 前后数字均为实测",
                                "Quits no app · No purge · Before and after are measured"),
            actionTitle: L10n.text("释放", "Free Up"),
            actionEnabled: canFreeUp && snapshot != nil,
            action: onFreeUp
        ) {
            CareStudioPillButton(title: L10n.text("查看占用最多的应用", "View Top Consumers"),
                                 systemImage: "list.bullet", action: onShowApps)
        }
    }
}

/// While the push runs: the picture working and Stop (no confirmation; the
/// memory is returned at once).
struct CareStudioMemoryRunning: View {
    let onStop: () -> Void

    var body: some View {
        CareStudioRunningPage(
            module: .memory,
            title: L10n.text("正在释放内存…", "Freeing Up Memory…"),
            detail: L10n.text("正在让系统收回文件缓存和可清除内存。", "Asking the system to hand back file cache and purgeable memory."),
            footnote: L10n.text("压缩内存一增长或压力一升高就立即停止", "Stops as soon as the compressor grows or pressure rises"),
            onStop: onStop)
    }
}

/// The result, as measured: idle memory before and after, the cache handed
/// back, the compressor and pressure. CleanMyMac shows only "RAM Freed Up";
/// we show the numbers and say that macOS already counted the cache as
/// available.
struct CareStudioMemoryResultPage: View {
    let result: MemoryOptimizationResult
    let reclaim: MemoryReclaimer.Outcome
    let onDone: () -> Void
    let onShowApps: () -> Void
    /// D154 batch 3P: the gain counts up once, here and not in the column,
    /// which a relayout rebuilds.
    @State private var counted = false

    private var gained: Int64? { reclaim.idleDeltaBytes }

    private var title: String {
        switch reclaim.stopReason {
        case .pressureAlreadyRaised: L10n.text("内存压力已升高", "Memory Pressure Is Raised")
        case .nothingToReclaim: L10n.text("无需释放", "Nothing to Free Up")
        case .cancelled: L10n.text("已取消", "Cancelled")
        default:
            (gained ?? 0) > 0 ? L10n.text("空闲内存已增加", "Idle Memory Increased")
                : L10n.text("已请求系统收回缓存", "Cache Hand-back Requested")
        }
    }

    private var showsSuccess: Bool {
        switch reclaim.stopReason {
        case .finished, .compressorGrowing, .pressureRose: (gained ?? 0) > 0
        default: false
        }
    }

    var body: some View {
        CareStudioPageFrame(module: .memory,
                            footnote: L10n.text("macOS 会把空闲内存再用作缓存；缓存本来就算作可用内存",
                                                "macOS reuses idle memory as cache; cache already counts as available")) {
            GeometryReader { proxy in
                // Scrolls only when the numbers do not fit (a short window).
                ViewThatFits(in: .vertical) {
                    column(height: proxy.size.height)
                    ScrollView { column(height: proxy.size.height) }
                        .scrollIndicators(.hidden)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .onAppear { counted = true }
        } action: {
            CareStudioActionButton(module: .memory, title: L10n.text("完成", "Done"), action: onDone)
                .keyboardShortcut(.defaultAction)
        }
#if DEBUG
        .layoutProbe("careStudio.memory.result")
#endif
    }

    private func column(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            if height < Self.compactHeight {
                // A short window puts the picture beside the title, so the
                // numbers stay above the round button without scrolling.
                HStack(alignment: .center, spacing: 18) {
                    CareStudioArt(module: .memory, side: 96, showsSuccess: showsSuccess)
                    headline(alignment: .leading)
                }
            } else {
                CareStudioArt(module: .memory, side: max(96, min(170, height * 0.24)), showsSuccess: showsSuccess)
                headline(alignment: .center)
                    .padding(.top, 10)
            }
            Text(result.detail)
                .font(.system(size: 14))
                .foregroundStyle(CareStudioInk.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560)
                .padding(.top, 10)
            measures
                .padding(.top, 16)
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    /// Below this page height the picture moves beside the title.
    private static let compactHeight: CGFloat = 460

    private func headline(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(title)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(CareStudioInk.primary)
                .multilineTextAlignment(alignment == .leading ? .leading : .center)
                .accessibilityAddTraits(.isHeader)
            if showsSuccess, let gained {
                CareStudioCountingText("+\(ByteFormat.memoryString(gained))", counted: counted,
                                       alignment: Alignment(horizontal: alignment, vertical: .center),
                                       delay: CareStudioMotion.countAfterSuccess)
                    .font(.system(size: 34, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(CareStudioInk.primary)
                    .padding(.top, 6)
                Text(L10n.text("空闲内存，来自文件缓存和可清除内存", "idle memory, from file cache and purgeable memory"))
                    .font(.system(size: 13))
                    .foregroundStyle(CareStudioInk.secondary)
            }
        }
    }

    /// D166: the measured numbers as small cards with the module's objects —
    /// idle memory (and the cache it came from), pressure (and the time),
    /// the compressor — and the way to the top consumers. Two columns where
    /// the numbers fit on one line, one column in a narrow window; without a
    /// push only the last card is shown.
    @ViewBuilder private var measures: some View {
        if let after = reclaim.after, reclaim.pushedBytes > 0 {
            let cards = measureCards(after: after)
            ViewThatFits(in: .horizontal) {
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow { cards[0]; cards[1] }
                    GridRow { cards[2]; cards[3] }
                }
                VStack(spacing: 10) {
                    ForEach(Array(cards.enumerated()), id: \.offset) { $0.element }
                }
            }
            .frame(maxWidth: 520)
#if DEBUG
            .layoutProbe("careStudio.memory.measures")
#endif
        } else {
            topAppsCard
                .frame(maxWidth: 260)
        }
    }

    private func measureCards(after: MemoryReclaimer.Reading) -> [CareStudioMemoryMeasureCard] {
        let before = reclaim.before
        return [
            CareStudioMemoryMeasureCard(
                art: .tileFreeable, title: L10n.text("空闲内存", "Idle memory"),
                value: Self.change(before.idleBytes, after.idleBytes),
                detail: L10n.text("文件缓存 \(Self.change(before.cacheBytes, after.cacheBytes))",
                                  "Cached files \(Self.change(before.cacheBytes, after.cacheBytes))")),
            CareStudioMemoryMeasureCard(
                art: .tilePressure, title: L10n.text("内存压力", "Pressure"),
                value: "\(Self.pressureTitle(before.pressureLevelCode)) → \(Self.pressureTitle(after.pressureLevelCode))",
                detail: L10n.text(String(format: "用时 %.1f 秒", reclaim.duration),
                                  String(format: "Took %.1f s", reclaim.duration))),
            CareStudioMemoryMeasureCard(
                art: .tileProcesses, title: L10n.text("压缩内存", "Compressed"),
                value: Self.change(before.compressedBytes, after.compressedBytes),
                detail: nil),
            topAppsCard
        ]
    }

    private var topAppsCard: CareStudioMemoryMeasureCard {
        CareStudioMemoryMeasureCard(
            art: .tileTopApps, title: L10n.text("占用最多的应用", "Top Consumers"),
            value: nil,
            detail: L10n.text("退出前会先确认", "Asks before quitting"),
            action: onShowApps)
    }

    private static func change(_ before: UInt64, _ after: UInt64) -> String {
        "\(ByteFormat.memoryString(Int64(clamping: before))) → \(ByteFormat.memoryString(Int64(clamping: after)))"
    }

    private static func pressureTitle(_ code: Int32?) -> String {
        code.flatMap { MemoryPressureLevel(systemCode: Int($0)) }?.title ?? "—"
    }
}

/// One measured number of the memory result as a small card with its D166
/// object (CleanMyMac's result tiles, at the height of two table rows); with
/// an action the whole card is the button.
struct CareStudioMemoryMeasureCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let art: GeneratedArt
    let title: String
    let value: String?
    let detail: String?
    var action: (() -> Void)? = nil
    @State private var isHovered = false

    var body: some View {
        if let action {
            Button(action: action) { card(chevron: true) }
                .buttonStyle(CareStudioRowButtonStyle())
                .onHover { isHovered = $0 }
                .accessibilityLabel(title)
                .accessibilityHint(detail ?? "")
        } else {
            card(chevron: false)
                .accessibilityElement(children: .combine)
        }
    }

    private func card(chevron: Bool) -> some View {
        HStack(spacing: 10) {
            FeatureLightfieldArtwork(art: art, variant: .header)
                .hueRotation(CareStudioModule.memory.family.hueRotation(for: art))
                .frame(width: 42, height: 42)
                .shadow(color: CareStudioPalette.color(CareStudioModule.memory.palette.deep, opacity: 0.4), radius: 6, y: 4)
                // The object leans in under the pointer, as on the result tiles.
                .scaleEffect(isHovered && !reduceMotion ? 1.08 : 1)
                .rotationEffect(.degrees(isHovered && !reduceMotion ? -5 : 0))
                .animation(reduceMotion ? nil : CareStudioMotion.tileArrival, value: isHovered)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: value == nil ? 14 : 12, weight: value == nil ? .semibold : .regular))
                    .foregroundStyle(value == nil ? CareStudioInk.primary : CareStudioInk.secondary)
                    .lineLimit(1)
                if let value {
                    Text(value)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(CareStudioInk.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(CareStudioInk.tertiary)
                        .monospacedDigit()
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CareStudioInk.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: CareStudioMetrics.tileCorner, style: .continuous))
        .careStudioCard(isHovered: isHovered)
    }
}
