import AppKit
import Foundation

struct IconSpec {
    let name: String
    let symbol: String
    let primary: NSColor
    let secondary: NSColor
    let darkPrimary: NSColor
    let darkSecondary: NSColor
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources", isDirectory: true)
let iconset = resources.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let appIconSource = resources.appendingPathComponent("AppIconSource.png")
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let specs: [IconSpec] = [
]

for spec in specs {
    try writePNG(drawModuleIcon(spec: spec, dark: false, size: 256), to: resources.appendingPathComponent("\(spec.name).png"))
    try writePNG(drawModuleIcon(spec: spec, dark: false, size: 256), to: resources.appendingPathComponent("\(spec.name)Light.png"))
    try writePNG(drawModuleIcon(spec: spec, dark: true, size: 256), to: resources.appendingPathComponent("\(spec.name)Dark.png"))
}

let lightAppIcon = appIconImage(dark: false, size: 1024)
let darkAppIcon = appIconImage(dark: true, size: 1024)
try writePNG(lightAppIcon, to: appIconSource)
try writePNG(lightAppIcon, to: resources.appendingPathComponent("AppIcon.png"))
try writePNG(lightAppIcon, to: resources.appendingPathComponent("AppIconLight.png"))
try writePNG(darkAppIcon, to: resources.appendingPathComponent("AppIconDark.png"))
try writePNG(lightAppIcon, to: resources.appendingPathComponent("AppIconClean.png"))
try writePNG(lightAppIcon, to: resources.appendingPathComponent("AppIconCleanLight.png"))
try writePNG(darkAppIcon, to: resources.appendingPathComponent("AppIconCleanDark.png"))

for logicalSize in [16, 32, 64] {
    let pixelSize = CGFloat(logicalSize * 2)
    try writePNG(
        appIconImage(dark: false, size: pixelSize),
        to: resources.appendingPathComponent("AppIconRuntimeLight\(logicalSize).png")
    )
    try writePNG(
        appIconImage(dark: true, size: pixelSize),
        to: resources.appendingPathComponent("AppIconRuntimeDark\(logicalSize).png")
    )
}

let iconSizes = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, size) in iconSizes {
    try writePNG(appIconImage(dark: false, size: CGFloat(size)), to: iconset.appendingPathComponent(filename))
}

try writeICNS(from: iconset, to: resources.appendingPathComponent("AppIcon.icns"))

func drawModuleIcon(spec: IconSpec, dark: Bool, size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let primary = dark ? spec.darkPrimary : spec.primary
    let secondary = dark ? spec.darkSecondary : spec.secondary

    let tileRect = NSRect(x: size * 0.105, y: size * 0.105, width: size * 0.79, height: size * 0.79)
    let tilePath = NSBezierPath(roundedRect: tileRect, xRadius: size * 0.215, yRadius: size * 0.215)

    NSShadow.draw(color: primary.withAlphaComponent(dark ? 0.38 : 0.28), blur: size * 0.13, offsetY: -size * 0.035) {
        NSGradient(colors: [
            secondary.withAlphaComponent(dark ? 0.90 : 0.84),
            primary.withAlphaComponent(dark ? 0.98 : 0.94)
        ])?.draw(in: tilePath, angle: -40)
    }

    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()

    NSGradient(colors: [
        NSColor.white.withAlphaComponent(dark ? 0.20 : 0.48),
        secondary.withAlphaComponent(dark ? 0.22 : 0.30),
        primary.withAlphaComponent(dark ? 0.30 : 0.22),
        NSColor.black.withAlphaComponent(dark ? 0.18 : 0.04)
    ])?.draw(in: tileRect, angle: 86)

    let upperBloom = NSBezierPath(ovalIn: NSRect(x: size * -0.05, y: size * 0.46, width: size * 0.70, height: size * 0.44))
    NSGradient(colors: [
        NSColor.white.withAlphaComponent(dark ? 0.20 : 0.46),
        secondary.withAlphaComponent(dark ? 0.18 : 0.26),
        NSColor.clear
    ])?.draw(in: upperBloom, angle: -30)

    let lowerBloom = NSBezierPath(ovalIn: NSRect(x: size * 0.36, y: size * -0.06, width: size * 0.66, height: size * 0.58))
    NSGradient(colors: [
        primary.withAlphaComponent(dark ? 0.32 : 0.30),
        secondary.withAlphaComponent(dark ? 0.22 : 0.18),
        NSColor.clear
    ])?.draw(in: lowerBloom, angle: 35)

    let highlight = NSBezierPath()
    highlight.move(to: NSPoint(x: tileRect.minX + size * 0.13, y: tileRect.maxY - size * 0.14))
    highlight.curve(
        to: NSPoint(x: tileRect.maxX - size * 0.14, y: tileRect.maxY - size * 0.17),
        controlPoint1: NSPoint(x: tileRect.midX - size * 0.18, y: tileRect.maxY - size * 0.06),
        controlPoint2: NSPoint(x: tileRect.midX + size * 0.19, y: tileRect.maxY - size * 0.07)
    )
    highlight.lineWidth = max(1.5, size * 0.018)
    highlight.lineCapStyle = .round
    NSColor.white.withAlphaComponent(dark ? 0.34 : 0.62).setStroke()
    highlight.stroke()

    NSGraphicsContext.restoreGraphicsState()

    NSColor.white.withAlphaComponent(dark ? 0.30 : 0.56).setStroke()
    let rim = NSBezierPath(roundedRect: tileRect.insetBy(dx: size * 0.018, dy: size * 0.018), xRadius: size * 0.188, yRadius: size * 0.188)
    rim.lineWidth = max(1, size * 0.010)
    rim.stroke()

    NSShadow.draw(color: NSColor.black.withAlphaComponent(dark ? 0.28 : 0.14), blur: size * 0.022, offsetY: -size * 0.010) {
        drawSymbol(
            spec.symbol,
            in: NSRect(x: size * 0.285, y: size * 0.285, width: size * 0.43, height: size * 0.43),
            pointSize: moduleSymbolPointSize(for: spec.symbol, size: size),
            color: .white
        )
    }
    return image
}

