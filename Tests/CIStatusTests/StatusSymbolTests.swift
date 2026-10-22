import AppKit
import XCTest
@testable import CIStatusKit

/// A row with no icon is the bug this covers. `Image(systemName:)` hands the menu
/// a template image it may draw as a mask, and a translucent label colour bakes
/// in so faintly the glyph disappears. Both fail silently, so they are asserted
/// here where they at least fail loudly.
final class StatusSymbolTests: XCTestCase {

    private let allStates: [Health] = [.ok, .unknown, .pending, .failing]
    /// The appearances the menu can be drawn in. A colour that only survives one
    /// of them is what makes an icon come and go.
    private let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

    private func bitmap(_ image: NSImage) -> NSBitmapImageRep? {
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    /// Runs `body` with `name` as the current drawing appearance.
    private func drawing<A>(_ name: NSAppearance.Name, _ body: () -> A) -> A {
        var result: A!
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance { result = body() }
        return result
    }

    /// Pixels solid enough to actually be seen, not merely present. A glyph baked
    /// at 55% white counts as blank here, which is the point.
    private func visiblePixelCount(_ image: NSImage) -> Int {
        guard let bmp = bitmap(image) else { return 0 }
        var count = 0
        for y in 0..<bmp.pixelsHigh {
            for x in 0..<bmp.pixelsWide {
                if bmp.colorAt(x: x, y: y)?.alphaComponent ?? 0 > 0.5 { count += 1 }
            }
        }
        return count
    }

    /// Guards the actual cause: a typo in `symbolName` would otherwise only show
    /// up as a blank row at runtime.
    func testEverySymbolNameIsKnownToTheSystem() {
        for health in allStates {
            XCTAssertNotNil(NSImage(systemSymbolName: health.symbolName,
                                    accessibilityDescription: nil),
                            "\(health) uses \"\(health.symbolName)\", which resolves to no symbol")
        }
    }

    /// Every state must paint a readable amount of ink, in every appearance.
    /// The cache is cleared between bakes so this really does re-rasterise each
    /// time rather than checking the same image four times.
    func testEveryStateRendersSomethingVisibleInEveryAppearance() {
        for name in appearances {
            StatusSymbol.resetCache()
            for health in allStates {
                let pixels = drawing(name) { visiblePixelCount(StatusSymbol.image(for: health)) }
                XCTAssertGreaterThan(pixels, 20, """
                    \(health) rendered \(pixels) px in \(name.rawValue); \
                    the icon would be invisible
                    """)
            }
        }
    }

    /// Template images are recoloured or masked by the menu, which is how the
    /// icon went missing. The tint has to survive in the pixels.
    func testSymbolIsNotATemplateImage() {
        for health in allStates {
            XCTAssertFalse(StatusSymbol.image(for: health).isTemplate,
                           "\(health) must keep its colour")
        }
    }

    /// The colour is baked in, so each state has to be distinguishable rather
    /// than collapsing to the same mask.
    func testEachStateKeepsItsOwnColour() throws {
        /// The most saturated pixel, which is the part of the glyph carrying the
        /// tint.
        func dominantTint(_ health: Health) throws -> (r: Double, g: Double, b: Double) {
            let bmp = try XCTUnwrap(bitmap(StatusSymbol.image(for: health)),
                                    "\(health) rendered no bitmap")
            var best: (r: Double, g: Double, b: Double, score: Double)?
            for y in 0..<bmp.pixelsHigh {
                for x in 0..<bmp.pixelsWide {
                    guard let c = bmp.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          c.alphaComponent > 0.9 else { continue }
                    let score = max(c.redComponent, c.greenComponent, c.blueComponent)
                        - min(c.redComponent, c.greenComponent, c.blueComponent)
                    if best == nil || score > best!.score {
                        // Explicit Double: older toolchains (the CI runner's) do not
                        // convert CGFloat to Double inside a tuple literal.
                        best = (Double(c.redComponent), Double(c.greenComponent),
                                Double(c.blueComponent), Double(score))
                    }
                }
            }
            let top = try XCTUnwrap(best, "\(health) rendered no opaque pixel")
            return (top.r, top.g, top.b)
        }

        let green = try dominantTint(.ok)
        let red = try dominantTint(.failing)
        let grey = try dominantTint(.unknown)

        XCTAssertGreaterThan(green.g, green.r, "ok should read as green")
        XCTAssertGreaterThan(red.r, red.g, "failing should read as red")

        // The grey state must still be grey, not the white the old
        // secondaryLabelColor baked in.
        let greySpread = max(grey.r, grey.g, grey.b) - min(grey.r, grey.g, grey.b)
        XCTAssertLessThan(greySpread, 0.1, "unknown should read as grey, got \(grey)")

        // ok and failing must not have collapsed to the same ink.
        let distance = abs(green.r - red.r) + abs(green.g - red.g) + abs(green.b - red.b)
        XCTAssertGreaterThan(distance, 0.3, "ok and failing look identical")
    }

    func testImagesAreCached() {
        for health in allStates {
            XCTAssertTrue(StatusSymbol.image(for: health) === StatusSymbol.image(for: health),
                          "\(health) should be drawn once")
        }
        XCTAssertTrue(StatusSymbol.template("trash", size: 10) === StatusSymbol.template("trash", size: 10))
        XCTAssertTrue(StatusSymbol.baked("circle", color: .systemGreen, size: 13)
                      === StatusSymbol.baked("circle", color: .systemGreen, size: 13))
    }

    /// Window chrome has to keep following light and dark, so the template
    /// variant must stay a template. Baking it would freeze the colour.
    func testTemplateVariantStaysATemplate() {
        XCTAssertTrue(StatusSymbol.template("trash", size: 10).isTemplate,
                      "window symbols must still take their colour from the appearance")
        XCTAssertTrue(StatusSymbol.template("plus.circle", size: 13).isTemplate)
    }

    func testBakedVariantIsNotATemplate() {
        XCTAssertFalse(StatusSymbol.baked("circle", color: .systemGreen, size: 13).isTemplate)
        XCTAssertFalse(StatusSymbol.baked("circle", color: .systemGray, size: 13).isTemplate)
    }

    /// The two variants of one symbol are different images and must not share a
    /// cache entry, or one caller's `isTemplate` would decide the other's.
    func testTemplateAndBakedVariantsDoNotCollide() {
        let asTemplate = StatusSymbol.template("circle", size: 13)
        let asBaked = StatusSymbol.baked("circle", color: .systemGreen, size: 13)
        XCTAssertFalse(asTemplate === asBaked, "one symbol, two cache entries expected")

        // Asking for them in the other order must not change either one.
        let bakedFirst = StatusSymbol.baked("circle", color: .systemGreen, size: 13)
        XCTAssertTrue(StatusSymbol.template("circle", size: 13).isTemplate)
        XCTAssertFalse(bakedFirst.isTemplate)
    }

    /// Size is part of the key, so the caption trash can and the body plus.circle
    /// do not hand back the same pixels.
    func testSizeIsPartOfTheCacheKey() {
        XCTAssertFalse(StatusSymbol.template("plus.circle", size: 10)
                       === StatusSymbol.template("plus.circle", size: 13))
    }

    /// A name this macOS does not have must still draw something, rather than
    /// leaving the gap that started all this.
    func testUnknownNameFallsBackToAVisibleDot() {
        let image = StatusSymbol.template("ciStatus.symbol.that.does.not.exist", size: 13)
        XCTAssertGreaterThan(visiblePixelCount(image), 20,
                             "an unknown name should fall back to a dot, not a blank")
        XCTAssertGreaterThan(visiblePixelCount(
            StatusSymbol.baked("ciStatus.symbol.that.does.not.exist",
                               color: .systemRed, size: 13)), 20)
    }
}
