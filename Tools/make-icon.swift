import AppKit

// Builds a transparent-cornered icon PNG from the square logo artwork.
//
// logo.png ships without an alpha channel, so its rounded square sits on an opaque
// black field. Used as-is, every macOS surface that expects a transparent icon -- Dock,
// Finder, Cmd-Tab -- would render a black box with the artwork inside it.
//
// The corners are cleared by flood-filling the near-black region inward from the four
// corners. Flood fill rather than a rounded-rect mask, for two reasons: it needs no
// guess about the artwork's corner radius, and it cannot touch the dolphin's black eye,
// which is enclosed by white pixels and so is never reached from the border.

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write("usage: make-icon <input.png> <output.png>\n".data(using: .utf8)!)
    exit(2)
}

let inputURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])

guard let source = NSImage(contentsOf: inputURL),
      let tiff = source.tiffRepresentation,
      let input = NSBitmapImageRep(data: tiff) else {
    FileHandle.standardError.write("could not read \(inputURL.path)\n".data(using: .utf8)!)
    exit(1)
}

let width = input.pixelsWide
let height = input.pixelsHigh

// Redraw into a known RGBA8 layout; colorAt/setColor on an arbitrary source rep is both
// slow and sensitive to the original's format.
guard let output = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: width * 4, bitsPerPixel: 32
) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
input.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
NSGraphicsContext.restoreGraphicsState()

guard let pixels = output.bitmapData else { exit(1) }

/// Luminance below which a pixel counts as background.
///
/// Must stay clear of the artwork itself: the darkest corner of the logo's gradient
/// (#76013A) has luminance 42, so anything near that eats holes in the bottom of the
/// icon. Pure black scores 0, which leaves plenty of headroom at 20.
let threshold = Int(ProcessInfo.processInfo.environment["ICON_THRESHOLD"] ?? "") ?? 20

func isBackground(_ index: Int) -> Bool {
    let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
    return (r * 299 + g * 587 + b * 114) / 1000 < threshold
}

var visited = [Bool](repeating: false, count: width * height)
var stack: [Int] = []

for corner in [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)] {
    stack.append(corner.1 * width + corner.0)
}

var cleared = 0
while let position = stack.popLast() {
    guard !visited[position] else { continue }
    let index = position * 4
    guard isBackground(index) else { continue }
    visited[position] = true
    pixels[index + 3] = 0   // clear alpha; RGB is irrelevant once fully transparent
    cleared += 1

    let x = position % width
    let y = position / width
    if x > 0 { stack.append(position - 1) }
    if x < width - 1 { stack.append(position + 1) }
    if y > 0 { stack.append(position - width) }
    if y < height - 1 { stack.append(position + width) }
}

guard let data = output.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: outputURL)
print("cleared \(cleared) background pixels (\(cleared * 100 / (width * height))% of canvas) -> \(outputURL.lastPathComponent)")