func drawAppIcon(dark: Bool, size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let shell = NSRect(x: size * 0.07, y: size * 0.07, width: size * 0.86, height: size * 0.86)
    let shellPath = NSBezierPath(roundedRect: shell, xRadius: size * 0.215, yRadius: size * 0.215)

    NSShadow.draw(color: NSColor.black.withAlphaComponent(dark ? 0.42 : 0.22), blur: size * 0.065, offsetY: -size * 0.026) {
        NSGradient(colors: dark
            ? [color(0x061426), color(0x0B3158), color(0x117A91), color(0x16D39B)]
            : [color(0xF7FDFF), color(0x7BE4FF), color(0x1B8CFF), color(0x19D59E)]
        )?.draw(in: shellPath, angle: -42)
    }

    NSGraphicsContext.saveGraphicsState()
    shellPath.addClip()

    NSGradient(colors: [
        NSColor.white.withAlphaComponent(dark ? 0.22 : 0.58),
        NSColor.white.withAlphaComponent(dark ? 0.06 : 0.20),
        color(0x001C38, alpha: dark ? 0.22 : 0.04)
    ])?.draw(in: shell.insetBy(dx: size * 0.026, dy: size * 0.026), angle: 86)

    let aquaPool = NSBezierPath(ovalIn: NSRect(x: size * -0.08, y: size * 0.30, width: size * 0.82, height: size * 0.62))
    NSGradient(colors: [
        color(0xE8FFFF, alpha: dark ? 0.11 : 0.36),
        color(0x5DE5FF, alpha: dark ? 0.19 : 0.28),
        NSColor.clear
    ])?.draw(in: aquaPool, angle: -35)

    let emeraldPool = NSBezierPath(ovalIn: NSRect(x: size * 0.41, y: size * -0.08, width: size * 0.68, height: size * 0.64))
    NSGradient(colors: [
        color(0x65FFD2, alpha: dark ? 0.25 : 0.34),
        color(0x00C486, alpha: dark ? 0.21 : 0.24),
        NSColor.clear
    ])?.draw(in: emeraldPool, angle: 38)

    let violetPool = NSBezierPath(ovalIn: NSRect(x: size * 0.28, y: size * 0.28, width: size * 0.75, height: size * 0.62))
    NSGradient(colors: [
        color(0x806CFF, alpha: dark ? 0.20 : 0.16),
        color(0x3E6DFF, alpha: dark ? 0.16 : 0.10),
        NSColor.clear
    ])?.draw(in: violetPool, angle: -20)

    let lowerWave = NSBezierPath()
    lowerWave.move(to: NSPoint(x: shell.minX, y: shell.minY + size * 0.17))
    lowerWave.curve(
        to: NSPoint(x: shell.maxX, y: shell.minY + size * 0.24),
        controlPoint1: NSPoint(x: shell.minX + size * 0.25, y: shell.minY + size * 0.38),
        controlPoint2: NSPoint(x: shell.maxX - size * 0.23, y: shell.minY + size * 0.05)
    )
    lowerWave.line(to: NSPoint(x: shell.maxX, y: shell.minY))
    lowerWave.line(to: NSPoint(x: shell.minX, y: shell.minY))
    lowerWave.close()
    NSGradient(colors: [
        color(0x13F3B5, alpha: dark ? 0.30 : 0.34),
        color(0x27A9FF, alpha: dark ? 0.18 : 0.21),
        color(0x5F64FF, alpha: dark ? 0.12 : 0.09)
    ])?.draw(in: lowerWave, angle: 6)

    NSColor.white.withAlphaComponent(dark ? 0.30 : 0.62).setStroke()
    let topHighlight = NSBezierPath()
    topHighlight.move(to: NSPoint(x: shell.minX + size * 0.13, y: shell.maxY - size * 0.12))
    topHighlight.curve(
        to: NSPoint(x: shell.maxX - size * 0.16, y: shell.maxY - size * 0.15),
        controlPoint1: NSPoint(x: shell.midX - size * 0.20, y: shell.maxY - size * 0.05),
        controlPoint2: NSPoint(x: shell.midX + size * 0.22, y: shell.maxY - size * 0.06)
    )
    topHighlight.lineWidth = max(2.5, size * 0.011)
    topHighlight.lineCapStyle = .round
    topHighlight.stroke()

    let orbit = NSBezierPath()
    orbit.appendArc(
        withCenter: NSPoint(x: size * 0.50, y: size * 0.50),
        radius: size * 0.33,
        startAngle: 202,
        endAngle: 326,
        clockwise: false
    )
    orbit.lineWidth = max(4, size * 0.017)
    orbit.lineCapStyle = .round
    color(0xEFFFFB, alpha: dark ? 0.20 : 0.34).setStroke()
    orbit.stroke()

    let plateRect = NSRect(x: size * 0.205, y: size * 0.285, width: size * 0.59, height: size * 0.43)
    let platePath = NSBezierPath(roundedRect: plateRect, xRadius: size * 0.098, yRadius: size * 0.098)
    NSShadow.draw(color: NSColor.black.withAlphaComponent(dark ? 0.34 : 0.17), blur: size * 0.045, offsetY: -size * 0.018) {
        NSGradient(colors: dark
            ? [color(0xF8FDFF, alpha: 0.28), color(0xA9C8DA, alpha: 0.20), color(0x132F42, alpha: 0.62)]
            : [color(0xFFFFFF, alpha: 0.94), color(0xEDF7FF, alpha: 0.84), color(0xC6DEE9, alpha: 0.86)]
        )?.draw(in: platePath, angle: -74)
    }

    NSGraphicsContext.restoreGraphicsState()

    let plateRim = NSBezierPath(roundedRect: NSRect(x: size * 0.205, y: size * 0.285, width: size * 0.59, height: size * 0.43).insetBy(dx: size * 0.014, dy: size * 0.014), xRadius: size * 0.082, yRadius: size * 0.082)
    NSColor.white.withAlphaComponent(dark ? 0.42 : 0.76).setStroke()
    plateRim.lineWidth = max(2, size * 0.010)
    plateRim.stroke()

    let indicatorRect = NSRect(x: size * 0.295, y: size * 0.515, width: size * 0.41, height: size * 0.060)
    let indicatorPath = NSBezierPath(roundedRect: indicatorRect, xRadius: size * 0.030, yRadius: size * 0.030)
    color(0x0B2A40, alpha: dark ? 0.42 : 0.18).setFill()
    indicatorPath.fill()
    let indicatorFill = NSBezierPath(roundedRect: NSRect(x: indicatorRect.minX, y: indicatorRect.minY, width: indicatorRect.width * 0.72, height: indicatorRect.height), xRadius: size * 0.030, yRadius: size * 0.030)
    NSGradient(colors: [color(0x54FBD2), color(0x22B8FF)])?.draw(in: indicatorFill, angle: 6)

    let lowerPill = NSBezierPath(roundedRect: NSRect(x: size * 0.295, y: size * 0.405, width: size * 0.32, height: size * 0.055), xRadius: size * 0.028, yRadius: size * 0.028)
    color(0x0B2A40, alpha: dark ? 0.34 : 0.13).setFill()
    lowerPill.fill()
    let statusDot = NSBezierPath(ovalIn: NSRect(x: size * 0.653, y: size * 0.402, width: size * 0.064, height: size * 0.064))
    NSShadow.draw(color: color(0x35FFC9, alpha: dark ? 0.50 : 0.42), blur: size * 0.020, offsetY: 0) {
        NSGradient(colors: [color(0xE9FFF7), color(0x30F2B5), color(0x00B686)])?.draw(in: statusDot, angle: -34)
    }

    let sweep = NSBezierPath()
    sweep.move(to: NSPoint(x: size * 0.315, y: size * 0.332))
    sweep.curve(
        to: NSPoint(x: size * 0.690, y: size * 0.725),
        controlPoint1: NSPoint(x: size * 0.435, y: size * 0.475),
        controlPoint2: NSPoint(x: size * 0.560, y: size * 0.628)
    )
    sweep.lineCapStyle = .round
    sweep.lineJoinStyle = .round
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = color(0x34FFD0, alpha: dark ? 0.56 : 0.48)
    glow.shadowBlurRadius = size * 0.040
    glow.shadowOffset = .zero
    glow.set()
    sweep.lineWidth = max(12, size * 0.056)
    color(0x28F7C0, alpha: dark ? 0.82 : 0.74).setStroke()
    sweep.stroke()
    NSGraphicsContext.restoreGraphicsState()

    sweep.lineWidth = max(6, size * 0.022)
    NSColor.white.withAlphaComponent(dark ? 0.82 : 0.92).setStroke()
    sweep.stroke()

    drawSparkle(at: NSPoint(x: size * 0.695, y: size * 0.735), size: size * 0.055, color: NSColor.white.withAlphaComponent(dark ? 0.92 : 0.98))
    drawSparkle(at: NSPoint(x: size * 0.300, y: size * 0.335), size: size * 0.034, color: color(0xE9FFF9, alpha: dark ? 0.84 : 0.94))

    NSColor.white.withAlphaComponent(dark ? 0.30 : 0.52).setStroke()
    let outerRim = NSBezierPath(roundedRect: shell.insetBy(dx: size * 0.022, dy: size * 0.022), xRadius: size * 0.194, yRadius: size * 0.194)
    outerRim.lineWidth = max(2, size * 0.009)
    outerRim.stroke()

    let innerRim = NSBezierPath(roundedRect: shell.insetBy(dx: size * 0.052, dy: size * 0.052), xRadius: size * 0.172, yRadius: size * 0.172)
    color(dark ? 0x8EF8FF : 0xFFFFFF, alpha: dark ? 0.18 : 0.28).setStroke()
    innerRim.lineWidth = max(1, size * 0.004)
    innerRim.stroke()

    return image
}

func appIconImage(dark: Bool, size: CGFloat) -> NSImage {
    if size <= 64 {
        return drawCompactBroomAppIcon(dark: dark, size: size)
    }
    return generatedAppIconImage(dark: dark, size: size)
        ?? drawSimpleCleanAppIcon(dark: dark, size: size)
}

func drawCompactBroomAppIcon(dark: Bool, size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }
    NSGraphicsContext.current?.imageInterpolation = .high

    NSColor.clear.setFill()
    NSRect(origin: .zero, size: image.size).fill()

    let shell = NSRect(
        x: size * 0.08,
        y: size * 0.08,
        width: size * 0.84,
        height: size * 0.84
    )
    let shellPath = NSBezierPath(
        roundedRect: shell,
        xRadius: size * 0.19,
        yRadius: size * 0.19
    )
    NSGradient(colors: dark
        ? [color(0x0B172A), color(0x102E55)]
        : [color(0xFFFFFF), color(0xDCE8FF)]
    )?.draw(in: shellPath, angle: 88)

    NSGraphicsContext.saveGraphicsState()
    shellPath.addClip()
    let transform = NSAffineTransform()
    transform.translateX(by: size * 0.52, yBy: size * 0.50)
    transform.rotate(byDegrees: -18)
    transform.translateX(by: -size * 0.52, yBy: -size * 0.50)
    transform.concat()

    let handle = NSBezierPath(
        roundedRect: NSRect(
            x: size * 0.458,
            y: size * 0.51,
            width: size * 0.13,
            height: size * 0.30
        ),
        xRadius: size * 0.05,
        yRadius: size * 0.05
    )
    NSGradient(colors: [color(0xFFFFFF), color(0xB7C8E7)])?
        .draw(in: handle, angle: 0)
    color(dark ? 0xD9E5FF : 0x7488B1, alpha: dark ? 0.70 : 0.82).setStroke()
    handle.lineWidth = max(0.65, size * 0.018)
    handle.stroke()

    let collar = NSBezierPath(
        roundedRect: NSRect(
            x: size * 0.36,
            y: size * 0.43,
            width: size * 0.33,
            height: size * 0.13
        ),
        xRadius: size * 0.055,
        yRadius: size * 0.055
    )
    NSGradient(colors: [color(0xFFFFFF), color(0xC5D2EB)])?
        .draw(in: collar, angle: 82)
    color(dark ? 0xD9E5FF : 0x647AA6, alpha: dark ? 0.72 : 0.86).setStroke()
    collar.lineWidth = max(0.65, size * 0.018)
    collar.stroke()

    let bristles = NSBezierPath()
    bristles.move(to: NSPoint(x: size * 0.385, y: size * 0.455))
    bristles.line(to: NSPoint(x: size * 0.665, y: size * 0.455))
    bristles.line(to: NSPoint(x: size * 0.735, y: size * 0.19))
    bristles.curve(
        to: NSPoint(x: size * 0.25, y: size * 0.19),
        controlPoint1: NSPoint(x: size * 0.62, y: size * 0.14),
        controlPoint2: NSPoint(x: size * 0.37, y: size * 0.14)
    )
    bristles.close()
    NSGradient(colors: [color(0x31F1F3), color(0x0B65FF), color(0x1739E8)])?
        .draw(in: bristles, angle: 0)

    let separatorColor = NSColor.white.withAlphaComponent(dark ? 0.24 : 0.38)
    separatorColor.setStroke()
    for x in [0.43, 0.52, 0.61] {
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: size * x, y: size * 0.42))
        separator.line(to: NSPoint(x: size * (x - 0.025), y: size * 0.20))
        separator.lineWidth = max(0.45, size * 0.014)
        separator.lineCapStyle = .round
        separator.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()

    color(dark ? 0x36547E : 0x829BC8, alpha: dark ? 0.82 : 0.72).setStroke()
    let edgeStroke = NSBezierPath(
        roundedRect: shell.insetBy(dx: size * 0.006, dy: size * 0.006),
        xRadius: size * 0.185,
        yRadius: size * 0.185
    )
    edgeStroke.lineWidth = max(0.65, size * 0.010)
    edgeStroke.stroke()

    return image
}

