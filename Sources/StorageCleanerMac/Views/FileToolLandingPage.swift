import SwiftUI

/// A compact, adaptive landing page shared by file-oriented tools.
///
/// The scanner and its state stay owned by the feature Store. This view only
/// Initial-state composition; result pages keep their own complete data lists.
struct FileToolLandingPage<Accessory: View>: View {
    @Environment(\.moduleTheme) private var theme
    @Environment(\.windowLayoutMetrics) private var layout
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let subtitle: String
    let systemImage: String
    let configurationTitle: String?
    let actionTitle: String
    let actionDetail: String
    let actionSystemImage: String
    let status: ScanStatusPresentation
    let isLoading: Bool
    let isActionDisabled: Bool
    let trustText: String
    let action: () -> Void
    private let accessory: Accessory

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        configurationTitle: String?,
        actionTitle: String,
        actionDetail: String,
        actionSystemImage: String,
        status: ScanStatusPresentation,
        isLoading: Bool = false,
        isActionDisabled: Bool = false,
        trustText: String,
        action: @escaping () -> Void,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.configurationTitle = configurationTitle
        self.actionTitle = actionTitle
        self.actionDetail = actionDetail
        self.actionSystemImage = actionSystemImage
        self.status = status
        self.isLoading = isLoading
        self.isActionDisabled = isActionDisabled
        self.trustText = trustText
        self.action = action
        self.accessory = accessory()
    }

    var body: some View {
        GeometryReader { proxy in
            let profile = GoldenLandingMetrics.profile(for: systemImage)
            let isFileAnalysis = theme.featureGroup == .files
                && systemImage == AppSymbols.Navigation.fileAnalysis
            let innerInset = layout.density == .compact ? CGFloat(12) : GoldenLandingMetrics.innerInset
            let availableWidth = max(0, proxy.size.width - innerInset * 2)
            let hasArtworkColumn = availableWidth >= 620 && !isLoading
            let actionWidth = hasArtworkColumn
                ? max(340, min(isFileAnalysis ? 540 : 570, availableWidth * profile.actionFraction))
                : availableWidth

            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.large) {
                HStack(alignment: .top, spacing: profile.columnSpacing) {
                    VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
                        AppPageHeader(title: title, subtitle: subtitle, systemImage: systemImage, isHero: true) {
                            if isLoading {
                                FileToolLandingArtwork(systemImage: systemImage, tint: theme.accent,
                                    featureGroup: theme.featureGroup, workflowIsActive: true)
                                    .frame(width: 96, height: 96).accessibilityHidden(true)
                            }
                        }
#if DEBUG
                        .layoutProbe(LayoutProbeID.landingHeader)
#endif
                        configurationPanel
                            .frame(maxHeight: isLoading ? .infinity : 390)
                    }
                    .frame(width: actionWidth)
                    .frame(maxHeight: .infinity, alignment: .top)

                    if hasArtworkColumn {
                        FileToolLandingArtwork(
                            systemImage: systemImage,
                            tint: theme.accent,
                            featureGroup: theme.featureGroup,
                            workflowIsActive: isLoading
                        )
                        .scaleEffect(profile.artworkScale)
                        .overlay(alignment: .topTrailing) {
                            if systemImage == ReviewFilter.duplicates.systemImage {
                                GoldenUnmeasuredCapacity().padding(.top, 6)
                            }
                        }
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
#if DEBUG
                        .layoutProbe(LayoutProbeID.landingArtwork)
#endif
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)

                footer
            }
            .padding(.horizontal, innerInset)
            .padding(.top, layout.isShort ? 0 : GoldenLandingMetrics.topInset)
            .padding(.bottom, layout.isShort ? 12 : 24)
            .background {
                if theme.isImmersive {
                    RoundedRectangle(cornerRadius: AppDesignTokens.Radius.modulePanel)
                        .fill(theme.accent.opacity(0.018))
                        .overlay(RoundedRectangle(cornerRadius: AppDesignTokens.Radius.modulePanel)
                            .strokeBorder(.white.opacity(0.09), lineWidth: 0.75))
                }
            }
        }
        .padding(.horizontal, GoldenLandingMetrics.outerInset)
        .padding(.top, layout.isShort ? 0 : 6)
        .padding(.bottom, GoldenLandingMetrics.outerInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(theme.accent)
        .environment(\.colorScheme, theme.isImmersive ? .dark : colorScheme)
#if DEBUG
        .layoutProbe(LayoutProbeID.landingRoot)
#endif
    }

    private var configurationPanel: some View {
        ContentPanel {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if configurationTitle != nil || showsBuiltInScopeGrid {
                            Label(configurationTitle ?? defaultConfigurationTitle, systemImage: "slider.horizontal.3")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(theme.primaryText)
                            Divider().overlay(.white.opacity(0.06))
                            if showsBuiltInScopeGrid { builtInScopeGrid }
                            if configurationTitle != nil { accessory }
                        }
                        if !actionDetail.isEmpty {
                            Text(actionDetail)
                                .font(AppTypography.secondaryText)
                                .foregroundStyle(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.vertical, 4)
                }
                Divider().overlay(theme.accent.opacity(0.18))
                landingActionButton
            }
            .padding(layout.isShort ? 14 : 16)
        }
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
#if DEBUG
        .layoutProbe(LayoutProbeID.landingContent)
        .layoutProbe(LayoutProbeID.landingActionPanel)
