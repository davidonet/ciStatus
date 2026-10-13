import AppKit
import Foundation

/// Renders the menu bar dot.
///
/// Menu bar icons are drawn as template images, which strip colour, so the
/// tint has to be baked into the pixels with `isTemplate = false`. A plain
/// SF Symbol would render black no matter what colour is applied.
public enum StatusDot {
    /// Drawn once per health and cached, so this is not on the per-frame path.
    public static func image(for health: Health, size: CGFloat = 18) -> NSImage {
        if let cached = cache[health] { return cached }

        let image = NSImage(size: NSSize(width: size, height: size),
                            flipped: false,
                            drawingHandler: { rect in
            // Leave a margin so the dot is not flush with the menu bar edges.
            let inset = rect.insetBy(dx: 2.5, dy: 2.5)
            color(for: health).setFill()
            NSBezierPath(ovalIn: inset).fill()
            return true
        })
        // Without this the system treats the image as a mask and discards colour.
        image.isTemplate = false
        cache[health] = image
        return image
    }

    public static func color(for health: Health) -> NSColor {
        switch health {
        case .ok:      return .systemGreen
        case .pending: return .systemOrange
        case .failing: return .systemRed
        // Not `secondaryLabelColor`: that is a translucent label colour, which
        // resolves to white at 55% alpha. A dot survives that because it is a
        // solid circle, but a symbol is thin strokes, and baking it at 55% white
        // left rows with no icon at all on a light menu — depending on which
        // appearance happened to be current when it rasterised. This is opaque
        // and still reads as grey in both appearances.
        case .unknown: return .systemGray
        }
    }

    private static var cache: [Health: NSImage] = [:]
}