func drawSimpleCleanAppIcon(dark: Bool, size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let shell = NSRect(x: size * 0.062, y: size * 0.062, width: size * 0.876, height: size * 0.876)
    let corner = size * 0.225
    let shellPath = NSBezierPath(roundedRect: shell, xRadius: corner, yRadius: corner)

    NSShadow.draw(color: NSColor.black.withAlphaComponent(dark ? 0.45 : 0.24), blur: size * 0.060, offsetY: -size * 0.022) {
        NSGradient(colors: dark
            ? [color(0x061522), color(0x0B3A68), color(0x0679D8), color(0x19D99A)]
            : [color(0x0977FF), color(0x00B7FF), color(0x21D6A7), color(0x47F0A4)]
        )?.draw(in: shellPath, angle: -38)
    }

    NSGraphicsContext.saveGraphicsState()
    shellPath.addClip()

    NSGradient(colors: [
        NSColor.white.withAlphaComponent(dark ? 0.18 : 0.34),
        NSColor.white.withAlphaComponent(dark ? 0.045 : 0.10),
        color(0x00172A, alpha: dark ? 0.30 : 0.10)
    ])?.draw(in: shell, angle: 85)

    let topLight = NSBezierPath(ovalIn: NSRect(x: size * -0.12, y: size * 0.46, width: size * 0.80, height: size * 0.52))
    NSGradient(colors: [
        color(0xFFFFFF, alpha: dark ? 0.08 : 0.22),
        color(0x70EFFF, alpha: dark ? 0.14 : 0.22),
        NSColor.clear
    ])?.draw(in: topLight, angle: -28)

    let lowerLight = NSBezierPath(ovalIn: NSRect(x: size * 0.38, y: size * -0.10, width: size * 0.70, height: size * 0.66))
    NSGradient(colors: [
        color(0x5BFFD1, alpha: dark ? 0.28 : 0.36),
        color(0x05B990, alpha: dark ? 0.18 : 0.22),
        NSColor.clear
    ])?.draw(in: lowerLight, angle: 32)

    let glyphRect = NSRect(x: size * 0.205, y: size * 0.215, width: size * 0.59, height: size * 0.59)
    NSShadow.draw(color: color(0x082A48, alpha: dark ? 0.36 : 0.22), blur: size * 0.026, offsetY: -size * 0.010) {
        drawSymbol(
            "arrow.triangle.2.circlepath",
            in: glyphRect,
            pointSize: size * 0.45,
            color: NSColor.white.withAlphaComponent(dark ? 0.94 : 0.96)
        )
    }

    NSShadow.draw(color: color(0x3CFFD2, alpha: dark ? 0.50 : 0.36), blur: size * 0.024, offsetY: 0) {
        drawSparkle(
            at: NSPoint(x: size * 0.690, y: size * 0.675),
            size: size * 0.062,
            color: NSColor.white.withAlphaComponent(dark ? 0.95 : 1.0)
        )
    }
    drawSparkle(
        at: NSPoint(x: size * 0.315, y: size * 0.315),
        size: size * 0.026,
        color: NSColor.white.withAlphaComponent(dark ? 0.66 : 0.78)
    )

    NSGraphicsContext.restoreGraphicsState()

    let rim = NSBezierPath(roundedRect: shell.insetBy(dx: size * 0.020, dy: size * 0.020), xRadius: size * 0.202, yRadius: size * 0.202)
    rim.lineWidth = max(1.5, size * 0.007)
    NSColor.white.withAlphaComponent(dark ? 0.24 : 0.46).setStroke()
    rim.stroke()

    return image
}

func drawPolishedDriveCheckAppIcon(dark: Bool, size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let shell = NSRect(x: size * 0.048, y: size * 0.048, width: size * 0.904, height: size * 0.904)
    let shellPath = NSBezierPath(roundedRect: shell, xRadius: size * 0.232, yRadius: size * 0.232)

    NSShadow.draw(color: NSColor.black.withAlphaComponent(dark ? 0.54 : 0.26), blur: size * 0.072, offsetY: -size * 0.026) {
        NSGradient(colors: dark
            ? [color(0x06111E), color(0x0A3673), color(0x0796D6), color(0x17E0A2)]
            : [color(0xDFF9FF), color(0x55CFFF), color(0x087BFF), color(0x20E3A0)]
        )?.draw(in: shellPath, angle: -38)
    }

    NSGraphicsContext.saveGraphicsState()
    shellPath.addClip()

    NSGradient(colors: [
        NSColor.white.withAlphaComponent(dark ? 0.18 : 0.46),
        NSColor.white.withAlphaComponent(dark ? 0.06 : 0.12),
        color(0x001A34, alpha: dark ? 0.36 : 0.09)
    ])?.draw(in: shell, angle: 82)

    let leftGlass = NSBezierPath(ovalIn: NSRect(x: size * -0.16, y: size * 0.46, width: size * 0.78, height: size * 0.56))
    NSGradient(colors: [
        color(0xFFFFFF, alpha: dark ? 0.10 : 0.26),
        color(0x50B7FF, alpha: dark ? 0.22 : 0.20),
        NSColor.clear
    ])?.draw(in: leftGlass, angle: -28)

    let rightGlass = NSBezierPath(ovalIn: NSRect(x: size * 0.42, y: size * -0.10, width: size * 0.76, height: size * 0.76))
    NSGradient(colors: [
        color(0x5EFFD5, alpha: dark ? 0.32 : 0.42),
        color(0x0DB8D8, alpha: dark ? 0.18 : 0.20),
        NSColor.clear
    ])?.draw(in: rightGlass, angle: 34)

    let softViolet = NSBezierPath(ovalIn: NSRect(x: size * 0.06, y: size * -0.02, width: size * 0.62, height: size * 0.44))
    NSGradient(colors: [
        color(0x7D6DFF, alpha: dark ? 0.20 : 0.15),
        color(0x2F7BFF, alpha: dark ? 0.12 : 0.10),
        NSColor.clear
    ])?.draw(in: softViolet, angle: 16)

    let glassArc = NSBezierPath()
    glassArc.appendArc(
        withCenter: NSPoint(x: size * 0.49, y: size * 0.52),
        radius: size * 0.354,
        startAngle: 206,
        endAngle: 38,
        clockwise: false
    )
    glassArc.lineCapStyle = .round
    glassArc.lineWidth = max(6, size * 0.026)
    color(0xEFFFFC, alpha: dark ? 0.16 : 0.24).setStroke()
    glassArc.stroke()

    let topHighlight = NSBezierPath()
    topHighlight.move(to: NSPoint(x: shell.minX + size * 0.13, y: shell.maxY - size * 0.12))
    topHighlight.curve(
        to: NSPoint(x: shell.maxX - size * 0.15, y: shell.maxY - size * 0.145),
        controlPoint1: NSPoint(x: shell.midX - size * 0.20, y: shell.maxY - size * 0.052),
        controlPoint2: NSPoint(x: shell.midX + size * 0.22, y: shell.maxY - size * 0.060)
    )
    topHighlight.lineCapStyle = .round
    topHighlight.lineWidth = max(3, size * 0.012)
    NSColor.white.withAlphaComponent(dark ? 0.32 : 0.64).setStroke()
    topHighlight.stroke()

    let driveTop = NSRect(x: size * 0.252, y: size * 0.392, width: size * 0.496, height: size * 0.332)
    let driveTopPath = NSBezierPath(roundedRect: driveTop, xRadius: size * 0.112, yRadius: size * 0.112)
    NSShadow.draw(color: NSColor.black.withAlphaComponent(dark ? 0.34 : 0.17), blur: size * 0.045, offsetY: -size * 0.016) {
        NSGradient(colors: dark
            ? [color(0xF8FEFF, alpha: 0.42), color(0xB2D5E8, alpha: 0.28), color(0x0C2B42, alpha: 0.78)]
            : [color(0xFFFFFF), color(0xEEF9FF), color(0xB7DCEC)]
        )?.draw(in: driveTopPath, angle: -70)
    }

    let driveInset = NSBezierPath(
        roundedRect: driveTop.insetBy(dx: size * 0.018, dy: size * 0.018),
        xRadius: size * 0.094,
        yRadius: size * 0.094
    )
    driveInset.lineWidth = max(2, size * 0.009)
    NSColor.white.withAlphaComponent(dark ? 0.36 : 0.70).setStroke()
    driveInset.stroke()

    let driveFace = NSRect(x: size * 0.232, y: size * 0.286, width: size * 0.536, height: size * 0.205)
    let driveFacePath = NSBezierPath(roundedRect: driveFace, xRadius: size * 0.076, yRadius: size * 0.076)
    NSShadow.draw(color: NSColor.black.withAlphaComponent(dark ? 0.40 : 0.18), blur: size * 0.030, offsetY: -size * 0.012) {
        NSGradient(colors: dark
            ? [color(0xDDF4FF, alpha: 0.36), color(0x9DBFD3, alpha: 0.24), color(0x08263D, alpha: 0.82)]
            : [color(0xFFFFFF), color(0xDFF5FF), color(0x8BB9D6)]
        )?.draw(in: driveFacePath, angle: -74)
    }

    let driveFaceRim = NSBezierPath(
        roundedRect: driveFace.insetBy(dx: size * 0.012, dy: size * 0.012),
        xRadius: size * 0.064,
        yRadius: size * 0.064
    )
    driveFaceRim.lineWidth = max(1.5, size * 0.008)
    NSColor.white.withAlphaComponent(dark ? 0.40 : 0.76).setStroke()
    driveFaceRim.stroke()

    let slotRect = NSRect(x: driveFace.minX + size * 0.074, y: driveFace.minY + size * 0.080, width: size * 0.330, height: size * 0.042)
    let slot = NSBezierPath(roundedRect: slotRect, xRadius: slotRect.height / 2, yRadius: slotRect.height / 2)
    color(0x061D34, alpha: dark ? 0.70 : 0.28).setFill()
    slot.fill()

    let slotFill = NSBezierPath(
        roundedRect: NSRect(x: slotRect.minX, y: slotRect.minY, width: slotRect.width * 0.92, height: slotRect.height),
        xRadius: slotRect.height / 2,
        yRadius: slotRect.height / 2
    )
    NSGradient(colors: [
        color(0x5AFBDB, alpha: dark ? 0.92 : 0.90),
        color(0x16B8FF, alpha: dark ? 0.92 : 0.86),
        color(0x257BFF, alpha: dark ? 0.82 : 0.78)
    ])?.draw(in: slotFill, angle: 0)

    let ledSize = size * 0.060
    let ledRect = NSRect(x: driveFace.maxX - size * 0.125, y: driveFace.minY + size * 0.071, width: ledSize, height: ledSize)
    let ledPath = NSBezierPath(ovalIn: ledRect)
    NSShadow.draw(color: color(0x30FFD0, alpha: dark ? 0.52 : 0.42), blur: size * 0.020, offsetY: 0) {
        NSGradient(colors: [color(0xF4FFF8), color(0x32F0B3), color(0x00AFFF)])?.draw(in: ledPath, angle: -36)
    }

    let badgeRect = NSRect(x: size * 0.596, y: size * 0.184, width: size * 0.278, height: size * 0.278)
    let badgePath = NSBezierPath(ovalIn: badgeRect)
    NSShadow.draw(color: color(0x08E89B, alpha: dark ? 0.62 : 0.48), blur: size * 0.045, offsetY: -size * 0.012) {
        NSGradient(colors: [
            color(0xE7FFF1),
            color(0x2FF0A2),
            color(0x00C5CF)
        ])?.draw(in: badgePath, angle: -38)
    }
    badgePath.lineWidth = max(3, size * 0.012)
    NSColor.white.withAlphaComponent(dark ? 0.58 : 0.82).setStroke()
    badgePath.stroke()
    drawCheckmark(
        in: badgeRect.insetBy(dx: size * 0.072, dy: size * 0.083),
        lineWidth: max(7, size * 0.034),
        color: .white
    )

    drawSparkle(at: NSPoint(x: size * 0.775, y: size * 0.720), size: size * 0.050, color: NSColor.white.withAlphaComponent(dark ? 0.90 : 0.98))
    drawSparkle(at: NSPoint(x: size * 0.830, y: size * 0.640), size: size * 0.024, color: NSColor.white.withAlphaComponent(dark ? 0.72 : 0.88))

    NSGraphicsContext.restoreGraphicsState()

    let rim = NSBezierPath(roundedRect: shell.insetBy(dx: size * 0.019, dy: size * 0.019), xRadius: size * 0.210, yRadius: size * 0.210)
    rim.lineWidth = max(2, size * 0.009)
    NSColor.white.withAlphaComponent(dark ? 0.31 : 0.58).setStroke()
    rim.stroke()

    let innerRim = NSBezierPath(roundedRect: shell.insetBy(dx: size * 0.052, dy: size * 0.052), xRadius: size * 0.184, yRadius: size * 0.184)
    innerRim.lineWidth = max(1, size * 0.004)
    color(dark ? 0x8DF6FF : 0xFFFFFF, alpha: dark ? 0.17 : 0.28).setStroke()
    innerRim.stroke()

    return image
}

