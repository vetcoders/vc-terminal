// Native carrier rendering. Founder-supplied raster is the product geometry.
// This generator recolors pixels; it never redraws or rescales the mark.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
func comparePixels(_ actual: NSBitmapImageRep, _ expected: NSBitmapImageRep) {
    precondition(actual.pixelsWide == expected.pixelsWide && actual.pixelsHigh == expected.pixelsHigh)
    for y in 0..<actual.pixelsHigh {
        for x in 0..<actual.pixelsWide {
            // colorAt returns the raw channel values in a generic NSColor.
            // A second color-profile conversion would alter already-sRGB bytes.
            let a = actual.colorAt(x: x, y: y)!
            let e = expected.colorAt(x: x, y: y)!
            precondition(abs(a.redComponent * a.alphaComponent - e.redComponent * e.alphaComponent) < 0.005)
            precondition(abs(a.greenComponent * a.alphaComponent - e.greenComponent * e.alphaComponent) < 0.005)
            precondition(abs(a.blueComponent * a.alphaComponent - e.blueComponent * e.alphaComponent) < 0.005)
            precondition(abs(a.alphaComponent - e.alphaComponent) < 0.005)
        }
    }
}
func nativeBitmap(_ path: String) -> NSBitmapImageRep {
    let image = NSImage(contentsOfFile: path)!
    let result = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 4096, bitsPerPixel: 32
    )!
    let context = CGContext(
        data: result.bitmapData, width: 1024, height: 1024, bitsPerComponent: 8,
        bytesPerRow: 4096, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    image.draw(in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    NSGraphicsContext.restoreGraphicsState()
    return result
}
if let index = CommandLine.arguments.firstIndex(of: "--compare-native") {
    let actual = nativeBitmap(CommandLine.arguments[index + 1])
    let expected = nativeBitmap(CommandLine.arguments[index + 2])
    let a = actual.bitmapData!, e = expected.bitmapData!
    var error = 0.0
    for offset in 0..<(1024 * 1024 * 4) {
        error += abs(Double(a[offset]) - Double(e[offset])) / 255
    }
    let meanError = error / Double(1024 * 1024 * 4)
    // AppKit's Dock setter rasterizes at display scale/profile. Normalize both
    // native images to sRGB; permit only subpixel resampling at edge contours.
    guard meanError < 0.002 else {
        fputs("native image differs: mean channel error \(meanError)\n", stderr)
        exit(1)
    }
    for (x, y) in [(512, 392), (365, 645), (656, 645), (512, 250)] {
        let offset = y * 4096 + x * 4
        for channel in 0..<4 {
            guard abs(Int(a[offset + channel]) - Int(e[offset + channel])) <= 3 else {
                fputs("native image center sample differs\n", stderr)
                exit(1)
            }
        }
    }
    print("native Dock pixels match; mean normalized channel error \(meanError)")
    exit(0)
}
if let index = CommandLine.arguments.firstIndex(of: "--compare") {
    let images = try CommandLine.arguments[(index + 1)...].map {
        NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: $0)))!
    }
    precondition(images.count == 2)
    comparePixels(images[0], images[1])
    print("native decoded carrier pixels match")
    exit(0)
}
let verify = CommandLine.arguments.contains("--verify")
let lightURL = root.appendingPathComponent("vc-terminal-icon-light.png")
let light = NSBitmapImageRep(data: try Data(contentsOf: lightURL))!
precondition(light.pixelsWide == 1024 && light.pixelsHigh == 1024)
precondition(light.bitsPerSample == 8 && light.samplesPerPixel == 4 && light.hasAlpha)
let dark = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied,
    bytesPerRow: 4096, bitsPerPixel: 32
)!
dark.setProperty(.colorSyncProfileData, withValue: NSColorSpace.sRGB.iccProfileData!)
let input = light.bitmapData!
let output = dark.bitmapData!
let background = [11.0, 11.0, 18.0]
let foreground = [224.0, 222.0, 244.0]
for y in 0..<1024 {
    for x in 0..<1024 {
        let source = y * light.bytesPerRow + x * 4
        let target = y * dark.bytesPerRow + x * 4
        output[target + 3] = input[source + 3]
        for channel in 0..<3 {
            let value = Double(input[source + channel])
            // The native light raster is the sole geometry and gloss authority.
            // Ink/antialias tones become cold ink; silver body/highlights retain
            // their luminance order above the navy base. No pixel is relocated.
            let tinted: Double
            if input[source + 3] < 255 {
                // Translucent exterior pixels belong to the native shadow and
                // bevel, never to the three fully opaque interior ink rings.
                tinted = value < 180
                    ? background[channel] * value / 180
                    : background[channel] + (value - 180) * 0.20
            } else {
                tinted = value < 180
                    ? foreground[channel] + (background[channel] - foreground[channel]) * value / 180
                    : background[channel] + (value - 180) * 0.20
            }
            output[target + channel] = input[source + 3] == 0 ? 0 : UInt8(tinted.rounded())
        }
    }
}
let destination = root.appendingPathComponent("vc-terminal-icon-dark.png")
if verify {
    let actual = NSBitmapImageRep(data: try Data(contentsOf: destination))!
    comparePixels(actual, dark)
    for y in 0..<1024 {
        for x in 0..<1024 {
            let original = light.colorAt(x: x, y: y)!
            let tinted = actual.colorAt(x: x, y: y)!
            precondition(tinted.alphaComponent == original.alphaComponent)
            if original.alphaComponent < 1 && original.redComponent < 0.05 {
                // Native black soft-shadow pixels may never become a light rim.
                precondition(tinted.redComponent < 0.05)
            }
        }
    }
    // Ring centers remain tile tones; the canonical black ring samples become ink.
    for (x, y) in [(512, 392), (365, 645), (656, 645)] {
        precondition(light.colorAt(x: x, y: y)!.redComponent > 0.7)
        precondition(actual.colorAt(x: x, y: y)!.redComponent < 0.15)
    }
    for (x, y) in [(512, 250), (230, 645), (791, 645)] {
        precondition(light.colorAt(x: x, y: y)!.redComponent < 0.05)
        precondition(actual.colorAt(x: x, y: y)!.redComponent > 0.8)
    }
    print("verified: exact canonical alpha, contours, hollow centers and pointwise gloss tint")
} else {
    try dark.representation(using: .png, properties: [:])!.write(to: destination)
    print("rendered: dark from exact Founder light raster")
}
