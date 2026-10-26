import SwiftUI

struct CareStudioActivityHealthCard: View {
    let health: MyActivityHealth
    let mac: MyActivityMacInfo
    let onOpen: () -> Void
    @State private var showsReasons = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(MyActivityHealth.title, systemImage: "heart.text.square")
                    .font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 8)
                Button { showsReasons.toggle() } label: {
                    Image(systemName: "info.circle").font(.system(size: 15))
                }
                .buttonStyle(CareStudioRowButtonStyle())
                .accessibilityLabel(L10n.text("查看健康度依据", "Show Health Evidence"))
                .help(health.helpText)
                .popover(isPresented: $showsReasons) {
                    Text(health.helpText).font(.system(size: 13))
                        .padding(18).frame(width: 360, alignment: .leading)
                }
            }
            Text(health.statusText)
                .font(.system(size: 29, weight: .semibold))
                .foregroundStyle(statusColor)
#if DEBUG
                .layoutProbe("careStudio.activity.health.status")
#endif
            Text(mac.modelName ?? L10n.text("机型未读取", "Model Unavailable"))
                .font(.system(size: 13, weight: .medium))
            VStack(alignment: .leading, spacing: 6) {
                Text(mac.startupDiskName ?? L10n.text("启动磁盘", "Startup Disk"))
                    .font(.system(size: 12, weight: .semibold))
                Text(mac.capacityText).font(.system(size: 12)).monospacedDigit()
#if DEBUG
                    .layoutProbe("careStudio.activity.health.capacity")
#endif
                if let capacity = mac.capacity {
                    LightfieldDataBar(progress: capacity.userUsedRatio, module: .myActivity, style: .progress(), color: statusColor,
                                      accessibilityLabel: L10n.text("启动磁盘已用空间", "Startup Disk Used Space"))
                }
            }
            .foregroundStyle(CareStudioInk.secondary)
            Spacer(minLength: 0)
            HStack(alignment: .center, spacing: 10) {
                if let checkedAt = health.checkedAt {
                    let date = checkedAt.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().locale(L10n.locale))
                    Text(L10n.text("检查于 \(date)", "Checked \(date)"))
                        .font(.system(size: 11)).foregroundStyle(CareStudioInk.tertiary)
                } else {
                    Text(health.helpText).font(.system(size: 12)).foregroundStyle(CareStudioInk.secondary)
                }
                Spacer(minLength: 0)
                CareStudioPillButton(title: health.grade == nil ? L10n.text("去检查", "Check Now") : L10n.text("查看检查", "Review Check"),
                                     compact: true, action: onOpen)
            }
        }
        .foregroundStyle(CareStudioInk.primary)
        .padding(20).frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
        .careStudioCard()
#if DEBUG
        .layoutProbe("careStudio.activity.health")
#endif
    }

    private var statusColor: Color {
        switch health.grade {
        case .good: CareStudioPalette.color(CareStudioFamily.cleanup.palette.actionGlow)
        case .attention: CareStudioPalette.color(CareStudioFamily.performance.palette.actionGlow)
        case .problem: .red
        case nil: CareStudioInk.secondary
        }
    }
}

struct CareStudioActivityTimeCard: View {
    let savings: MyActivityTimeSavings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(MyActivityTimeSavings.title, systemImage: "clock.badge.checkmark")
                .font(.system(size: 16, weight: .semibold))
            Text(MyActivityTimeSavings.duration(savings.totalMinutes))
                .font(.system(size: 29, weight: .semibold)).monospacedDigit()
#if DEBUG
                .layoutProbe("careStudio.activity.time.value")
#endif
            Text(L10n.text("共 \(ByteFormat.count(savings.totalMinutes)) 分钟", "\(ByteFormat.count(savings.totalMinutes)) minutes in total"))
                .font(.system(size: 12)).foregroundStyle(CareStudioInk.secondary)
            ForEach(MyActivityTimeSavings.Category.allCases, id: \.self) { category in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(category.title)
                    Text("× " + ByteFormat.count(savings.counts[category] ?? 0))
                        .foregroundStyle(CareStudioInk.tertiary)
                    Spacer(minLength: 8)
                    Text(MyActivityTimeSavings.duration(savings.minutes(for: category))).monospacedDigit()
                }
                .font(.system(size: 12))
                .accessibilityElement(children: .combine)
                .help(L10n.text("每次估算 \(ByteFormat.count(category.minutesPerOperation)) 分钟。",
                               "Estimated at \(ByteFormat.count(category.minutesPerOperation)) minutes per operation."))
            }
            Text(MyActivityTimeSavings.explanation)
                .font(.system(size: 11)).foregroundStyle(CareStudioInk.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(CareStudioInk.primary)
        .padding(20).frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
        .careStudioCard()
#if DEBUG
        .layoutProbe("careStudio.activity.time")
#endif
    }
}

struct CareStudioActivityRecommendationCard: View {
    let recommendation: MyActivityRecommendation
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CareStudioFamilyIcon(family: CareStudioFamily(route: recommendation.destination),
                                 systemImage: recommendation.isGuide ? "sparkles" : "arrow.up.forward.circle", side: 30)
            Text(recommendation.title).font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(recommendation.detail).font(.system(size: 12))
                .foregroundStyle(CareStudioInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            CareStudioPillButton(title: recommendation.buttonTitle, compact: true, action: onOpen)
#if DEBUG
                .layoutProbe("careStudio.activity.recommendation.\(recommendation.kind.rawValue).open")
#endif
        }
        .foregroundStyle(CareStudioInk.primary)
        .padding(18).frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .careStudioCard()
#if DEBUG
        .layoutProbe("careStudio.activity.recommendation.\(recommendation.kind.rawValue)")
#endif
    }
}

struct CareStudioActivityRecommendationsList: View {
    let recommendations: [MyActivityRecommendation]
    let onOpen: (ReviewFilter) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(MyActivityRecommendations.title(count: recommendations.count))
                    .font(.system(size: 22, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                CareStudioPillButton(title: L10n.text("关闭", "Close"), compact: true, action: onClose)
            }
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(recommendations) { recommendation in
                        CareStudioActivityRecommendationCard(recommendation: recommendation) {
                            onOpen(recommendation.destination)
                        }
                    }
                }
            }
        }
        .padding(24).frame(minWidth: 420, idealWidth: 560, minHeight: 420, idealHeight: 620)
    }
}