func drawAuroraStorageAppIcon(dark: Bool, size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let shell = NSRect(x: size * 0.060, y: size * 0.060, width: size * 0.880, height: size * 0.880)
    let shellPath = NSBezierPath(roundedRect: shell, xRadius: size * 0.230, yRadius: size * 0.230)

    NSShadow.draw(color: NSColor.black.withAlphaComponent(dark ? 0.56 : 0.28), blur: size * 0.078, offsetY: -size * 0.026) {
        NSGradient(colors: dark
            ? [color(0x06131F), color(0x0A2E65), color(0x087EC7), color(0x10E0A4)]
            : [color(0x073C82), color(0x0A78FF), color(0x04BDE8), color(0x21E4A5)]
        )?.draw(in: shellPath, angle: -38)
    }

    NSGraphicsContext.saveGraphicsState()
    shellPath.addClip()

    NSGradient(colors: [
        NSColor.white.withAlphaComponent(dark ? 0.16 : 0.30),
        NSColor.white.withAlphaComponent(dark ? 0.04 : 0.08),
        color(0x001326, alpha: dark ? 0.36 : 0.16)
    ])?.draw(in: shell, angle: 84)

    let upperBloom = NSBezierPath(ovalIn: NSRect(x: size * -0.18, y: size * 0.52, width: size * 0.88, height: size * 0.52))
    NSGradient(colors: [
        color(0xF2FFFF, alpha: dark ? 0.10 : 0.25),
        color(0x76EFFF, alpha: dark ? 0.18 : 0.20),
        NSColor.clear
    ])?.draw(in: upperBloom, angle: -30)

    let lowerBloom = NSBezierPath(ovalIn: NSRect(x: size * 0.36, y: size * -0.08, width: size * 0.76, height: size * 0.72))
    NSGradient(colors: [
        color(0x45FFD2, alpha: dark ? 0.34 : 0.42),
        color(0x04BB92, alpha: dark ? 0.23 : 0.27),
        NSColor.clear
    ])?.draw(in: lowerBloom, angle: 34)

    let sideGlow = NSBezierPath(ovalIn: NSRect(x: size * 0.70, y: size * 0.18, width: size * 0.34, height: size * 0.58))
    NSGradient(colors: [
        color(0x7CFFF3, alpha: dark ? 0.12 : 0.18),
        color(0x27A8FF, alpha: dark ? 0.08 : 0.10),
        NSColor.clear
    ])?.draw(in: sideGlow, angle: 20)

    let glassSlash = NSBezierPath()
    glassSlash.move(to: NSPoint(x: shell.minX + size * 0.08, y: shell.minY + size * 0.10))
    glassSlash.line(to: NSPoint(x: shell.minX + size * 0.26, y: shell.minY + size * 0.10))
    glassSlash.line(to: NSPoint(x: shell.maxX - size * 0.16, y: shell.maxY - size * 0.08))
    glassSlash.line(to: NSPoint(x: shell.maxX - size * 0.35, y: shell.maxY - size * 0.08))
    glassSlash.close()
    NSColor.white.withAlphaComponent(dark ? 0.045 : 0.13).setFill()
    glassSlash.fill()

    let topHighlight = NSBezierPath()
    topHighlight.move(to: NSPoint(x: shell.minX + size * 0.13, y: shell.maxY - size * 0.12))
    topHighlight.curve(
        to: NSPoint(x: shell.maxX - size * 0.15, y: shell.maxY - size * 0.145),
        controlPoint1: NSPoint(x: shell.midX - size * 0.20, y: shell.maxY - size * 0.05),
        controlPoint2: NSPoint(x: shell.midX + size * 0.22, y: shell.maxY - size * 0.055)
    )
    topHighlight.lineCapStyle = .round
    topHighlight.lineWidth = max(3, size * 0.012)
    NSColor.white.withAlphaComponent(dark ? 0.30 : 0.56).setStroke()
    topHighlight.stroke()

    let trayShadow = NSBezierPath(roundedRect: NSRect(x: size * 0.238, y: size * 0.292, width: size * 0.560, height: size * 0.178), xRadius: size * 0.075, yRadius: size * 0.075)
    color(0x03101C, alpha: dark ? 0.38 : 0.20).setFill()
    trayShadow.fill()

    let baseRect = NSRect(x: size * 0.238, y: size * 0.315, width: size * 0.560, height: size * 0.220)
    let basePath = NSBezierPath(roundedRect: baseRect, xRadius: size * 0.082, yRadius: size * 0.082)
    NSShadow.draw(color: NSColor.black.withAlphaComponent(dark ? 0.42 : 0.24), blur: size * 0.044, offsetY: -size * 0.018) {
        NSGradient(colors: dark
            ? [color(0xF5FDFF, alpha: 0.34), color(0x85AFC8, alpha: 0.24), color(0x071E33, alpha: 0.86)]
            : [color(0xFFFFFF), color(0xE9F9FF), color(0x9DC6D9)]
        )?.draw(in: basePath, angle: -72)
    }

    let baseSlot = NSBezierPath(roundedRect: NSRect(x: baseRect.minX + size * 0.098, y: baseRect.minY + size * 0.075, width: size * 0.305, height: size * 0.044), xRadius: size * 0.022, yRadius: size * 0.022)
    color(0x061F36, alpha: dark ? 0.70 : 0.34).setFill()
    baseSlot.fill()

    let baseSlotFill = NSBezierPath(roundedRect: NSRect(x: baseRect.minX + size * 0.098, y: baseRect.minY + size * 0.075, width: size * 0.205, height: size * 0.044), xRadius: size * 0.022, yRadius: size * 0.022)
    NSGradient(colors: [color(0x56FAD1), color(0x20AAFF)])?.draw(in: baseSlotFill, angle: 0)

    let ledRect = NSRect(x: baseRect.maxX - size * 0.132, y: baseRect.minY + size * 0.064, width: size * 0.064, height: size * 0.064)
    let led = NSBezierPath(ovalIn: ledRect)
    NSShadow.draw(color: color(0x31F5B9, alpha: dark ? 0.56 : 0.42), blur: size * 0.024, offsetY: 0) {
        NSGradient(colors: [color(0xF3FFF8), color(0x34F2B3), color(0x00B7FF)])?.draw(in: led, angle: -38)
    }

    let capRect = NSRect(x: size * 0.215, y: size * 0.430, width: size * 0.590, height: size * 0.275)
    let capPath = NSBezierPath(roundedRect: capRect, xRadius: size * 0.114, yRadius: size * 0.114)
    NSShadow.draw(color: NSColor.black.withAlphaComponent(dark ? 0.35 : 0.18), blur: size * 0.040, offsetY: -size * 0.016) {
        NSGradient(colors: dark
            ? [color(0xF8FEFF, alpha: 0.42), color(0x9CBBD0, alpha: 0.28), color(0x0D2D45, alpha: 0.78)]
            : [color(0xFFFFFF), color(0xF0FBFF), color(0xBAD9E6)]
        )?.draw(in: capPath, angle: -68)
    }

    let capInner = NSBezierPath(
        roundedRect: capRect.insetBy(dx: size * 0.042, dy: size * 0.040),
        xRadius: size * 0.080,
        yRadius: size * 0.080
    )
    NSColor.white.withAlphaComponent(dark ? 0.34 : 0.68).setStroke()
    capInner.lineWidth = max(2, size * 0.009)
    capInner.stroke()

    let capGlint = NSBezierPath()
    capGlint.move(to: NSPoint(x: capRect.minX + size * 0.080, y: capRect.maxY - size * 0.070))
    capGlint.curve(
        to: NSPoint(x: capRect.maxX - size * 0.090, y: capRect.maxY - size * 0.084),
        controlPoint1: NSPoint(x: capRect.midX - size * 0.13, y: capRect.maxY - size * 0.026),
        controlPoint2: NSPoint(x: capRect.midX + size * 0.16, y: capRect.maxY - size * 0.030)
    )
    capGlint.lineCapStyle = .round
    capGlint.lineWidth = max(2, size * 0.009)
    NSColor.white.withAlphaComponent(dark ? 0.34 : 0.72).setStroke()
    capGlint.stroke()

    let sweep = NSBezierPath()
    sweep.move(to: NSPoint(x: size * 0.305, y: size * 0.318))
    sweep.curve(
        to: NSPoint(x: size * 0.785, y: size * 0.585),
        controlPoint1: NSPoint(x: size * 0.425, y: size * 0.460),
        controlPoint2: NSPoint(x: size * 0.585, y: size * 0.548)
    )
    sweep.lineCapStyle = .round
    sweep.lineJoinStyle = .round

    NSGraphicsContext.saveGraphicsState()
    let sweepGlow = NSShadow()
    sweepGlow.shadowColor = color(0x39FFD5, alpha: dark ? 0.62 : 0.46)
    sweepGlow.shadowBlurRadius = size * 0.038
    sweepGlow.shadowOffset = .zero
    sweepGlow.set()
    sweep.lineWidth = max(11, size * 0.052)
    color(0x34F1C6, alpha: dark ? 0.84 : 0.76).setStroke()
    sweep.stroke()
    NSGraphicsContext.restoreGraphicsState()

    sweep.lineWidth = max(4, size * 0.018)
    NSColor.white.withAlphaComponent(dark ? 0.88 : 0.94).setStroke()
    sweep.stroke()

    drawSparkle(at: NSPoint(x: size * 0.790, y: size * 0.590), size: size * 0.060, color: NSColor.white.withAlphaComponent(dark ? 0.94 : 1.0))

    let rim = NSBezierPath(roundedRect: shell.insetBy(dx: size * 0.020, dy: size * 0.020), xRadius: size * 0.208, yRadius: size * 0.208)
    rim.lineWidth = max(2, size * 0.009)
    NSColor.white.withAlphaComponent(dark ? 0.30 : 0.52).setStroke()
    rim.stroke()

    let innerRim = NSBezierPath(roundedRect: shell.insetBy(dx: size * 0.055, dy: size * 0.055), xRadius: size * 0.182, yRadius: size * 0.182)
    innerRim.lineWidth = max(1, size * 0.004)
    color(dark ? 0x8EF8FF : 0xFFFFFF, alpha: dark ? 0.16 : 0.25).setStroke()
    innerRim.stroke()

    NSGraphicsContext.restoreGraphicsState()

    return image
}

