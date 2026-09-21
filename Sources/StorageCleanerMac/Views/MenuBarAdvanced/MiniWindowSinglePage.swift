import SwiftUI

/// The window first grows to the page's measured size. Only a smaller display
/// can constrain that size; in that case keep the entire page and its hit areas
/// together instead of introducing a scroll offset or clipping the last row.
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
        let scale = MiniWindowPageFit.scale(content: contentSize, available: availableSize)
        content
            .frame(width: contentSize.width, height: contentSize.height, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: contentSize.width * scale, height: contentSize.height * scale, alignment: .topLeading)
            .frame(width: availableSize.width, height: availableSize.height, alignment: .top)
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
                    .frame(width: initialSize.width, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.onChange(of: proxy.size, initial: true) {
                                guard proxy.size.height.isFinite, proxy.size.height > 0 else { return }
                                measuredHeight = proxy.size.height
                                reportSize(proxy.size)
                            }
                        }
                    }
            }
        }
        .frame(idealWidth: initialSize.width, idealHeight: naturalSize.height)
    }
}
