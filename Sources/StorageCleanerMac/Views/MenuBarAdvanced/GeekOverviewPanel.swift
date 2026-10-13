import SwiftUI

/// The same natural-size overview composition for live cards and Settings.
/// Sampling, routing, shell chrome and actions belong to the respective hosts.
struct GeekOverviewPanel<ModuleContent: View, EmptyContent: View>: View {
    let modules: [GeekDashboardModule]
    private let emptyContent: EmptyContent
    private let moduleContent: (GeekDashboardModule) -> ModuleContent

    init(modules: [GeekDashboardModule],
         @ViewBuilder empty: () -> EmptyContent,
         @ViewBuilder content: @escaping (GeekDashboardModule) -> ModuleContent) {
        self.modules = modules
        self.emptyContent = empty()
        self.moduleContent = content
    }

    var body: some View {
        VStack(spacing: GeekPanelLayout.sectionSpacing) {
            if modules.isEmpty { emptyContent }
            ForEach(modules) { module in
                moduleContent(module)
#if DEBUG
                    .layoutProbe("geek.overview.module." + module.rawValue)
#endif
            }
        }
        .padding(GeekPanelLayout.contentPadding)
        .frame(width: MiniWindowStyleTokens.overviewSize.width, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension GeekOverviewPanel where EmptyContent == EmptyView {
    init(modules: [GeekDashboardModule],
         @ViewBuilder content: @escaping (GeekDashboardModule) -> ModuleContent) {
        self.init(modules: modules, empty: { EmptyView() }, content: content)
    }
}