#endif
    }

    private var landingActionButton: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Group {
                    if isLoading { ProgressView().controlSize(.small) }
                    else {
                        Image(systemName: actionSystemImage)
                            .font(.system(size: layout.isShort ? 23 : 29, weight: .medium))
                            .frame(width: layout.isShort ? 36 : 48, height: layout.isShort ? 36 : 48)
                            .background(.white.opacity(0.12), in: Circle())
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: layout.isShort ? 64 : 82)
                Rectangle().fill(.white.opacity(0.18)).frame(width: 1)
                Text(actionTitle)
                    .font(.system(size: layout.isShort ? 19 : 24, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, minHeight: layout.isShort ? 54 : 72)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.white)
            .background(
                LinearGradient(colors: [theme.accent, theme.accent.opacity(0.58)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: AppDesignTokens.Radius.modulePanel, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppDesignTokens.Radius.modulePanel, style: .continuous)
                    .strokeBorder(.white.opacity(0.32), lineWidth: 1)
            }
        }
        .buttonStyle(ResponsivePlainButtonStyle())
        .disabled(isActionDisabled || isLoading)
        .accessibilityLabel(actionTitle)
#if DEBUG
        .layoutProbe(LayoutProbeID.landingActionButton)
#endif
    }

    private var builtInScopeGrid: some View {
        let nodes = builtInScopeNodes
        let isUpdateSourceList = systemImage == ReviewFilter.updater.systemImage
        let isApplicationScope = systemImage == ReviewFilter.uninstall.systemImage
        let usesInlineNodes = isUpdateSourceList || isApplicationScope
        let columnCount = isUpdateSourceList ? 1 : (isApplicationScope ? 2 : (nodes.count == 3 ? 3 : min(4, max(1, nodes.count))))
        return LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: AppDesignTokens.Spacing.small),
                count: columnCount
            ),
            spacing: isUpdateSourceList ? 6 : AppDesignTokens.Spacing.small
        ) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { index, node in
                let nodeLayout = usesInlineNodes
                    ? AnyLayout(HStackLayout(alignment: .center, spacing: 12))
                    : AnyLayout(VStackLayout(alignment: .center, spacing: 6))
                nodeLayout {
                    Image(systemName: node.systemImage)
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: isUpdateSourceList ? 22 : (usesInlineNodes ? 24 : 32), weight: .regular))
                        .foregroundStyle(node.tint)
                        .frame(width: isUpdateSourceList ? 30 : (usesInlineNodes ? 38 : 52), height: isUpdateSourceList ? 30 : (usesInlineNodes ? 38 : 52))
                        .background(node.tint.opacity(0.14), in: RoundedRectangle(
                            cornerRadius: 10,
                            style: .continuous
                        ))
#if DEBUG
                        .layoutProbe(LayoutProbeID.landingScopeIcon(index))