func drawLiquidCleanAppIcon(dark: Bool, size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let shell = NSRect(x: size * 0.055, y: size * 0.055, width: size * 0.89, height: size * 0.89)
    let shellPath = NSBezierPath(roundedRect: shell, xRadius: size * 0.225, yRadius: size * 0.225)

    NSShadow.draw(color: NSColor.black.withAlphaComponent(dark ? 0.58 : 0.34), blur: size * 0.075, offsetY: -size * 0.030) {
        NSGradient(colors: dark
            ? [color(0x07101F), color(0x0B2A5F), color(0x075CB8), color(0x02B890)]
            : [color(0x064982), color(0x0B7DFF), color(0x09C5E7), color(0x19E09F)]
        )?.draw(in: shellPath, angle: -38)
    }

    NSGraphicsContext.saveGraphicsState()
    shellPath.addClip()

    NSGradient(colors: [
        NSColor.white.withAlphaComponent(dark ? 0.16 : 0.34),
        NSColor.white.withAlphaComponent(dark ? 0.04 : 0.08),
        color(0x001326, alpha: dark ? 0.36 : 0.16)
    ])?.draw(in: shell, angle: 84)

    let coolBloom = NSBezierPath(ovalIn: NSRect(x: size * -0.14, y: size * 0.48, width: size * 0.78, height: size * 0.56))
    NSGradient(colors: [
        color(0xF4FFFF, alpha: dark ? 0.11 : 0.30),
        color(0x65EFFF, alpha: dark ? 0.18 : 0.20),
        NSColor.clear
    ])?.draw(in: coolBloom, angle: -32)

    let greenBloom = NSBezierPath(ovalIn: NSRect(x: size * 0.36, y: size * -0.08, width: size * 0.76, height: size * 0.70))
    NSGradient(colors: [
        color(0x45FFD0, alpha: dark ? 0.36 : 0.42),
        color(0x04C08E, alpha: dark ? 0.24 : 0.28),
        NSColor.clear
    ])?.draw(in: greenBloom, angle: 34)

    let violetBloom = NSBezierPath(ovalIn: NSRect(x: size * 0.40, y: size * 0.45, width: size * 0.62, height: size * 0.50))
    NSGradient(colors: [
        color(0x8267FF, alpha: dark ? 0.24 : 0.18),
        color(0x1C5BFF, alpha: dark ? 0.16 : 0.11),
        NSColor.clear
    ])?.draw(in: violetBloom, angle: -25)

    let glassSlash = NSBezierPath()
    glassSlash.move(to: NSPoint(x: shell.minX + size * 0.08, y: shell.minY + size * 0.08))
    glassSlash.line(to: NSPoint(x: shell.minX + size * 0.28, y: shell.minY + size * 0.08))
    glassSlash.line(to: NSPoint(x: shell.maxX - size * 0.14, y: shell.maxY - size * 0.08))
    glassSlash.line(to: NSPoint(x: shell.maxX - size * 0.34, y: shell.maxY - size * 0.08))
    glassSlash.close()
    NSColor.white.withAlphaComponent(dark ? 0.055 : 0.14).setFill()
    glassSlash.fill()

    let orbit = NSBezierPath()
    orbit.appendArc(
        withCenter: NSPoint(x: size * 0.50, y: size * 0.49),
        radius: size * 0.35,
        startAngle: 205,
        endAngle: 35,
        clockwise: false
    )
    orbit.lineCapStyle = .round
    orbit.lineWidth = max(7, size * 0.030)
    color(0xCFFFFB, alpha: dark ? 0.16 : 0.28).setStroke()
    orbit.stroke()

    let storageRect = NSRect(x: size * 0.205, y: size * 0.305, width: size * 0.590, height: size * 0.420)
    let storagePath = NSBezierPath(roundedRect: storageRect, xRadius: size * 0.112, yRadius: size * 0.112)
    NSShadow.draw(color: NSColor.black.withAlphaComponent(dark ? 0.42 : 0.24), blur: size * 0.050, offsetY: -size * 0.020) {
        NSGradient(colors: dark
            ? [color(0xF7FEFF, alpha: 0.30), color(0x7EA9C7, alpha: 0.20), color(0x09233B, alpha: 0.78)]
            : [color(0xFFFFFF, alpha: 0.92), color(0xDDF7FF, alpha: 0.76), color(0x7EB2D8, alpha: 0.58)]
        )?.draw(in: storagePath, angle: -70)
    }

    let storageRim = NSBezierPath(
        roundedRect: storageRect.insetBy(dx: size * 0.016, dy: size * 0.016),
        xRadius: size * 0.096,
        yRadius: size * 0.096
    )
    storageRim.lineWidth = max(2, size * 0.010)
    NSColor.white.withAlphaComponent(dark ? 0.45 : 0.76).setStroke()
    storageRim.stroke()

    let storageShine = NSBezierPath()
    storageShine.move(to: NSPoint(x: storageRect.minX + size * 0.075, y: storageRect.maxY - size * 0.075))
    storageShine.curve(
        to: NSPoint(x: storageRect.maxX - size * 0.075, y: storageRect.maxY - size * 0.094),
        controlPoint1: NSPoint(x: storageRect.midX - size * 0.15, y: storageRect.maxY - size * 0.024),
        controlPoint2: NSPoint(x: storageRect.midX + size * 0.15, y: storageRect.maxY - size * 0.030)
    )
    storageShine.lineCapStyle = .round
    storageShine.lineWidth = max(2.5, size * 0.011)
    NSColor.white.withAlphaComponent(dark ? 0.38 : 0.66).setStroke()
    storageShine.stroke()

    let sweep = NSBezierPath()
    sweep.move(to: NSPoint(x: size * 0.245, y: size * 0.355))
    sweep.curve(
        to: NSPoint(x: size * 0.755, y: size * 0.650),
        controlPoint1: NSPoint(x: size * 0.395, y: size * 0.520),
        controlPoint2: NSPoint(x: size * 0.560, y: size * 0.610)
    )
    sweep.lineCapStyle = .round
    sweep.lineJoinStyle = .round
    NSGraphicsContext.saveGraphicsState()
    let sweepGlow = NSShadow()
    sweepGlow.shadowColor = color(0x2BFFD1, alpha: dark ? 0.62 : 0.48)
    sweepGlow.shadowBlurRadius = size * 0.042
    sweepGlow.shadowOffset = .zero
    sweepGlow.set()
    sweep.lineWidth = max(13, size * 0.060)
    color(0x21F2C7, alpha: dark ? 0.82 : 0.70).setStroke()
    sweep.stroke()
    NSGraphicsContext.restoreGraphicsState()

    sweep.lineWidth = max(5, size * 0.022)
    NSColor.white.withAlphaComponent(dark ? 0.88 : 0.92).setStroke()
    sweep.stroke()

    let rows = [
        NSRect(x: storageRect.minX + size * 0.110, y: storageRect.minY + size * 0.218, width: size * 0.345, height: size * 0.045),
        NSRect(x: storageRect.minX + size * 0.110, y: storageRect.minY + size * 0.132, width: size * 0.275, height: size * 0.041)
    ]

    for (index, rect) in rows.enumerated() {
        let base = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        color(0x071F36, alpha: dark ? 0.42 : 0.20).setFill()
        base.fill()

        let fill = NSBezierPath(
            roundedRect: NSRect(x: rect.minX, y: rect.minY, width: rect.width * (index == 0 ? 0.84 : 0.68), height: rect.height),
            xRadius: rect.height / 2,
            yRadius: rect.height / 2
        )
        NSGradient(colors: [
            color(index == 0 ? 0x58FFD5 : 0x6CE5FF, alpha: dark ? 0.92 : 0.90),
            color(index == 0 ? 0x15BFFF : 0x337BFF, alpha: dark ? 0.86 : 0.82)
        ])?.draw(in: fill, angle: 0)
    }

    let ledRect = NSRect(x: storageRect.maxX - size * 0.138, y: storageRect.minY + size * 0.092, width: size * 0.074, height: size * 0.074)
    let led = NSBezierPath(ovalIn: ledRect)
    NSShadow.draw(color: color(0x38FFD0, alpha: dark ? 0.56 : 0.42), blur: size * 0.026, offsetY: 0) {
        NSGradient(colors: [color(0xF3FFF9), color(0x3CF2B7), color(0x03AFFF)])?.draw(in: led, angle: -38)
    }

    drawSparkle(at: NSPoint(x: size * 0.755, y: size * 0.650), size: size * 0.055, color: .white)
    drawSparkle(at: NSPoint(x: size * 0.275, y: size * 0.285), size: size * 0.032, color: color(0xECFFFB, alpha: dark ? 0.82 : 0.92))

    NSGraphicsContext.restoreGraphicsState()

    let topHighlight = NSBezierPath()
    topHighlight.move(to: NSPoint(x: shell.minX + size * 0.135, y: shell.maxY - size * 0.130))
    topHighlight.curve(
        to: NSPoint(x: shell.maxX - size * 0.160, y: shell.maxY - size * 0.155),
        controlPoint1: NSPoint(x: shell.midX - size * 0.20, y: shell.maxY - size * 0.052),
        controlPoint2: NSPoint(x: shell.midX + size * 0.21, y: shell.maxY - size * 0.060)
    )
    topHighlight.lineCapStyle = .round
    topHighlight.lineWidth = max(3, size * 0.013)
    NSColor.white.withAlphaComponent(dark ? 0.30 : 0.56).setStroke()
    topHighlight.stroke()

    let outerRim = NSBezierPath(roundedRect: shell.insetBy(dx: size * 0.021, dy: size * 0.021), xRadius: size * 0.205, yRadius: size * 0.205)
    outerRim.lineWidth = max(2, size * 0.009)
    NSColor.white.withAlphaComponent(dark ? 0.31 : 0.50).setStroke()
    outerRim.stroke()

    let innerRim = NSBezierPath(roundedRect: shell.insetBy(dx: size * 0.055, dy: size * 0.055), xRadius: size * 0.180, yRadius: size * 0.180)
    innerRim.lineWidth = max(1, size * 0.004)
    color(dark ? 0x8EF8FF : 0xFFFFFF, alpha: dark ? 0.16 : 0.26).setStroke()
    innerRim.stroke()

    return image
}

