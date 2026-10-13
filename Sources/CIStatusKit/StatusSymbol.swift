import AppKit
import Foundation

/// SF Symbols drawn by the app, resolved once and cached.
///
/// `Image(systemName:)` looks a symbol up lazily every time the view is drawn
/// and hands back a *template* image, which the host is then free to draw as a
/// mask rather than as artwork. In the menu that left a row with no icon at all.
/// Resolving once and caching removes the repeated lookup, and picking how the
/// result is handed over removes the masking:
///
/// - `image(for:)` bakes the tint into the pixels, like `StatusDot` does, for the
///   menu rows and any toggle whose colour must not depend on the appearance.
/// - `template(_:size:weight:)` stays a template, so window chrome keeps
///   following light and dark and any `.foregroundStyle` the caller applies.
public enum StatusSymbol {

    /// The menu row icon for a health, tinted and non-template.
    public static func image(for health: Health, size: CGFloat = 13) -> NSImage {
        baked(health.symbolName, color: StatusDot.color(for: health), size: size)
    }

    /// A cached symbol left as a template, so it takes its colour from the
    /// surrounding appearance. Falls back to the same coloured dot if the
    /// running system does not know the name, because a blank slot is worse
    /// than a plain one.
    public static func template(_ name: String, size: CGFloat,
                                weight: NSFont.Weight = .regular) -> NSImage {
        let image = resolve(name, size: size, weight: weight)
        image.isTemplate = true
        return image
    }

    /// A cached symbol with the tint baked into the pixels. Use when the colour
    /// has to survive whatever the host does with a template image.
    public static func baked(_ name: String, color: NSColor, size: CGFloat,
                             weight: NSFont.Weight = .regular) -> NSImage {
        let key = Entry(name: name, size: size, weight: weight, baked: color)
        if let cached = cache[key] { return cached }

        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image: NSImage
        if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            image = symbol
        } else {
            image = dot(color: color, size: size)
        }
        // Without this the system treats the image as a mask and discards colour.
        image.isTemplate = false
        cache[key] = image
        return image
    }

    private static func resolve(_ name: String, size: CGFloat,
                                weight: NSFont.Weight) -> NSImage {
        let key = Entry(name: name, size: size, weight: weight, baked: nil)
        if let cached = cache[key] { return cached }

        let image: NSImage
        if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight)) {
            image = symbol
        } else {
            // Resolved here, not inside a drawing handler: a handler would look
            // the symbol up again on every draw, which is the lookup this type
            // exists to remove.
            image = dot(color: StatusDot.color(for: .unknown), size: size)
        }
        cache[key] = image
        return image
    }

    private static func dot(color: NSColor, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false, drawingHandler: { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        })
    }

    /// A tint is part of the key because the baked and template variants of the
    /// same symbol are different images.
    private struct Entry: Hashable {
        let name: String
        let size: CGFloat
        let weight: NSFont.Weight
        let baked: NSColor?
    }

    private static var cache: [Entry: NSImage] = [:]

    /// Drops the cache so each appearance is genuinely re-baked. Internal, not
    /// public: nothing at runtime has a reason to redraw.
    internal static func resetCache() { cache.removeAll() }
}
