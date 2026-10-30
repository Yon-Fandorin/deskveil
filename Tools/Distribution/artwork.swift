import AppKit

// Native drawing keeps the app icon and installer artwork reproducible.
func color(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
            green: CGFloat((value >> 8) & 255) / 255,
            blue: CGFloat(value & 255) / 255, alpha: alpha)
}

func png(_ destination: URL, size: NSSize, scale: Int, draw: () -> Void) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
        pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = size
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
    context.translateBy(x: 0, y: size.height)
    context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
}

func text(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat,
          size: CGFloat, weight: NSFont.Weight = .regular, ink: NSColor,
          alignment: NSTextAlignment = .left) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.alignment = alignment
    (value as NSString).draw(in: NSRect(x: x, y: y, width: width, height: 44),
        withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                         .foregroundColor: ink, .paragraphStyle: paragraph])
}

func appIcon(size: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current!.cgContext.scaleBy(x: size / 1024, y: size / 1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 96, y: 96, width: 832, height: 832),
                            xRadius: 184, yRadius: 184)
    let shadow = NSShadow()
    shadow.shadowColor = color(0x123D46, alpha: 0.22)
    shadow.shadowBlurRadius = 28; shadow.shadowOffset = NSSize(width: 0, height: 12)
    shadow.set()
    color(0x164853).setFill(); tile.fill(); NSShadow().set()
    NSGradient(starting: color(0x286773), ending: color(0x123D46))!.draw(in: tile, angle: 90)
    color(0xFFFFFF, alpha: 0.16).setStroke(); tile.lineWidth = 2; tile.stroke()

    let screen = NSBezierPath(roundedRect: NSRect(x: 228, y: 280, width: 568, height: 390), xRadius: 42, yRadius: 42)
    color(0xE2F1E8).setFill(); screen.fill()
    let glass = NSBezierPath(roundedRect: NSRect(x: 250, y: 302, width: 524, height: 346), xRadius: 23, yRadius: 23)
    color(0x205F6A).setFill(); glass.fill()
    NSGraphicsContext.saveGraphicsState(); glass.addClip()
    // The veil descends from the top and conceals most of the screen.
    // Only the lower hem moves in a soft wave; it must not read as a floating ribbon.
    let veil = NSBezierPath()
    veil.move(to: NSPoint(x: 248, y: 300)); veil.line(to: NSPoint(x: 776, y: 300))
    veil.line(to: NSPoint(x: 776, y: 566))
    veil.curve(to: NSPoint(x: 512, y: 574), controlPoint1: NSPoint(x: 678, y: 644), controlPoint2: NSPoint(x: 612, y: 640))
    veil.curve(to: NSPoint(x: 248, y: 580), controlPoint1: NSPoint(x: 410, y: 506), controlPoint2: NSPoint(x: 344, y: 510))
    veil.close()
    let fabricShadow = NSShadow()
    fabricShadow.shadowColor = color(0x071F26, alpha: 0.25)
    fabricShadow.shadowBlurRadius = 28; fabricShadow.shadowOffset = NSSize(width: 0, height: 14)
    fabricShadow.set(); color(0xCDE9DC).setFill(); veil.fill(); NSShadow().set()
    NSGradient(colorsAndLocations: (color(0xF0F8EE), 0), (color(0xD7EDDF), 0.35),
        (color(0xA0CFBC), 0.65), (color(0xE2F3E7), 1))!.draw(in: veil, angle: 0)
    color(0xFFFFFF, alpha: 0.28).setStroke(); veil.lineWidth = 2; veil.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let stand = NSBezierPath()
    stand.move(to: NSPoint(x: 512, y: 670)); stand.line(to: NSPoint(x: 512, y: 730))
    stand.move(to: NSPoint(x: 428, y: 734)); stand.line(to: NSPoint(x: 596, y: 734))
    stand.lineWidth = 23; stand.lineCapStyle = .round
    color(0xE2F1E8).setStroke(); stand.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    fputs("Usage: artwork.swift icon OUTPUT.iconset | background OUTPUT.png VERSION ARCH\n", stderr)
    exit(2)
}
let destination = URL(fileURLWithPath: arguments[2])
if arguments[1] == "icon" {
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let suffix = scale == 2 ? "@2x" : ""
            try png(destination.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"),
                    size: NSSize(width: points, height: points), scale: scale) { appIcon(size: CGFloat(points)) }
        }
    }
} else if arguments[1] == "background", arguments.count == 5 {
    let version = arguments[3], architecture = arguments[4]
    try png(destination, size: NSSize(width: 680, height: 420), scale: 2) {
        color(0xF4F8F7).setFill(); NSRect(x: 0, y: 0, width: 680, height: 420).fill()
        let glow = NSGradient(colorsAndLocations:
            (color(0xA8D5C7, alpha: 0.48), 0),
            (color(0xC5E4DA, alpha: 0.16), 0.55),
            (color(0xC5E4DA, alpha: 0), 1))!
        glow.draw(fromCenter: NSPoint(x: 176, y: 202), radius: 0,
                  toCenter: NSPoint(x: 176, y: 202), radius: 176, options: [])
        text("DeskVeil 설치", x: 40, y: 30, width: 430, size: 23, weight: .semibold, ink: color(0x21304A))
        text("작업은 계속, 자리는 잠시 비움.", x: 40, y: 67, width: 500, size: 14, ink: color(0x5D6C82))
        text(version, x: 520, y: 37, width: 120, size: 11, ink: color(0x7B8799), alignment: .right)

        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 304, y: 202)); arrow.line(to: NSPoint(x: 376, y: 202))
        arrow.move(to: NSPoint(x: 362, y: 188)); arrow.line(to: NSPoint(x: 376, y: 202))
        arrow.line(to: NSPoint(x: 362, y: 216))
        arrow.lineWidth = 2; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
        color(0x7C9BC7).setStroke(); arrow.stroke()

        color(0xE0E7F1).setFill(); NSRect(x: 40, y: 320, width: 600, height: 1).fill()
        text("설치 후", x: 40, y: 337, width: 400, size: 11, weight: .medium, ink: color(0x778498))
        text("응용 프로그램에서 DeskVeil을 열어주세요.",
             x: 40, y: 355, width: 600, size: 14, weight: .medium, ink: color(0x34445F))
        text("앱을 오른쪽 폴더로 옮긴 뒤 실행해주세요.",
             x: 40, y: 382, width: 455, size: 12, ink: color(0x6E7D93))
        let device = architecture == "arm64" ? "Apple Silicon" : architecture
        text(device, x: 510, y: 383, width: 130, size: 11, ink: color(0x7B8799), alignment: .right)
    }
} else { exit(2) }