func drawGlassDriveAppIcon(dark: Bool, size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let shell = NSRect(x: size * 0.055, y: size * 0.055, width: size * 0.89, height: size * 0.89)
    let shellPath = NSBezierPath(roundedRect: shell, xRadius: size * 0.224, yRadius: size * 0.224)

    NSShadow.draw(color: NSColor.black.withAlphaComponent(dark ? 0.54 : 0.30), blur: size * 0.074, offsetY: -size * 0.030) {
        NSGradient(colors: dark
            ? [color(0x07101D), color(0x0C3670), color(0x058AD2), color(0x12D79D)]
            : [color(0x07355E), color(0x086BFF), color(0x00B7E7), color(0x1CE19B)]
        )?.draw(in: shellPath, angle: -38)
    }

    NSGraphicsContext.saveGraphicsState()
    shellPath.addClip()

    NSGradient(colors: [
        NSColor.white.withAlphaComponent(dark ? 0.16 : 0.25),
        NSColor.white.withAlphaComponent(dark ? 0.05 : 0.07),
        color(0x001428, alpha: dark ? 0.34 : 0.22)
    ])?.draw(in: shell, angle: 82)

    let topGlass = NSBezierPath(ovalIn: NSRect(x: size * -0.18, y: size * 0.50, width: size * 0.92, height: size * 0.50))
    NSGradient(colors: [
        color(0xFFFFFF, alpha: dark ? 0.10 : 0.18),
        color(0x9EF1FF, alpha: dark ? 0.18 : 0.18),
        NSColor.clear
    ])?.draw(in: topGlass, angle: -30)

    let colorPocket = NSBezierPath(ovalIn: NSRect(x: size * 0.42, y: size * -0.08, width: size * 0.72, height: size * 0.66))
    NSGradient(colors: [
        color(0x2EFFBC, alpha: dark ? 0.34 : 0.40),
        color(0x00B0FF, alpha: dark ? 0.22 : 0.20),
        NSColor.clear
    ])?.draw(in: colorPocket, angle: 36)

    let violetPocket = NSBezierPath(ovalIn: NSRect(x: size * 0.35, y: size * 0.40, width: size * 0.66, height: size * 0.50))
    NSGradient(colors: [
        color(0x6657FF, alpha: dark ? 0.22 : 0.18),
        color(0x0B4BFF, alpha: dark ? 0.14 : 0.10),
        NSColor.clear
    ])?.draw(in: violetPocket, angle: -26)

    let sweep = NSBezierPath()
    sweep.move(to: NSPoint(x: shell.minX + size * 0.11, y: shell.minY + size * 0.22))
    sweep.curve(
        to: NSPoint(x: shell.maxX - size * 0.10, y: shell.maxY - size * 0.24),
        controlPoint1: NSPoint(x: shell.minX + size * 0.32, y: shell.midY + size * 0.02),
        controlPoint2: NSPoint(x: shell.maxX - size * 0.32, y: shell.midY + size * 0.20)
    )
    sweep.lineCapStyle = .round
    sweep.lineJoinStyle = .round
    sweep.lineWidth = max(18, size * 0.075)
    color(0x8DFFF3, alpha: dark ? 0.18 : 0.24).setStroke()
    sweep.stroke()

    let topHighlight = NSBezierPath()
    topHighlight.move(to: NSPoint(x: shell.minX + size * 0.14, y: shell.maxY - size * 0.13))
    topHighlight.curve(
        to: NSPoint(x: shell.maxX - size * 0.16, y: shell.maxY - size * 0.15),
        controlPoint1: NSPoint(x: shell.midX - size * 0.18, y: shell.maxY - size * 0.055),
        controlPoint2: NSPoint(x: shell.midX + size * 0.20, y: shell.maxY - size * 0.060)
    )
    topHighlight.lineCapStyle = .round
    topHighlight.lineWidth = max(3, size * 0.012)
    NSColor.white.withAlphaComponent(dark ? 0.30 : 0.62).setStroke()
    topHighlight.stroke()

    let driveRect = NSRect(x: size * 0.305, y: size * 0.270, width: size * 0.390, height: size * 0.555)
    let drivePath = NSBezierPath(roundedRect: driveRect, xRadius: size * 0.112, yRadius: size * 0.112)
    NSShadow.draw(color: NSColor.black.withAlphaComponent(dark ? 0.42 : 0.22), blur: size * 0.048, offsetY: -size * 0.020) {
        NSGradient(colors: dark
            ? [color(0xF7FCFF, alpha: 0.42), color(0x83A6BA, alpha: 0.24), color(0x071E33, alpha: 0.90)]
            : [color(0xFFFFFF), color(0xE9F8FF), color(0x8CB8D2)]
        )?.draw(in: drivePath, angle: -70)
    }

    let driveInner = NSBezierPath(
        roundedRect: driveRect.insetBy(dx: size * 0.018, dy: size * 0.018),
        xRadius: size * 0.094,
        yRadius: size * 0.094
    )
    NSColor.white.withAlphaComponent(dark ? 0.42 : 0.78).setStroke()
    driveInner.lineWidth = max(2, size * 0.010)
    driveInner.stroke()

    let driveShine = NSBezierPath()
    driveShine.move(to: NSPoint(x: driveRect.minX + size * 0.070, y: driveRect.maxY - size * 0.080))
    driveShine.curve(
        to: NSPoint(x: driveRect.maxX - size * 0.070, y: driveRect.maxY - size * 0.096),
        controlPoint1: NSPoint(x: driveRect.midX - size * 0.10, y: driveRect.maxY - size * 0.030),
        controlPoint2: NSPoint(x: driveRect.midX + size * 0.10, y: driveRect.maxY - size * 0.034)
    )
    driveShine.lineCapStyle = .round
    driveShine.lineWidth = max(2, size * 0.010)
    NSColor.white.withAlphaComponent(dark ? 0.32 : 0.68).setStroke()
    driveShine.stroke()

    let faceRect = NSRect(x: driveRect.minX + size * 0.078, y: driveRect.minY + size * 0.170, width: driveRect.width - size * 0.156, height: size * 0.285)
    let facePath = NSBezierPath(roundedRect: faceRect, xRadius: size * 0.058, yRadius: size * 0.058)
    NSGradient(colors: [
        color(0x062A4C, alpha: dark ? 0.58 : 0.28),
        color(0x0A7CFF, alpha: dark ? 0.32 : 0.20),
        color(0x22F0C6, alpha: dark ? 0.16 : 0.13)
    ])?.draw(in: facePath, angle: -32)

    let slotRect = NSRect(x: faceRect.minX + size * 0.038, y: faceRect.minY + size * 0.072, width: faceRect.width - size * 0.076, height: size * 0.048)
    let slot = NSBezierPath(roundedRect: slotRect, xRadius: slotRect.height / 2, yRadius: slotRect.height / 2)
    color(0x041B2E, alpha: dark ? 0.72 : 0.40).setFill()
    slot.fill()

    let slotFill = NSBezierPath(
        roundedRect: NSRect(x: slotRect.minX, y: slotRect.minY, width: slotRect.width * 0.62, height: slotRect.height),
        xRadius: slotRect.height / 2,
        yRadius: slotRect.height / 2
    )
    NSGradient(colors: [color(0x34F7CD), color(0x159DFF)])?.draw(in: slotFill, angle: 0)

    let ledSize = size * 0.048
    let led = NSBezierPath(ovalIn: NSRect(x: driveRect.midX - ledSize / 2, y: driveRect.minY + size * 0.075, width: ledSize, height: ledSize))
    NSShadow.draw(color: color(0x33FFD0, alpha: dark ? 0.48 : 0.38), blur: size * 0.020, offsetY: 0) {
        NSGradient(colors: [color(0xF1FFF8), color(0x36F4B4), color(0x00B7FF)])?.draw(in: led, angle: -38)
    }

    let statusRect = NSRect(x: size * 0.640, y: size * 0.235, width: size * 0.205, height: size * 0.205)
    let statusCircle = NSBezierPath(ovalIn: statusRect)
    NSShadow.draw(color: color(0x08E79F, alpha: dark ? 0.62 : 0.50), blur: size * 0.045, offsetY: -size * 0.012) {
        NSGradient(colors: [
            color(0xDFFFF1),
            color(0x2FED9A),
            color(0x02AFFF)
        ])?.draw(in: statusCircle, angle: -38)
    }

    NSColor.white.withAlphaComponent(dark ? 0.56 : 0.80).setStroke()
    statusCircle.lineWidth = max(3, size * 0.012)
    statusCircle.stroke()
    drawSparkle(
        at: NSPoint(x: statusRect.midX, y: statusRect.midY),
        size: size * 0.062,
        color: NSColor.white.withAlphaComponent(dark ? 0.94 : 0.98)
    )

    drawSparkle(at: NSPoint(x: size * 0.725, y: size * 0.760), size: size * 0.040, color: NSColor.white.withAlphaComponent(dark ? 0.78 : 0.92))
    drawSparkle(at: NSPoint(x: size * 0.288, y: size * 0.292), size: size * 0.027, color: color(0xE9FFF9, alpha: dark ? 0.72 : 0.90))

    NSGraphicsContext.restoreGraphicsState()

    let outerRim = NSBezierPath(roundedRect: shell.insetBy(dx: size * 0.020, dy: size * 0.020), xRadius: size * 0.204, yRadius: size * 0.204)
    outerRim.lineWidth = max(2, size * 0.009)
    NSColor.white.withAlphaComponent(dark ? 0.30 : 0.54).setStroke()
    outerRim.stroke()

    let innerRim = NSBezierPath(roundedRect: shell.insetBy(dx: size * 0.055, dy: size * 0.055), xRadius: size * 0.178, yRadius: size * 0.178)
    innerRim.lineWidth = max(1, size * 0.004)
    color(dark ? 0x87F4FF : 0xFFFFFF, alpha: dark ? 0.16 : 0.30).setStroke()
    innerRim.stroke()

    return image
}

