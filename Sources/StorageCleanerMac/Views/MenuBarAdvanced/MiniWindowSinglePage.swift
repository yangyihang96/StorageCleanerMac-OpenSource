import SwiftUI

/// Legacy geometry helper retained for decoding/tests. Production pages never
/// shrink controls or text; constrained viewports scroll at their readable size.
enum MiniWindowPageFit {
    static func scale(content: CGSize, available: CGSize) -> CGFloat {
        guard content.width.isFinite, content.height.isFinite,
              available.width.isFinite, available.height.isFinite,
              content.width > 0, content.height > 0,
              available.width > 0, available.height > 0 else { return 1 }
        return min(1, available.width / content.width, available.height / content.height)
    }
}

struct MiniWindowFittedPage<Content: View>: View {
    let contentSize: CGSize
    let availableSize: CGSize
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.vertical) {
            content
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .scrollIndicators(.hidden)
        .frame(width: max(1, availableSize.width), height: max(1, availableSize.height), alignment: .top)

    }
}

/// Measures at a stable width, independently of the last window height. Used
/// by detached controls, whose natural height changes when a mode is expanded.
struct MiniWindowMeasuredPage<Content: View>: View {
    let initialSize: CGSize
    let reportSize: (CGSize) -> Void
    @ViewBuilder let content: Content
    @State private var measuredHeight: CGFloat?

    var body: some View {
        let naturalSize = CGSize(width: initialSize.width, height: measuredHeight ?? initialSize.height)
        GeometryReader { viewport in
            MiniWindowFittedPage(contentSize: naturalSize, availableSize: viewport.size) {
                content
                    .frame(width: initialSize.width,
                           alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.onChange(of: proxy.size, initial: true) {
                                guard proxy.size.height.isFinite, proxy.size.height > 0 else { return }
                                let size = proxy.size
                                guard measuredHeight.map({ abs($0 - size.height) > 0.5 }) ?? true else { return }
                                measuredHeight = size.height
                                // Publish outside the current SwiftUI measurement.
                                Task { @MainActor in
                                    guard measuredHeight == size.height else { return }
                                    reportSize(size)
                                }
                            }
                        }
                    }
            }
        }
        .frame(idealWidth: initialSize.width, idealHeight: naturalSize.height)
    }
}