#endif
                    VStack(alignment: usesInlineNodes ? .leading : .center, spacing: 4) {
                    Text(node.title)
                        .font(AppDesignTokens.Typography.compactLabelEmphasis)
                        .foregroundStyle(theme.primaryText)
                        .multilineTextAlignment(usesInlineNodes ? .leading : .center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: usesInlineNodes ? .leading : .center)
#if DEBUG
                        .layoutProbe(LayoutProbeID.landingScopeTitle(index))
#endif
                    if let detail = node.detail, !isUpdateSourceList {
                        Text(detail)
                            .font(AppDesignTokens.Typography.metadata)
                            .foregroundStyle(theme.secondaryText)
                            .multilineTextAlignment(usesInlineNodes ? .leading : .center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    }
                    .frame(maxWidth: .infinity, alignment: usesInlineNodes ? .leading : .center)
                }
                .padding(.horizontal, AppDesignTokens.Spacing.small)
                .padding(.vertical, usesInlineNodes ? 6 : AppDesignTokens.Spacing.small)
                .frame(maxWidth: .infinity, minHeight: isUpdateSourceList ? 42 : (usesInlineNodes ? 52 : 104))
                .help(node.detail ?? node.title)
                .background(theme.accent.opacity(0.055), in: RoundedRectangle(
                    cornerRadius: AppDesignTokens.Radius.glassControl,
                    style: .continuous
                ))
                .overlay {
                    RoundedRectangle(
                        cornerRadius: AppDesignTokens.Radius.glassControl,
                        style: .continuous
                    )
                    .strokeBorder(theme.accent.opacity(0.20), lineWidth: 1)
                }
#if DEBUG
                .layoutProbe(LayoutProbeID.landingScopeCard(index))
#endif
            }
        }
        .fixedSize(horizontal: false, vertical: usesInlineNodes)
    }

    private var builtInScopeNodes: [LandingArtworkNode] {
        FileToolLandingArtwork(
            systemImage: systemImage,
            tint: theme.accent,
            featureGroup: theme.featureGroup
        ).satelliteNodes
    }

    private var showsBuiltInScopeGrid: Bool {
        switch theme.featureGroup {
        case .cleanup:
            !(systemImage == ReviewFilter.green.systemImage && configurationTitle != nil)
        case .protection:
            configurationTitle == nil
        case .applications:
            true
        case .performance:
            systemImage != ReviewFilter.energy.systemImage
        case .smartScan, .files, .settings:
            false
        }
    }

    private var defaultConfigurationTitle: String {
        switch theme.featureGroup {
        case .smartScan:
            L10n.text("扫描内容", "Scan Contents")
        case .cleanup:
            L10n.text("选择要扫描的项目", "Choose Items to Scan")
        case .protection:
            L10n.text("检查范围", "Check Scope")
        case .performance:
            L10n.text("检测项目", "Inspection Items")
        case .applications:
            systemImage == ReviewFilter.updater.systemImage
                ? L10n.text("更新来源", "Update Sources")
                : L10n.text("扫描范围", "Scan Scope")
        case .files:
            L10n.text("文件范围", "File Scope")
        case .settings:
            L10n.text("设置内容", "Settings")
        }
    }

    private var footer: some View {
        ContentPanel {
            HStack(alignment: .center, spacing: AppDesignTokens.Spacing.large) {
                HStack(spacing: 14) {
                    Image(systemName: status.systemImage)
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(theme.accent)
                        .frame(width: GoldenLandingMetrics.statusIconSize, height: GoldenLandingMetrics.statusIconSize)
                        .overlay(Circle().strokeBorder(theme.accent.opacity(0.55), lineWidth: 2))
                        .accessibilityHidden(true)
                    Text(status.title)
                        .font(.system(size: 15))
                        .foregroundStyle(statusTint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !trustText.isEmpty {
                    Divider().frame(height: 30)
                    Label(trustText, systemImage: "checkmark.shield")
                        .font(AppTypography.body)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 38)
            .padding(.horizontal, 20)
            .padding(.vertical, layout.isShort ? 12 : 18)
        }
#if DEBUG
        .layoutProbe(LayoutProbeID.landingFooter)
#endif
    }

    private var statusTint: Color {
        switch status {
        case .completed:
            AppDesignTokens.Palette.success
        case .failed, .expired:
            AppDesignTokens.Palette.warning
        case .scanning:
            theme.accent
        case .idle, .neverScanned:
            theme.secondaryText
        }
    }
}

struct FileToolLandingArtwork: View {
    let systemImage: String
    let tint: Color
    let featureGroup: FeatureGroup
    var isCompact = false
    var workflowIsActive = false
    @Environment(\.moduleTheme) private var theme

    private static let safeCleanupArtwork: NSImage? = Bundle.main.url(
        forResource: "LandingArtwork-SafeCleanup-v1", withExtension: "png"
    ).flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        GeometryReader { proxy in
            let points = Array(satellitePoints(in: proxy.size).prefix(satelliteNodes.count))
            let center = artworkCenter(in: proxy.size)

            ZStack {
                if systemImage == ReviewFilter.green.systemImage, !isCompact,
                   let artwork = Self.safeCleanupArtwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        // Non-data artwork only. Screen compositing removes the black asset backdrop.
                        .blendMode(.screen)
                } else if systemImage == ReviewFilter.uninstall.systemImage, !isCompact,
                          theme.isImmersive, let image = GoldenLandingAsset.uninstall.image {
                    GoldenLandingArtwork(image: image)
                } else if systemImage == ReviewFilter.updater.systemImage, !isCompact,
                          theme.isImmersive, let image = GoldenLandingAsset.appUpdates.image {
                    GoldenLandingArtwork(image: image)
                } else if systemImage == ReviewFilter.privacy.systemImage, !isCompact {
                    PrivacyConceptArtwork(tint: tint)
                } else if featureGroup == .files && systemImage == ReviewFilter.duplicates.systemImage && !isCompact {
                    if theme.isImmersive, let image = GoldenLandingAsset.duplicateFiles.image {
                        GoldenLandingArtwork(image: image)
                    } else {
                        DuplicatePairsArtwork(tint: tint)
                    }
                } else if featureGroup == .smartScan && !isCompact,
                          theme.isImmersive, let image = GoldenLandingAsset.smartScan.image {
                    GoldenLandingArtwork(image: image)
                } else if featureGroup == .files && systemImage == ReviewFilter.migration.systemImage && !isCompact {
                    if theme.isImmersive, let image = GoldenLandingAsset.migrationFlow.image {
                        GoldenWorkflowArtwork(image: image, kind: .migration)
                    } else {
                        MigrationFlowArtwork(tint: tint)
                    }
                } else if isDeveloperArtifactsArtwork && !isCompact {
                    if theme.isImmersive, let image = GoldenLandingAsset.developerArtifacts.image {
                        GoldenLandingArtwork(image: image)
                    } else {
                        DeveloperArtifactsConceptArtwork(tint: tint)
                    }
                } else if isHealthArtwork && !isCompact {
                    if theme.isImmersive, let image = GoldenLandingAsset.health.image {
                        GoldenHealthArtwork(image: image, tint: tint)
                    } else { HealthConceptArtwork(tint: tint) }
                } else if systemImage == ReviewFilter.startup.systemImage, !isCompact,
                          theme.isImmersive, let image = GoldenLandingAsset.startup.image {
                    GoldenLandingArtwork(image: image)
                } else if isEnergyArtwork && !isCompact {
                    if theme.isImmersive, let image = GoldenLandingAsset.energyFlow.image {
                        GoldenWorkflowArtwork(image: image, kind: .energy, isMeasuring: workflowIsActive)
                    } else {
                        EnergyConceptArtwork(tint: tint)
                    }
                } else if isFileAnalysisArtwork && !isCompact {
                    FileAnalysisDirectoryArtwork(tint: tint)

                } else {
                    Canvas { context, _ in
                        for radius in orbitRadii(in: proxy.size) {
                            let rect = CGRect(
                                x: center.x - radius,
                                y: center.y - radius,
                                width: radius * 2,
                                height: radius * 2
                            )
                            context.stroke(
                                Path(ellipseIn: rect),
                                with: .color(tint.opacity(0.14)),
                                lineWidth: 1
                            )
                        }

                        for point in points {
                            var path = Path()
                            path.move(to: center)
                            path.addLine(to: point)
                            context.stroke(
                                path,
                                with: .color(tint.opacity(0.48)),
                                style: StrokeStyle(lineWidth: 1.5, dash: [5, 6])
                            )
                        }

                        for dot in ambientDots(in: proxy.size) {
                            context.fill(
                                Path(ellipseIn: CGRect(
                                    x: dot.x - 2,
                                    y: dot.y - 2,
                                    width: 4,
                                    height: 4
                                )),
                                with: .color(tint.opacity(0.72))
                            )
                        }
                    }

                    ForEach(Array(satelliteNodes.enumerated()), id: \.offset) { index, node in
                        satellite(node)
                            .position(points[index])
                    }

                    ZStack {
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [tint.opacity(0.62), tint.opacity(0.16), Color.black.opacity(0.48)],
                                    center: .topLeading,
                                    startRadius: 4,
                                    endRadius: isCompact ? 58 : 92
                                )
                            )
                        Circle()
                            .strokeBorder(tint.opacity(0.64), lineWidth: 2)
                        Circle()
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                            .padding(isCompact ? 8 : 12)
                        if featureGroup == .smartScan {
                            RadarScanArtwork(tint: tint)
                                .padding(12)
                        } else {
                            Image(systemName: systemImage)
                                .symbolRenderingMode(.hierarchical)
                                .font(.system(size: isCompact ? 30 : 48, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.96))
                        }
                    }
                    .frame(width: isCompact ? 74 : (featureGroup == .smartScan ? 220 : 158), height: isCompact ? 74 : (featureGroup == .smartScan ? 220 : 158))
                    .shadow(color: tint.opacity(0.34), radius: 28)
                    .position(center)
                }
            }
        }
        .accessibilityHidden(true)
    }

    fileprivate var satelliteNodes: [LandingArtworkNode] {
        switch featureGroup {
        case .smartScan:
            return [
                node("trash.fill", L10n.text("可清理", "Cleanup"), .blue),
                node("doc.text.fill", L10n.text("需复核", "Review"), .purple),
                node("checkmark.shield.fill", L10n.text("健康状态", "Health"), .mint),
            ]
        case .cleanup:
            return isDeveloperArtifactsArtwork
                ? [
                    node("chevron.left.forwardslash.chevron.right", L10n.text("代码工程", "Projects"), .orange),
                    node("terminal.fill", L10n.text("Agent", "Agents"), .purple),
                    node("bubble.left.and.bubble.right.fill", L10n.text("会话", "Sessions"), .cyan),
                    node("internaldrive.fill", L10n.text("产物", "Artifacts"), .green),
                ]
                : [
                    node("internaldrive.fill", L10n.text("缓存", "Caches"), .orange),
                    node("doc.text.fill", L10n.text("日志", "Logs"), .yellow),
                    node("clock.fill", L10n.text("临时文件", "Temporary"), .pink),
                    node("arrow.down.circle.fill", L10n.text("下载项", "Downloads"), .blue),
                ]
        case .protection:
            if systemImage == ReviewFilter.healthHub.systemImage {
                return [
                    node("internaldrive.fill", L10n.text("磁盘", "Disk"), .mint, detail: L10n.text("健康状态、容量与错误记录", "Health, capacity, and errors")),
                    node("battery.75", L10n.text("电池", "Battery"), .green, detail: L10n.text("健康容量、循环与供电状态", "Capacity, cycles, and power source")),
                    node("waveform.path.ecg", L10n.text("稳定性", "Stability"), .cyan, detail: L10n.text("温度与关键系统状态", "Thermals and key system state")),
                ]
            }
            return [
                node("lock.shield.fill", L10n.text("隐私", "Privacy"), .green),
                node("globe", L10n.text("网站", "Websites"), .mint),
                node("clock.fill", L10n.text("时间", "Timeline"), .cyan),
                node("trash.fill", L10n.text("确认", "Review"), .teal),
            ]
        case .performance:
            if systemImage == ReviewFilter.startup.systemImage {
                return [
                    node("app.badge", L10n.text("登录项", "Login Items"), .pink),
                    node("bolt.horizontal.circle.fill", L10n.text("后台项", "Background"), .purple),
                    node("gearshape.2.fill", L10n.text("代理", "Agents"), .orange),
                    node("shield.fill", L10n.text("系统项", "System"), .cyan),
                ]
            }
            if systemImage == ReviewFilter.memory.systemImage {
                return [
                    node("memorychip.fill", L10n.text("内存", "Memory"), .purple),
                    node("app.fill", L10n.text("应用", "Apps"), .pink),
                    node("gauge.with.dots.needle.67percent", L10n.text("压力", "Pressure"), .orange),
                    node("arrow.left.arrow.right", L10n.text("交换", "Swap"), .cyan),
                ]
            }
            if systemImage == ReviewFilter.energy.systemImage {
                return [
                    node("bolt.fill", L10n.text("能耗", "Energy"), .pink),
                    node("battery.75", L10n.text("续航", "Battery"), .purple),
                    node("thermometer.medium", L10n.text("发热", "Thermals"), .orange),
                    node("moon.zzz.fill", L10n.text("后台", "Background"), .cyan),
                ]
            }
            return [
                node("cpu.fill", L10n.text("处理器", "CPU"), .pink),
                node("rectangle.3.group.fill", L10n.text("图形", "Graphics"), .purple),
                node("play.rectangle.fill", L10n.text("媒体", "Media"), .orange),
                node("waveform.path.ecg", L10n.text("持续性能", "Sustained"), .cyan),
            ]
        case .applications:
            if systemImage == ReviewFilter.updater.systemImage {
                return [
                    node("bag.fill", L10n.text("App Store", "App Store"), .cyan, detail: L10n.text("由系统商店管理的应用", "Apps managed by the system store")),
                    node("arrow.triangle.2.circlepath", L10n.text("Sparkle", "Sparkle"), .purple, detail: L10n.text("读取应用提供的更新源", "Read the app-provided update feed")),
                    node("globe", L10n.text("官网", "Website"), .teal, detail: L10n.text("检查可识别的官方版本信息", "Check recognized official version information")),
                    node("shippingbox.fill", L10n.text("Homebrew", "Homebrew"), .blue, detail: L10n.text("检查已安装的软件包来源", "Check installed package sources")),
                ]
            }
            return [
                node("app.fill", L10n.text("应用", "Apps"), .cyan),
                node("folder.fill", L10n.text("关联文件", "Related"), .blue),
                node("doc.fill", L10n.text("支持文件", "Support"), .teal),
                node("shippingbox.fill", L10n.text("容器", "Containers"), .mint),
            ]
        case .files:
            if systemImage == ReviewFilter.migration.systemImage {
                return [
                    node("folder.fill", L10n.text("来源", "Source"), .purple),
                    node("checkmark.shield.fill", L10n.text("验证", "Verify"), .cyan),
                    node("arrow.right", L10n.text("搬移", "Move"), .mint),
                    node("externaldrive.fill", L10n.text("目标", "Destination"), .orange),
                ]
            }
            if systemImage == ReviewFilter.duplicates.systemImage {
                return [
                    node("doc.on.doc.fill", L10n.text("文档", "Documents"), .purple),
                    node("photo.on.rectangle.angled", L10n.text("照片", "Photos"), .pink),
                    node("video.fill", L10n.text("视频", "Videos"), .blue),
                    node("waveform", L10n.text("音频", "Audio"), .orange),
                ]
            }
            return [
                node("doc.fill", L10n.text("文档", "Documents"), .blue),
                node("photo.fill", L10n.text("图像", "Images"), .pink),
                node("archivebox.fill", L10n.text("归档", "Archives"), .orange),
                node("puzzlepiece.fill", L10n.text("其他", "Other"), .green),
            ]
        case .settings:
            return [
                node("gearshape.fill", L10n.text("通用", "General"), .gray),
                node("paintpalette.fill", L10n.text("外观", "Appearance"), .purple),
                node("bell.fill", L10n.text("通知", "Alerts"), .orange),
                node("arrow.up.circle.fill", L10n.text("更新", "Updates"), .blue),
            ]
        }
    }

    private func satellite(_ node: LandingArtworkNode) -> some View {
        VStack(spacing: 5) {
            ZStack {
                if usesRoundedSatelliteTiles {
                    RoundedRectangle(cornerRadius: isCompact ? 12 : 18, style: .continuous)
                        .fill(node.tint.opacity(0.22))
                    RoundedRectangle(cornerRadius: isCompact ? 12 : 18, style: .continuous)
                        .strokeBorder(node.tint.opacity(0.66), lineWidth: 1)
                } else {
                    Circle()
                        .fill(node.tint.opacity(0.22))
                    Circle()
                        .strokeBorder(node.tint.opacity(0.66), lineWidth: 1)
                }

                Image(systemName: node.systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: isCompact ? 17 : 28, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.94))
            }
            .frame(width: isCompact ? 44 : 90, height: isCompact ? 44 : 90)
            .shadow(color: node.tint.opacity(0.24), radius: 12)

            if !isCompact {
                Text(node.title)
                    .font(AppDesignTokens.Typography.metadata.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private func node(_ systemImage: String, _ title: String, _ tint: Color, detail: String? = nil) -> LandingArtworkNode {
        LandingArtworkNode(systemImage: systemImage, title: title, tint: tint, detail: detail)
    }

    private func ambientDots(in size: CGSize) -> [CGPoint] {
        [
            CGPoint(x: size.width * 0.11, y: size.height * 0.18),
            CGPoint(x: size.width * 0.32, y: size.height * 0.09),
            CGPoint(x: size.width * 0.71, y: size.height * 0.12),
            CGPoint(x: size.width * 0.91, y: size.height * 0.36),
            CGPoint(x: size.width * 0.86, y: size.height * 0.82),
            CGPoint(x: size.width * 0.58, y: size.height * 0.91),
            CGPoint(x: size.width * 0.18, y: size.height * 0.84),
        ]
    }

    private func satellitePoints(in size: CGSize) -> [CGPoint] {
        if isCompact {
            return [
                CGPoint(x: size.width * 0.16, y: size.height * 0.50),
                CGPoint(x: size.width * 0.38, y: size.height * 0.20),
                CGPoint(x: size.width * 0.68, y: size.height * 0.20),
                CGPoint(x: size.width * 0.86, y: size.height * 0.52),
            ]
        }

        if satelliteNodes.count == 3 {
            return [
                CGPoint(x: size.width * 0.20, y: size.height * 0.24),
                CGPoint(x: size.width * 0.80, y: size.height * 0.24),
                CGPoint(x: size.width * 0.52, y: size.height * 0.80),
            ]
        }

        return [
            CGPoint(x: size.width * 0.20, y: size.height * 0.24),
            CGPoint(x: size.width * 0.80, y: size.height * 0.24),
            CGPoint(x: size.width * 0.20, y: size.height * 0.76),
            CGPoint(x: size.width * 0.80, y: size.height * 0.76),
        ]
    }

    private func artworkCenter(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width * 0.50, y: size.height * 0.50)
    }

    private var isDeveloperArtifactsArtwork: Bool {
        featureGroup == .cleanup
            && systemImage == AppSymbols.Navigation.developerArtifacts
    }

    private var isFileAnalysisArtwork: Bool {
        featureGroup == .files
            && systemImage == AppSymbols.Navigation.fileAnalysis
    }

    private var isHealthArtwork: Bool {
        featureGroup == .protection
            && systemImage == ReviewFilter.healthHub.systemImage
    }

    private var isEnergyArtwork: Bool {
        featureGroup == .performance
            && systemImage == ReviewFilter.energy.systemImage
    }

    private var usesRoundedSatelliteTiles: Bool {
        featureGroup == .cleanup || featureGroup == .applications
    }

    private func orbitRadii(in size: CGSize) -> [CGFloat] {
        let base = min(size.width, size.height)
        return isCompact
            ? [base * 0.28, base * 0.43]
            : [base * 0.22, base * 0.36, base * 0.49]
    }
}

private struct DeveloperArtifactsConceptArtwork: View {
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let center = CGPoint(x: size.width * 0.50, y: size.height * 0.52)

            ZStack {
                Canvas { context, _ in
                    for radius in [size.height * 0.20, size.height * 0.32, size.height * 0.44] {
                        context.stroke(
                            Path(ellipseIn: CGRect(
                                x: center.x - radius,
                                y: center.y - radius,
                                width: radius * 2,
                                height: radius * 2
                            )),
                            with: .color(tint.opacity(0.13)),
                            lineWidth: 1
                        )
                    }

                    for point in developerPoints(in: size) {
                        var path = Path()
                        path.move(to: center)
                        path.addCurve(
                            to: point,
                            control1: CGPoint(x: center.x, y: point.y),
                            control2: CGPoint(x: point.x, y: center.y)
                        )
                        context.stroke(
                            path,
                            with: .color(tint.opacity(0.58)),
                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 6])
                        )
                    }
                }

                DeveloperMiniWindow(
                    symbol: "folder.badge.gearshape",
                    title: "src / components",
                    detail: "index.swift",
                    tint: AppDesignTokens.Palette.technicalLine
                )
                .frame(width: size.width * 0.34, height: size.height * 0.20)
                .position(x: size.width * 0.34, y: size.height * 0.18)

                DeveloperMiniWindow(
                    symbol: "point.3.connected.trianglepath.dotted",
                    title: "main · feat/ui",
                    detail: "fix/cache · docs",
                    tint: AppDesignTokens.Palette.diagnostic
                )
                .frame(width: size.width * 0.31, height: size.height * 0.19)
                .position(x: size.width * 0.77, y: size.height * 0.35)

                DeveloperMiniWindow(
                    symbol: "terminal.fill",
                    title: "$ pnpm build",
                    detail: L10n.text("构建产物示意", "Build artifacts illustration"),
                    tint: AppDesignTokens.Palette.success
                )
                .frame(width: size.width * 0.34, height: size.height * 0.20)
                .position(x: size.width * 0.69, y: size.height * 0.76)

                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.52), Color.black.opacity(0.62)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(tint.opacity(0.72), lineWidth: 1.5)
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 128, height: 128)
                .shadow(color: tint.opacity(0.42), radius: 28)
                .position(center)

                Image(systemName: "ellipsis.message.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(AppDesignTokens.Palette.diagnostic)
                    .padding(18)
                    .background(AppDesignTokens.Palette.diagnostic.opacity(0.14), in: Circle())
                    .position(x: size.width * 0.20, y: size.height * 0.67)
            }
        }
    }

    private func developerPoints(in size: CGSize) -> [CGPoint] {
        [
            CGPoint(x: size.width * 0.34, y: size.height * 0.18),
            CGPoint(x: size.width * 0.77, y: size.height * 0.35),
            CGPoint(x: size.width * 0.69, y: size.height * 0.76),
            CGPoint(x: size.width * 0.20, y: size.height * 0.67),
        ]
    }
}

