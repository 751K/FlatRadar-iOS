// Re-encode fully opaque XCTest PNGs without an alpha channel for App Store Connect.
// RGB pixels, dimensions, and color space are preserved; no resizing or retouching.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let context = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        fatalError("Cannot decode RGB PNG: \(path)")
    }
    // Reject actual transparency rather than silently compositing it away.
    guard let check = CGContext(data: nil, width: image.width, height: image.height,
                                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                                    | CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Cannot verify opacity: \(path)")
    }
    check.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let data = check.data else { fatalError("Cannot read opacity: \(path)") }
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    for index in stride(from: 3, to: image.width * image.height * 4, by: 4) {
        guard bytes[index] == 255 else { fatalError("PNG contains actual transparency: \(path)") }
    }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let opaque = context.makeImage() else { fatalError("Cannot encode \(path)") }
    let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".png")
    guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Cannot create PNG destination: \(path)")
    }
    CGImageDestinationAddImage(destination, opaque, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write \(path)") }
    _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    print("Opaque PNG: \(url.lastPathComponent), \(image.width)x\(image.height)")
}
