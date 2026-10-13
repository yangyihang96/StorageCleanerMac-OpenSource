import SwiftUI

/// A dashboard occupies its whole viewport. The native outer scroll host has
/// no overflow; the process list inside the dashboard is the sole scroller.
struct FeatureFixedDashboardSlot<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content.frame(width: proxy.size.width, height: proxy.size.height)
            }
            .scrollIndicators(.hidden)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }
}