private struct DeveloperMiniWindow: View {
    let symbol: String
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(index == 0 ? tint : Color.white.opacity(0.25))
                        .frame(width: 6, height: 6)
                }
                Spacer()
                Image(systemName: symbol)
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(AppDesignTokens.Typography.metadata.weight(.semibold))
                .foregroundStyle(.white)
            Text(detail)
                .font(AppDesignTokens.Typography.caption.monospaced())
                .foregroundStyle(tint.opacity(0.90))
        }
        .padding(12)
        .background(Color.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.28), radius: 12, y: 6)
    }
}

private struct HealthConceptArtwork: View {
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let center = CGPoint(x: size.width * 0.38, y: size.height * 0.53)
            let ringSize = min(size.width, size.height) * 0.52

            ZStack {
                ForEach([CGFloat(1.20), 1.65, 2.05], id: \.self) { scale in
                    Circle()
                        .stroke(tint.opacity(0.12), lineWidth: 1)
                        .frame(width: ringSize * scale, height: ringSize * scale)
                        .position(center)
                }

                Circle()
                    .stroke(LinearGradient(colors: [tint, .cyan.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 10)
                    .frame(width: ringSize, height: ringSize)
                    .position(center)
                Path { path in
                    for target in [CGPoint(x: size.width * 0.78, y: size.height * 0.25),
                                   CGPoint(x: size.width * 0.83, y: size.height * 0.53),
                                   CGPoint(x: size.width * 0.78, y: size.height * 0.80)] {
                        path.move(to: CGPoint(x: center.x + ringSize * 0.49, y: center.y))
                        path.addLine(to: CGPoint(x: size.width * 0.64, y: target.y))
                        path.addLine(to: target)
                    }
                }
                .stroke(tint.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))

                VStack(spacing: 8) {
                    Text(L10n.text("尚未测量", "Not measured"))
                        .font(AppDesignTokens.Typography.cardTitle)
                        .foregroundStyle(.white.opacity(0.84))
                    Capsule()
                        .fill(Color.white.opacity(0.88))
                        .frame(width: 38, height: 5)
                }
                .position(center)

                HealthSatellite(symbol: "internaldrive.fill", tint: AppDesignTokens.Palette.technicalLine)
                    .position(x: size.width * 0.82, y: size.height * 0.22)
                HealthSatellite(symbol: "battery.75", tint: AppDesignTokens.Palette.caution)
                    .position(x: size.width * 0.88, y: size.height * 0.52)
                HealthSatellite(symbol: "waveform.path.ecg", tint: AppDesignTokens.Palette.information)
                    .position(x: size.width * 0.79, y: size.height * 0.80)
            }
        }
    }
}