func drawRefinedAppIcon(dark: Bool, size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let shell = NSRect(x: size * 0.055, y: size * 0.055, width: size * 0.89, height: size * 0.89)
    let shellPath = NSBezierPath(roundedRect: shell, xRadius: size * 0.235, yRadius: size * 0.235)

    NSShadow.draw(color: NSColor.black.withAlphaComponent(dark ? 0.46 : 0.28), blur: size * 0.075, offsetY: -size * 0.024) {
        NSGradient(colors: dark
            ? [color(0x061320), color(0x0D315C), color(0x126FA2), color(0x12F0B1)]
            : [color(0x0063E6), color(0x00B7FF), color(0x15D7B4), color(0x42F0A8)]
        )?.draw(in: shellPath, angle: -38)
    }

    NSGraphicsContext.saveGraphicsState()
    shellPath.addClip()

    NSGradient(colors: [
        NSColor.white.withAlphaComponent(dark ? 0.20 : 0.34),
        NSColor.white.withAlphaComponent(dark ? 0.06 : 0.10),
        color(0x001A31, alpha: dark ? 0.30 : 0.13)
    ])?.draw(in: shell.insetBy(dx: size * 0.024, dy: size * 0.024), angle: 84)

    let cyanBloom = NSBezierPath(ovalIn: NSRect(x: size * -0.12, y: size * 0.35, width: size * 0.78, height: size * 0.58))
    NSGradient(colors: [
        color(0xF1FFFF, alpha: dark ? 0.11 : 0.24),
        color(0x66EFFF, alpha: dark ? 0.20 : 0.26),
        NSColor.clear
    ])?.draw(in: cyanBloom, angle: -35)

    let emeraldBloom = NSBezierPath(ovalIn: NSRect(x: size * 0.38, y: size * -0.08, width: size * 0.70, height: size * 0.62))
    NSGradient(colors: [
        color(0x57FFD4, alpha: dark ? 0.30 : 0.37),
        color(0x0AC196, alpha: dark ? 0.20 : 0.24),
        NSColor.clear
    ])?.draw(in: emeraldBloom, angle: 38)

    let violetBloom = NSBezierPath(ovalIn: NSRect(x: size * 0.30, y: size * 0.35, width: size * 0.72, height: size * 0.56))
    NSGradient(colors: [
        color(0x806CFF, alpha: dark ? 0.24 : 0.22),
        color(0x325DFF, alpha: dark ? 0.15 : 0.14),
        NSColor.clear
    ])?.draw(in: violetBloom, angle: -20)

    let warmBloom = NSBezierPath(ovalIn: NSRect(x: size * 0.58, y: size * 0.62, width: size * 0.40, height: size * 0.34))
    NSGradient(colors: [
        color(0xFFE98A, alpha: dark ? 0.20 : 0.26),
        color(0xFF9F0A, alpha: dark ? 0.11 : 0.14),
        NSColor.clear
    ])?.draw(in: warmBloom, angle: -32)

    let scanRibbon = NSBezierPath()
    scanRibbon.move(to: NSPoint(x: shell.minX + size * 0.12, y: shell.minY + size * 0.24))
    scanRibbon.curve(
        to: NSPoint(x: shell.maxX - size * 0.12, y: shell.maxY - size * 0.24),
        controlPoint1: NSPoint(x: shell.minX + size * 0.32, y: shell.midY + size * 0.03),
        controlPoint2: NSPoint(x: shell.maxX - size * 0.34, y: shell.midY + size * 0.20)
    )
    scanRibbon.lineCapStyle = .round
    scanRibbon.lineJoinStyle = .round
    NSGraphicsContext.saveGraphicsState()
    let ribbonGlow = NSShadow()
    ribbonGlow.shadowColor = color(0x35FFE2, alpha: dark ? 0.48 : 0.38)
    ribbonGlow.shadowBlurRadius = size * 0.052
    ribbonGlow.shadowOffset = .zero
    ribbonGlow.set()
    scanRibbon.lineWidth = max(18, size * 0.086)
    color(0x1CF7D3, alpha: dark ? 0.34 : 0.30).setStroke()
    scanRibbon.stroke()
    NSGraphicsContext.restoreGraphicsState()

    scanRibbon.lineWidth = max(5, size * 0.018)
    color(0xF0FFFF, alpha: dark ? 0.44 : 0.62).setStroke()
    scanRibbon.stroke()

    let orbit = NSBezierPath()
    orbit.appendArc(
        withCenter: NSPoint(x: size * 0.50, y: size * 0.51),
        radius: size * 0.345,
        startAngle: 214,
        endAngle: 36,
        clockwise: false
    )
    orbit.lineCapStyle = .round
    orbit.lineWidth = max(5, size * 0.022)
    color(0xEFFFFB, alpha: dark ? 0.22 : 0.38).setStroke()
    orbit.stroke()

    NSColor.white.withAlphaComponent(dark ? 0.30 : 0.62).setStroke()
    let topHighlight = NSBezierPath()
    topHighlight.move(to: NSPoint(x: shell.minX + size * 0.14, y: shell.maxY - size * 0.12))
    topHighlight.curve(
        to: NSPoint(x: shell.maxX - size * 0.16, y: shell.maxY - size * 0.145),
        controlPoint1: NSPoint(x: shell.midX - size * 0.20, y: shell.maxY - size * 0.05),
        controlPoint2: NSPoint(x: shell.midX + size * 0.22, y: shell.maxY - size * 0.06)
    )
    topHighlight.lineWidth = max(2.5, size * 0.011)
    topHighlight.lineCapStyle = .round
    topHighlight.stroke()

    let storageRect = NSRect(x: size * 0.195, y: size * 0.320, width: size * 0.61, height: size * 0.385)
    let storagePath = NSBezierPath(roundedRect: storageRect, xRadius: size * 0.105, yRadius: size * 0.105)
    NSShadow.draw(color: NSColor.black.withAlphaComponent(dark ? 0.34 : 0.28), blur: size * 0.045, offsetY: -size * 0.018) {
        NSGradient(colors: dark
            ? [color(0xF9FEFF, alpha: 0.34), color(0xB9D5E4, alpha: 0.20), color(0x0B2B3D, alpha: 0.66)]
            : [color(0xF5FFFF, alpha: 0.74), color(0xB7F1FF, alpha: 0.60), color(0x176F96, alpha: 0.52)]
        )?.draw(in: storagePath, angle: -70)
    }

    let storageRim = NSBezierPath(
        roundedRect: storageRect.insetBy(dx: size * 0.014, dy: size * 0.014),
        xRadius: size * 0.090,
        yRadius: size * 0.090
    )
    NSColor.white.withAlphaComponent(dark ? 0.44 : 0.66).setStroke()
    storageRim.lineWidth = max(2, size * 0.010)
    storageRim.stroke()

    let storageGlint = NSBezierPath()
    storageGlint.move(to: NSPoint(x: storageRect.minX + size * 0.070, y: storageRect.maxY - size * 0.075))
    storageGlint.curve(
        to: NSPoint(x: storageRect.maxX - size * 0.075, y: storageRect.maxY - size * 0.092),
        controlPoint1: NSPoint(x: storageRect.midX - size * 0.14, y: storageRect.maxY - size * 0.022),
        controlPoint2: NSPoint(x: storageRect.midX + size * 0.15, y: storageRect.maxY - size * 0.030)
    )
    storageGlint.lineWidth = max(2, size * 0.010)
    storageGlint.lineCapStyle = .round
    NSColor.white.withAlphaComponent(dark ? 0.36 : 0.54).setStroke()
    storageGlint.stroke()

    let layerRows = [
        NSRect(x: storageRect.minX + size * 0.110, y: storageRect.minY + size * 0.235, width: size * 0.400, height: size * 0.050),
        NSRect(x: storageRect.minX + size * 0.110, y: storageRect.minY + size * 0.155, width: size * 0.330, height: size * 0.046),
        NSRect(x: storageRect.minX + size * 0.110, y: storageRect.minY + size * 0.080, width: size * 0.250, height: size * 0.042)
    ]

    for (index, rect) in layerRows.enumerated() {
        let row = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        color(0x09263B, alpha: dark ? 0.38 : 0.24).setFill()
        row.fill()

        let fillWidth = rect.width * [0.82, 0.66, 0.48][index]
        let fill = NSBezierPath(
            roundedRect: NSRect(x: rect.minX, y: rect.minY, width: fillWidth, height: rect.height),
            xRadius: rect.height / 2,
            yRadius: rect.height / 2
        )
        NSGradient(colors: [
            color(index == 0 ? 0x4DFFD3 : 0x55D8FF, alpha: dark ? 0.90 : 0.96),
            color(index == 0 ? 0x17BFFF : 0x2478FF, alpha: dark ? 0.86 : 0.94)
        ])?.draw(in: fill, angle: 0)
    }

    let cleanCoreRect = NSRect(x: size * 0.600, y: size * 0.214, width: size * 0.250, height: size * 0.250)
    let cleanCore = NSBezierPath(ovalIn: cleanCoreRect)
    NSShadow.draw(color: color(0x13F4B2, alpha: dark ? 0.56 : 0.45), blur: size * 0.048, offsetY: -size * 0.010) {
        NSGradient(colors: [
            color(0xF2FFF7),
            color(0x2EF2AE),
            color(0x01AFFF)
        ])?.draw(in: cleanCore, angle: -38)
    }

    NSColor.white.withAlphaComponent(dark ? 0.48 : 0.74).setStroke()
    cleanCore.lineWidth = max(2, size * 0.010)
    cleanCore.stroke()

    drawSparkle(
        at: NSPoint(x: cleanCoreRect.midX, y: cleanCoreRect.midY),
        size: size * 0.070,
        color: NSColor.white.withAlphaComponent(dark ? 0.94 : 0.98)
    )
    drawSparkle(at: NSPoint(x: size * 0.715, y: size * 0.775), size: size * 0.042, color: NSColor.white.withAlphaComponent(dark ? 0.88 : 0.96))
    drawSparkle(at: NSPoint(x: size * 0.292, y: size * 0.300), size: size * 0.030, color: color(0xE9FFF9, alpha: dark ? 0.80 : 0.92))

    NSGraphicsContext.restoreGraphicsState()

    NSColor.white.withAlphaComponent(dark ? 0.30 : 0.52).setStroke()
    let outerRim = NSBezierPath(roundedRect: shell.insetBy(dx: size * 0.022, dy: size * 0.022), xRadius: size * 0.210, yRadius: size * 0.210)
    outerRim.lineWidth = max(2, size * 0.009)
    outerRim.stroke()

    let innerRim = NSBezierPath(roundedRect: shell.insetBy(dx: size * 0.054, dy: size * 0.054), xRadius: size * 0.185, yRadius: size * 0.185)
    color(dark ? 0x8EF8FF : 0xFFFFFF, alpha: dark ? 0.18 : 0.28).setStroke()
    innerRim.lineWidth = max(1, size * 0.004)
    innerRim.stroke()

    return image
}

