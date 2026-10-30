import AppKit

/// A descending veil conceals most of a monitor. Fill distinguishes the active state.
enum DeskVeilBrand {
    static func mark(size: CGFloat = 24, covered: Bool = true) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let context = NSGraphicsContext.current!.cgContext
            context.scaleBy(x: rect.width / 24, y: rect.height / 24)
            NSColor.labelColor.setStroke()
            let screen = NSBezierPath(roundedRect: NSRect(x: 1, y: 3, width: 22, height: 15.5), xRadius: 2, yRadius: 2)
            screen.lineWidth = 1.5; screen.stroke()
            let veil = NSBezierPath()
            veil.move(to: NSPoint(x: 3, y: 5)); veil.line(to: NSPoint(x: 21, y: 5))
            veil.line(to: NSPoint(x: 21, y: 14))
            veil.curve(to: NSPoint(x: 12, y: 14.3), controlPoint1: NSPoint(x: 17.6, y: 16.8), controlPoint2: NSPoint(x: 15.4, y: 16.6))
            veil.curve(to: NSPoint(x: 3, y: 14.5), controlPoint1: NSPoint(x: 8.6, y: 12), controlPoint2: NSPoint(x: 6.4, y: 12.1))
            veil.close()
            NSColor.labelColor.setFill(); NSColor.labelColor.setStroke()
            if covered { veil.fill() }
            else { veil.lineWidth = 1.5; veil.lineJoinStyle = .round; veil.stroke() }
            let stand = NSBezierPath()
            stand.move(to: NSPoint(x: 12, y: 18.5)); stand.line(to: NSPoint(x: 12, y: 21.5))
            stand.move(to: NSPoint(x: 8, y: 21.5)); stand.line(to: NSPoint(x: 16, y: 21.5))
            stand.lineWidth = 1.5; stand.lineCapStyle = .round; stand.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "DeskVeil"
        return image
    }
}