private struct HealthSatellite: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: 38, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 90, height: 90)
            .background(Color.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(tint.opacity(0.58), lineWidth: 1)
            }
            .shadow(color: tint.opacity(0.24), radius: 16)
    }
}

private struct EnergyConceptArtwork: View {
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let left = CGPoint(x: size.width * 0.16, y: size.height * 0.52)
            let right = CGPoint(x: size.width * 0.84, y: size.height * 0.52)
            let middlePoints = [
                CGPoint(x: size.width * 0.52, y: size.height * 0.25),
                CGPoint(x: size.width * 0.52, y: size.height * 0.52),
                CGPoint(x: size.width * 0.52, y: size.height * 0.79),
            ]

            ZStack {
                Canvas { context, _ in
                    for (index, point) in middlePoints.enumerated() {
                        var first = Path()
                        first.move(to: left)
                        first.addCurve(
                            to: point,
                            control1: CGPoint(x: size.width * 0.30, y: left.y),
                            control2: CGPoint(x: size.width * 0.38, y: point.y)
                        )
                        context.stroke(first, with: .color(energyColor(index)), lineWidth: 2.4)

                        var second = Path()
                        second.move(to: point)
                        second.addCurve(
                            to: right,
                            control1: CGPoint(x: size.width * 0.66, y: point.y),
                            control2: CGPoint(x: size.width * 0.72, y: right.y)
                        )
                        context.stroke(second, with: .color(energyColor(index)), lineWidth: 2.4)
                    }
                }

                EnergyNode(symbol: "powerplug.fill", tint: AppDesignTokens.Palette.diagnostic)
                    .position(left)
                EnergyNode(symbol: "fan.fill", tint: AppDesignTokens.Palette.technicalLine)
                    .position(right)
                EnergyNode(symbol: "cpu.fill", tint: AppDesignTokens.Palette.sensitive)
                    .position(middlePoints[0])
                EnergyNode(symbol: "battery.75", tint: AppDesignTokens.Palette.warning)
                    .position(middlePoints[1])
                EnergyNode(symbol: "thermometer.medium", tint: AppDesignTokens.Palette.sensitive)
                    .position(middlePoints[2])
            }
        }
    }

    private func energyColor(_ index: Int) -> Color {
        switch index {
        case 0: .pink
        case 1: AppDesignTokens.Palette.warning
        default: tint
        }
    }
}

