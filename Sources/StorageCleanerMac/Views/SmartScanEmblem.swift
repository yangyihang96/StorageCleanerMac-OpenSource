import SwiftUI

/// Native, resolution-independent scan mark from the 012 reference.
/// It follows the foreground tint; no text or controls are part of the drawing.
struct SmartScanEmblem: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                ScanArcs()
                    .stroke(style: StrokeStyle(lineWidth: side * 0.055, lineCap: .round))
                Circle()
                    .frame(width: side * 0.19, height: side * 0.19)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private struct ScanArcs: Shape {
        func path(in rect: CGRect) -> Path {
            let side = min(rect.width, rect.height)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            var path = Path()
            func arc(radius: CGFloat, from: Double, to: Double) {
                path.move(to: CGPoint(x: center.x + CGFloat(cos(from * .pi / 180)) * side * radius,
                                     y: center.y + CGFloat(sin(from * .pi / 180)) * side * radius))
                path.addArc(center: center, radius: side * radius,
                            startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
            }
            arc(radius: 0.44, from: 4, to: 346)
            arc(radius: 0.30, from: 14, to: 136)
            arc(radius: 0.30, from: 160, to: 266)
            arc(radius: 0.30, from: 286, to: 346)
            path.move(to: CGPoint(x: center.x - side * 0.13, y: center.y + side * 0.13))
            path.addLine(to: CGPoint(x: center.x - side * 0.36, y: center.y + side * 0.36))
            return path
        }
    }
}
