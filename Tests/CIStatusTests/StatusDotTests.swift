import AppKit
import XCTest
@testable import CIStatusKit

/// The whole point of the app is a coloured dot, so the pixels are checked
/// rather than trusting the drawing code to look right.
final class StatusDotTests: XCTestCase {

    /// Samples the centre pixel of a rendered dot.
    private struct RGB: Equatable {
        let r: UInt8, g: UInt8, b: UInt8
    }

    private func centerColor(of health: Health) -> RGB {
        let image = StatusDot.image(for: health)
        XCTAssertEqual(image.size.width, 18)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            XCTFail("could not rasterise the dot")
            return RGB(r: 0, g: 0, b: 0)
        }
        let x = bitmap.pixelsWide / 2
        let y = bitmap.pixelsHigh / 2
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
            XCTFail("no colour at centre")
            return RGB(r: 0, g: 0, b: 0)
        }
        return RGB(r: UInt8(color.redComponent * 255),
                   g: UInt8(color.greenComponent * 255),
                   b: UInt8(color.blueComponent * 255))
    }

    /// Template images are recoloured by the system, which would turn every
    /// state black and break the entire feature.
    func testDotIsNotATemplateImage() {
        for health in [Health.ok, .pending, .failing, .unknown] {
            XCTAssertFalse(StatusDot.image(for: health).isTemplate, "\(health) must keep its colour")
        }
    }

    func testEachStateRendersADistinctColour() {
        let green = centerColor(of: .ok)
        let orange = centerColor(of: .pending)
        let red = centerColor(of: .failing)

        XCTAssertGreaterThan(green.g, green.r, "ok should read as green")
        XCTAssertGreaterThan(green.g, 100)

        XCTAssertGreaterThan(red.r, red.g, "failing should read as red")
        XCTAssertGreaterThan(red.r, 100)

        XCTAssertGreaterThan(orange.r, orange.b, "pending should read as orange")
        XCTAssertGreaterThan(orange.g, orange.b)

        XCTAssertNotEqual(green, red)
        XCTAssertNotEqual(green, orange)
        XCTAssertNotEqual(red, orange)
    }

    /// The centre must be filled, not the background of an empty image.
    func testCentreIsOpaqueAndCornersAreNot() {
        let image = StatusDot.image(for: .ok)
        let tiff = image.tiffRepresentation!
        let bitmap = NSBitmapImageRep(data: tiff)!
        let center = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)!
        XCTAssertGreaterThan(center.alphaComponent, 0.9, "the dot should be solid in the middle")

        let corner = bitmap.colorAt(x: 0, y: 0)!
        XCTAssertLessThan(corner.alphaComponent, 0.1, "the dot should have a transparent margin")
    }

    func testImagesAreCached() {
        XCTAssertTrue(StatusDot.image(for: .failing) === StatusDot.image(for: .failing))
    }
}