private struct EnergyNode: View {
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 78, height: 78)
                .background(Color.black.opacity(0.30), in: Circle())
                .overlay { Circle().strokeBorder(tint.opacity(0.55), lineWidth: 1) }
            Text(L10n.text("尚未测量", "Not measured"))
                .font(AppDesignTokens.Typography.caption)
                .foregroundStyle(.white.opacity(0.58))
        }
    }
}

private struct FileAnalysisDirectoryArtwork: View {
    let tint: Color

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 16) {
                Image(systemName: "internaldrive")
                Image(systemName: "chevron.right").font(AppDesignTokens.Typography.metadata)
                Image(systemName: "folder.fill")
            }
            .font(.system(size: 24, weight: .regular))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height) * 0.87
                ZStack {
                    // Neutral, unsegmented tracks denote an empty chart, never byte proportions.
                    ForEach([CGFloat(0.56), 0.72, 0.88, 1], id: \.self) { scale in
                        Circle().stroke(.white.opacity(0.06), lineWidth: side * 0.058)
                            .frame(width: side * scale, height: side * scale)
                    }
                    VStack(spacing: 14) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: side * 0.17, weight: .regular))
                            .foregroundStyle(LinearGradient(colors: [.cyan, .blue], startPoint: .top, endPoint: .bottom))
                        Text(L10n.text("尚未分析", "Not analyzed"))
                            .font(AppDesignTokens.Typography.compactLabel)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(L10n.text("分析后按实际容量展开", "Analyze to show measured sizes"))
                .font(AppDesignTokens.Typography.metadata).foregroundStyle(.secondary)
        }
        .padding(22)
        .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12)))
        .padding(.vertical, 28)
    }
}