func generatedAppIconImage(dark: Bool, size: CGFloat) -> NSImage? {
    // These files are approved source artwork. Generated output must never overwrite them.
    let sourceName = dark ? "AppIconGeneratedDark.png" : "AppIconGeneratedLight.png"
    let sourceURL = resources.appendingPathComponent(sourceName)
    guard let source = NSImage(contentsOf: sourceURL) else {
        return nil
    }

    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    // macOS app icons keep the artwork inside ~84% of the canvas so the Dock
    // renders them at the same visual size as system apps. The approved source
    // artwork fills its canvas edge to edge, so scale it down here.
    let artworkSide = size * 0.84
    let artworkRect = NSRect(
        x: (size - artworkSide) / 2,
        y: (size - artworkSide) / 2,
        width: artworkSide,
        height: artworkSide
    )
    let mask = NSBezierPath(
        roundedRect: artworkRect,
        xRadius: artworkSide * 0.218,
        yRadius: artworkSide * 0.218
    )
    mask.addClip()
    // The approved export includes a narrow baked-in perimeter highlight.
    // Crop only that export edge so Finder and the Dock do not render it as
    // a white halo around the icon's transparent silhouette.
    let sourceRect = NSRect(origin: .zero, size: source.size).insetBy(
        dx: source.size.width * 0.015,
        dy: source.size.height * 0.015
    )
    source.draw(
        in: artworkRect,
        from: sourceRect,
        operation: .sourceOver,
        fraction: 1
    )

    // Keep the antialiased silhouette blue-gray rather than translucent
    // white, which otherwise becomes a visible halo on dark wallpapers.
    color(dark ? 0x36547E : 0x829BC8, alpha: dark ? 0.82 : 0.72).setStroke()
    mask.lineWidth = max(0.75, size * 0.004)
    mask.stroke()

    return image
}

func resizedImage(_ source: NSImage, to size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    source.draw(
        in: NSRect(x: 0, y: 0, width: size, height: size),
        from: NSRect(origin: .zero, size: source.size),
        operation: .sourceOver,
        fraction: 1
    )
    return image
}

func drawSymbol(_ symbol: String, in rect: NSRect, pointSize: CGFloat, color: NSColor) {
    let pointConfig = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    let colorConfig = NSImage.SymbolConfiguration(hierarchicalColor: color)
    let config = pointConfig.applying(colorConfig)
    guard let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
        return
    }

    symbolImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
}

func moduleSymbolPointSize(for symbol: String, size: CGFloat) -> CGFloat {
    switch symbol {
    case "arrow.triangle.2.circlepath", "exclamationmark.triangle.fill", "memorychip.fill", "clock.arrow.circlepath", "chart.line.uptrend.xyaxis":
        return size * 0.31
    case "doc.text.fill", "hand.raised.fill", "powerplug.fill":
        return size * 0.33
    default:
        return size * 0.35
    }
}

func drawSparkle(at point: NSPoint, size: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: point.x, y: point.y + size))
    path.line(to: NSPoint(x: point.x + size * 0.22, y: point.y + size * 0.22))
    path.line(to: NSPoint(x: point.x + size, y: point.y))
    path.line(to: NSPoint(x: point.x + size * 0.22, y: point.y - size * 0.22))
    path.line(to: NSPoint(x: point.x, y: point.y - size))
    path.line(to: NSPoint(x: point.x - size * 0.22, y: point.y - size * 0.22))
    path.line(to: NSPoint(x: point.x - size, y: point.y))
    path.line(to: NSPoint(x: point.x - size * 0.22, y: point.y + size * 0.22))
    path.close()
    color.setFill()
    path.fill()
}

func drawCheckmark(in rect: NSRect, lineWidth: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: rect.minX + rect.width * 0.12, y: rect.midY - rect.height * 0.02))
    path.line(to: NSPoint(x: rect.minX + rect.width * 0.40, y: rect.minY + rect.height * 0.22))
    path.line(to: NSPoint(x: rect.maxX - rect.width * 0.08, y: rect.maxY - rect.height * 0.18))
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.lineWidth = lineWidth
    color.setStroke()
    path.stroke()
}

func writePNG(_ image: NSImage, to url: URL) throws {
    // Render into an explicit 1x bitmap so output pixels always match the
    // requested point size, regardless of the host display's backing scale.
    let pixelWidth = Int(image.size.width.rounded())
    let pixelHeight = Int(image.size.height.rounded())
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelWidth,
        pixelsHigh: pixelHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "Artwork", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to encode PNG"])
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "Artwork", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to encode PNG"])
    }
    try png.write(to: url, options: .atomic)
}

func writeICNS(from iconset: URL, to outputURL: URL) throws {
    // Legacy ic04/ic05 chunks use raw ARGB. Retina tags keep every embedded PNG native
    // and provide the small Finder/Dock representations through system downsampling.
    let representations = [
        (type: "ic11", filename: "icon_16x16@2x.png"),
        (type: "ic12", filename: "icon_32x32@2x.png"),
        (type: "ic07", filename: "icon_128x128.png"),
        (type: "ic13", filename: "icon_128x128@2x.png"),
        (type: "ic08", filename: "icon_256x256.png"),
        (type: "ic14", filename: "icon_256x256@2x.png"),
        (type: "ic09", filename: "icon_512x512.png"),
        (type: "ic10", filename: "icon_512x512@2x.png")
    ]

    var body = Data()
    for representation in representations {
        let png = try Data(contentsOf: iconset.appendingPathComponent(representation.filename))
        guard let type = representation.type.data(using: .ascii), type.count == 4,
              png.count <= Int(UInt32.max) - 8 else {
            throw NSError(domain: "Artwork", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid ICNS representation"])
        }

        body.append(type)
        appendBigEndian(UInt32(png.count + 8), to: &body)
        body.append(png)
    }

    guard body.count <= Int(UInt32.max) - 8 else {
        throw NSError(domain: "Artwork", code: 3, userInfo: [NSLocalizedDescriptionKey: "ICNS output is too large"])
    }

    var icns = Data("icns".utf8)
    appendBigEndian(UInt32(body.count + 8), to: &icns)
    icns.append(body)
    try icns.write(to: outputURL, options: .atomic)
}

func appendBigEndian(_ value: UInt32, to data: inout Data) {
    var bigEndianValue = value.bigEndian
    withUnsafeBytes(of: &bigEndianValue) { bytes in
        data.append(contentsOf: bytes)
    }
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

extension NSShadow {
    static func draw(color: NSColor, blur: CGFloat, offsetY: CGFloat, _ block: () -> Void) {
        let shadow = NSShadow()
        shadow.shadowColor = color
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = NSSize(width: 0, height: offsetY)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        block()
        NSGraphicsContext.restoreGraphicsState()
    }
}
