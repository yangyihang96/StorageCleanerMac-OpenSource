import SwiftUI

/// Initial-state illustrations only. Labels remain native and never assert a measurement or completed operation.
struct GoldenWorkflowArtwork: View {
    enum Kind { case energy, migration }
    let image: NSImage
    let kind: Kind
    var isMeasuring = false

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let origin = CGPoint(x: (proxy.size.width - side) / 2, y: (proxy.size.height - side) / 2)
            ZStack {
                GoldenLandingArtwork(image: image)
                if kind == .energy {
                    ForEach(0..<5) { index in
                        let positions: [CGPoint] = [CGPoint(x: 0.135, y: 0.59), CGPoint(x: 0.50, y: 0.32), CGPoint(x: 0.50, y: 0.59), CGPoint(x: 0.50, y: 0.86), CGPoint(x: 0.866, y: 0.59)]
                        Text(isMeasuring ? L10n.text("测量中", "Measuring") : L10n.text("尚未测量", "Not measured"))
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.white.opacity(0.80))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.14)))
                            .position(x: origin.x + side * positions[index].x, y: origin.y + side * positions[index].y)
                    }
                } else {
                    ForEach(0..<5) { index in
                        let xs: [CGFloat] = [0.16, 0.36, 0.50, 0.64, 0.84]
                        let titles = [L10n.text("Mac 文件夹", "Mac Folder"), L10n.text("预检", "Preflight"), L10n.text("复制", "Copy"), L10n.text("读取校验", "Verify"), L10n.text("外接 SSD", "External SSD")]
                        Text(titles[index])
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .position(x: origin.x + side * xs[index], y: origin.y + side * 0.64)
                    }
                    Text(L10n.text("流程示意 · 尚未执行", "Workflow · Not started"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .position(x: proxy.size.width / 2, y: origin.y + side * 0.77)
                }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