private struct LandingArtworkNode {
    let systemImage: String
    let title: String
    let tint: Color
    var detail: String? = nil
}

/// Initial-page illustration only: paired objects describe the operation,
/// never a discovered duplicate count or a completed scan.
private struct DuplicatePairsArtwork: View {
    let tint: Color
    private let symbols = ["doc.text.fill", "photo.fill", "video.fill", "music.note"]
    private let colors: [Color] = [.blue, .orange, .cyan, .purple]
    private var titles: [String] {
        [L10n.text("文档", "Documents"), L10n.text("照片", "Photos"),
         L10n.text("视频", "Videos"), L10n.text("音频", "Audio")]
    }

    var body: some View {
        GeometryReader { proxy in
            let positions = [CGPoint(x: 0.26, y: 0.25), CGPoint(x: 0.74, y: 0.25),
                             CGPoint(x: 0.26, y: 0.75), CGPoint(x: 0.74, y: 0.75)]
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            ZStack {
                Canvas { context, size in
                    for point in positions {
                        var line = Path()
                        line.move(to: center)
                        line.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
                        context.stroke(line, with: .color(tint.opacity(0.5)),
                                       style: StrokeStyle(lineWidth: 2, dash: [3, 5]))
                    }
                }
                Image(systemName: "link")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 72, height: 72)
                    .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 20))
                    .position(center)
                ForEach(0..<4, id: \.self) { index in
                    VStack(spacing: 14) {
                        ZStack {
                            paper(index)
                                .rotationEffect(.degrees(-12))
                                .offset(x: -19, y: -9)
                            paper(index)
                                .rotationEffect(.degrees(8))
                                .offset(x: 17, y: 8)
                        }
                        Text(titles[index])
                            .font(AppDesignTokens.Typography.compactLabelEmphasis)
                            .foregroundStyle(.secondary)
                    }
                    .position(x: positions[index].x * proxy.size.width,
                              y: positions[index].y * proxy.size.height)
                }
            }
        }
    }

    private func paper(_ index: Int) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbols[index])
                .font(.system(size: 27, weight: .medium))
            RoundedRectangle(cornerRadius: 2).frame(width: 40, height: 3).opacity(0.5)
            RoundedRectangle(cornerRadius: 2).frame(width: 30, height: 3).opacity(0.3)
        }
        .foregroundStyle(colors[index])
        .frame(width: 76, height: 100)
        .background(LinearGradient(colors: [.white.opacity(0.96), colors[index].opacity(0.55)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 9))
        .overlay(alignment: .topTrailing) {
            Image(systemName: "triangle.fill")
                .font(.system(size: 15)).rotationEffect(.degrees(180))
                .foregroundStyle(colors[index].opacity(0.55)).padding(3)
        }
        .shadow(color: .black.opacity(0.35), radius: 10, x: 3, y: 7)
    }
}

