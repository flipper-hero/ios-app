import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import FlipperKit

/// Renders a Flipper frame the way the device looks: dark pixels on the orange backlight.
public enum ScreenRenderer {
    public static let backlight: (r: UInt8, g: UInt8, b: UInt8) = (255, 130, 0)
    public static let ink: (r: UInt8, g: UInt8, b: UInt8) = (22, 14, 6)

    /// RGBA bitmap at `scale`x, for vision models and previews.
    public static func cgImage(_ frame: FlipperScreenFrame, scale: Int = 4) -> CGImage? {
        let size = frame.displaySize
        let width = size.width * scale, height = size.height * scale
        let pixels = frame.pixels()
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let on = pixels[(y / scale) * size.width + (x / scale)]
                let color = on ? ink : backlight
                let i = (y * width + x) * 4
                bytes[i] = color.r; bytes[i + 1] = color.g; bytes[i + 2] = color.b
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    public static func png(_ frame: FlipperScreenFrame, scale: Int = 4) -> Data? {
        guard let image = cgImage(frame, scale: scale) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
