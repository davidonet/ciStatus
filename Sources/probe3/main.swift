// Finds the status dot by diffing two screenshots of the menu bar: one taken
// before the app launched, one after. Only pixels the app added are classified,
// so system items in the same cluster — including a grey circle that would
// otherwise be read as our own — cannot be mistaken for the dot.
import AppKit

struct Pixel { let x: Int, y: Int, r: Int, g: Int, b: Int }

func load(_ path: String) -> NSBitmapImageRep? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return NSBitmapImageRep(data: data)
}

/// Hue in degrees, 0-360. Returns -1 for greys where hue is meaningless.
func hueDegrees(r: Int, g: Int, b: Int) -> Double {
    let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
    let maxV = max(rf, gf, bf), minV = min(rf, gf, bf)
    let delta = maxV - minV
    guard delta > 0.001 else { return -1 }
    let hue: Double
    if maxV == rf { hue = ((gf - bf) / delta).truncatingRemainder(dividingBy: 6) }
    else if maxV == gf { hue = (bf - rf) / delta + 2 }
    else { hue = (rf - gf) / delta + 4 }
    let degrees = hue * 60
    return degrees < 0 ? degrees + 360 : degrees
}

let beforePath = CommandLine.arguments[1]
let afterPath = CommandLine.arguments[2]
let xStart = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3])! : 0

guard let before = load(beforePath), let after = load(afterPath) else {
    print("could not read the screenshots")
    exit(1)
}
guard before.pixelsWide == after.pixelsWide, before.pixelsHigh == after.pixelsHigh else {
    print("screenshot sizes differ")
    exit(1)
}

var added: [Pixel] = []
// Stay clear of the bottom rows, which can clip the window below the bar.
for y in 0..<min(after.pixelsHigh, 30) {
    for x in xStart..<after.pixelsWide {
        guard let a = after.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
              let b = before.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        let ar = Int(a.redComponent * 255), ag = Int(a.greenComponent * 255), ab = Int(a.blueComponent * 255)
        let br = Int(b.redComponent * 255), bg = Int(b.greenComponent * 255), bb = Int(b.blueComponent * 255)
        guard abs(ar - br) + abs(ag - bg) + abs(ab - bb) > 90 else { continue }
        // Only pixels that got brighter are new marks, not repaints of old ones.
        guard max(ar, ag, ab) > max(br, bg, bb) else { continue }
        added.append(Pixel(x: x, y: y, r: ar, g: ag, b: ab))
    }
}

guard !added.isEmpty else { print("the app added no pixels to the menu bar"); exit(2) }

// Adding a menu bar item shifts every item to its right, so the diff also
// catches the system glyphs that moved. Our item is the leftmost addition, so
// work on the leftmost cluster of changed pixels only.
added.sort { $0.x < $1.x }
var clusters: [[Pixel]] = []
for pixel in added {
    if var last = clusters.last, pixel.x - (last.last?.x ?? pixel.x) <= 6 {
        last.append(pixel)
        clusters[clusters.count - 1] = last
    } else {
        clusters.append([pixel])
    }
}

let cluster = clusters[0]
let x0 = cluster.map(\.x).min()!, x1 = cluster.map(\.x).max()!
let y0 = cluster.map(\.y).min()!, y1 = cluster.map(\.y).max()!
let n = cluster.count
let r = cluster.reduce(0) { $0 + $1.r } / n
let g = cluster.reduce(0) { $0 + $1.g } / n
let b = cluster.reduce(0) { $0 + $1.b } / n
let w = x1 - x0 + 1, h = y1 - y0 + 1
print("dot \(w)x\(h) at \(x0),\(y0) from \(n) px rgb=\(r),\(g),\(b)")

guard (6...30).contains(w), (6...30).contains(h), abs(w - h) <= 10 else {
    print("=> SHAPE (not a round dot)")
    exit(3)
}

// Hue based rather than a red-vs-green comparison: systemOrange also has more
// red than green, so a naive check reports it as red.
let name: String
let hue = hueDegrees(r: r, g: g, b: b)
if max(r, g, b) - min(r, g, b) < 30 { name = "GREY" }
else if hue < 15 || hue >= 345 { name = "RED" }
else if hue < 45 { name = "ORANGE" }
else if hue < 165 { name = "GREEN" }
else { name = "OTHER" }

print("=> \(name)")
exit(name == "OTHER" ? 3 : 0)