private struct RadarScanArtwork: View {
    let tint: Color
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2
            for fraction in [0.25, 0.5, 0.75, 1.0] {
                let r = radius * fraction
                context.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r,
                                                       width: r * 2, height: r * 2)),
                               with: .color(tint.opacity(0.7)), lineWidth: 1)
            }
            var axes = Path()
            axes.move(to: CGPoint(x: center.x, y: 0)); axes.addLine(to: CGPoint(x: center.x, y: size.height))
            axes.move(to: CGPoint(x: 0, y: center.y)); axes.addLine(to: CGPoint(x: size.width, y: center.y))
            context.stroke(axes, with: .color(tint.opacity(0.45)), lineWidth: 1)
            var sweep = Path()
            sweep.move(to: center)
            sweep.addArc(center: center, radius: radius, startAngle: .degrees(-80), endAngle: .degrees(-20), clockwise: false)
            sweep.closeSubpath()
            context.fill(sweep, with: .linearGradient(Gradient(colors: [tint.opacity(0.65), tint.opacity(0.05)]),
                                                       startPoint: center, endPoint: CGPoint(x: size.width, y: 0)))
            for point in [CGPoint(x: 0.65, y: 0.24), CGPoint(x: 0.3, y: 0.62), CGPoint(x: 0.73, y: 0.68)] {
                context.fill(Path(ellipseIn: CGRect(x: point.x * size.width, y: point.y * size.height, width: 5, height: 5)),
                             with: .color(.cyan))
            }
        }
    }
}

/// Process illustration only; execution state remains in the migration workspace.
private struct MigrationFlowArtwork: View {
    let tint: Color

    var body: some View {
        VStack(spacing: 30) {
            HStack(spacing: 18) {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(LinearGradient(colors: [.cyan.opacity(0.8), .blue.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 106, height: 66).offset(y: -15)
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.4)).frame(height: 2).padding(.horizontal, 8) }
                        .frame(width: 124, height: 77)
                }
                .rotation3DEffect(.degrees(-12), axis: (x: 0, y: 1, z: 0))
                Spacer(minLength: 4)
                Image(systemName: "arrow.right").font(.system(size: 32, weight: .medium)).foregroundStyle(tint)
                Spacer(minLength: 4)
                RoundedRectangle(cornerRadius: 15)
                    .fill(LinearGradient(colors: [.gray.opacity(0.8), Color(white: 0.13), .gray.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        VStack(spacing: 10) {
                            Text("SSD").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.8))
                            Capsule().fill(.black.opacity(0.7)).frame(width: 30, height: 5)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.3), lineWidth: 1))
                    .frame(width: 104, height: 124)
                    .rotation3DEffect(.degrees(12), axis: (x: 0, y: 1, z: 0))
            }
            .shadow(color: tint.opacity(0.25), radius: 18, y: 10)
            HStack(spacing: 0) {
                ForEach(Array([L10n.text("来源", "Source"), L10n.text("预检", "Preflight"), L10n.text("复制", "Copy"), L10n.text("读取校验", "Verify"), L10n.text("目标", "Target")].enumerated()), id: \.offset) { index, title in
                    if index > 0 { Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(tint.opacity(0.7)) }
                    VStack(spacing: 9) {
                        Text("\(index + 1)")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .frame(width: 34, height: 34)
                            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.45), lineWidth: 1))
                        Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            Text(L10n.text("搬移流程示意 · 尚未执行", "Migration workflow · Not started"))
                .font(AppDesignTokens.Typography.metadata).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


private struct GoldenHealthArtwork: View {
    let image: NSImage
    let tint: Color
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                GoldenLandingArtwork(image: image)
                Circle().stroke(tint.opacity(0.45), lineWidth: 8)
                    .frame(width: side * 0.43, height: side * 0.43)
                    .overlay {
                        VStack(spacing: 8) {
                            Text(L10n.text("尚未测量", "Not measured")).font(.system(size: 13))
                            Text("—").font(.system(size: 30, weight: .medium))
                        }
                    }
                    .position(x: (proxy.size.width - side) / 2 + side * 0.37,
                              y: proxy.size.height / 2)
            }
        }
        .allowsHitTesting(false)
    }
}
