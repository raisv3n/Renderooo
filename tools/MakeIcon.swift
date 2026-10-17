import AppKit

// Turns icon.png into a macOS app icon (1024×1024 PNG) that macOS 26 shows full-size:
// the artwork sits on Apple's rounded-square tile. Without the tile, macOS shrinks free-form
// icons onto a grey plate.
//
// - Background removal: real transparency, and "fake" transparency (a grey/white checkerboard
//   painted into the pixels) are both removed by flood-filling inward from the image edges.
// - If the artwork already is a tile (a filled rounded square), that tile is scaled to fill the
//   icon shape, its own colour extends to the edges, and nothing is cropped.
// - Otherwise the whole artwork is centred on a navy tile with breathing room.
//
// Usage: MakeIcon <art.png> <out-1024.png>

let args = CommandLine.arguments
guard args.count >= 3, let source = NSImage(contentsOfFile: args[1]),
      let cgSource = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("usage: MakeIcon <art.png> <out-1024.png>")
}

// Pixels as RGBA8.
let width = cgSource.width, height = cgSource.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
pixels.withUnsafeMutableBytes { buffer in
    let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cgSource, in: CGRect(x: 0, y: 0, width: width, height: height))
}

func rgba(_ i: Int) -> (r: Double, g: Double, b: Double, a: Double) {
    (Double(pixels[i * 4]) / 255, Double(pixels[i * 4 + 1]) / 255, Double(pixels[i * 4 + 2]) / 255, Double(pixels[i * 4 + 3]) / 255)
}

/// Transparent, or light and colourless (a painted checkerboard square).
func isBackground(_ i: Int) -> Bool {
    let p = rgba(i)
    if p.a < 0.05 { return true }
    let maxC = max(p.r, p.g, p.b), minC = min(p.r, p.g, p.b)
    // Checkerboards are colourless greys (light and mid grey); the flood starts at the image
    // edges, so colourless artwork inside a coloured tile is never reached.
    return maxC > 0.35 && (maxC - minC) < 0.08
}

// Flood fill from every edge pixel through background-looking pixels.
var background = [Bool](repeating: false, count: width * height)
var stack: [Int] = []
for x in 0..<width { stack.append(x); stack.append((height - 1) * width + x) }
for y in 0..<height { stack.append(y * width); stack.append(y * width + width - 1) }
while let i = stack.popLast() {
    if background[i] || !isBackground(i) { continue }
    background[i] = true
    let x = i % width, y = i / width
    if x > 0 { stack.append(i - 1) }
    if x < width - 1 { stack.append(i + 1) }
    if y > 0 { stack.append(i - width) }
    if y < height - 1 { stack.append(i + width) }
}

// Bounding box of the artwork (top-left origin).
var minX = width, minY = height, maxX = 0, maxY = 0
for y in 0..<height { for x in 0..<width where !background[y * width + x] {
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
} }
guard maxX > minX, maxY > minY else { fatalError("no artwork found") }

// Cut the background out (fully transparent).
for i in 0..<(width * height) where background[i] {
    pixels[i * 4] = 0; pixels[i * 4 + 1] = 0; pixels[i * 4 + 2] = 0; pixels[i * 4 + 3] = 0
}

// Is the artwork already a filled tile? Sample the middle stretch of each side, just inside the box.
func sample(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) { rgba(y * width + x) }
var edgeSamples: [(r: Double, g: Double, b: Double, a: Double)] = []
let bw = maxX - minX, bh = maxY - minY
for t in stride(from: 0.3, through: 0.7, by: 0.05) {
    edgeSamples.append(sample(minX + Int(Double(bw) * t), minY + 4))
    edgeSamples.append(sample(minX + Int(Double(bw) * t), maxY - 4))
    edgeSamples.append(sample(minX + 4, minY + Int(Double(bh) * t)))
    edgeSamples.append(sample(maxX - 4, minY + Int(Double(bh) * t)))
}
let opaque = edgeSamples.filter { $0.a > 0.95 }
let mean = opaque.reduce((r: 0.0, g: 0.0, b: 0.0)) { (r: $0.r + $1.r / Double(opaque.count), g: $0.g + $1.g / Double(opaque.count), b: $0.b + $1.b / Double(opaque.count)) }
let spread = opaque.map { abs($0.r - mean.r) + abs($0.g - mean.g) + abs($0.b - mean.b) }.max() ?? 1
let isTile = opaque.count == edgeSamples.count && spread < 0.12

// Compose the 1024 icon.
let art = pixels.withUnsafeMutableBytes { buffer -> CGImage in
    let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx.makeImage()!
}
let cropped = art.cropping(to: CGRect(x: minX, y: minY, width: bw + 1, height: bh + 1))!

let size = 1024
let out = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: rgb,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
out.interpolationQuality = .high
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)          // Apple's macOS icon grid
let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
out.addPath(shape)
out.clip()

if isTile {
    // The artwork's own tile colour fills the icon shape; the tile is scaled to the full shape.
    out.setFillColor(CGColor(srgbRed: mean.r, green: mean.g, blue: mean.b, alpha: 1))
    out.fill(tile)
    let scale = min(tile.width / CGFloat(cropped.width), tile.height / CGFloat(cropped.height))
    let w = CGFloat(cropped.width) * scale, h = CGFloat(cropped.height) * scale
    out.draw(cropped, in: CGRect(x: tile.midX - w / 2, y: tile.midY - h / 2, width: w, height: h))
} else {
    let colors = [CGColor(srgbRed: 0x1C / 255, green: 0x43 / 255, blue: 0x74 / 255, alpha: 1),
                  CGColor(srgbRed: 0x0E / 255, green: 0x26 / 255, blue: 0x47 / 255, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: rgb, colors: colors, locations: [0, 1])!
    out.drawLinearGradient(gradient, start: CGPoint(x: tile.midX, y: tile.maxY), end: CGPoint(x: tile.midX, y: tile.minY), options: [])
    let inner = tile.insetBy(dx: 58, dy: 58)
    let scale = min(inner.width / CGFloat(cropped.width), inner.height / CGFloat(cropped.height))
    let w = CGFloat(cropped.width) * scale, h = CGFloat(cropped.height) * scale
    out.draw(cropped, in: CGRect(x: inner.midX - w / 2, y: inner.midY - h / 2, width: w, height: h))
}

let result = NSBitmapImageRep(cgImage: out.makeImage()!)
try! result.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print(isTile ? "tile artwork, colour \(String(format: "#%02X%02X%02X", Int(mean.r * 255), Int(mean.g * 255), Int(mean.b * 255)))" : "free-form artwork on navy tile",
      "bbox \(minX),\(minY) \(bw)x\(bh)")
