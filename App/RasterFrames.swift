import Foundation
import ImageIO
import UniformTypeIdentifiers

enum RasterFrames {
    static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, options)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func frame(_ source: CGImageSource, _ index: Int, pixels: Int = 1800) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels
        ] as CFDictionary)
    }

    static func frameDelay(_ source: CGImageSource, index: Int) -> Double {
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
        let group = ["{GIF}", "{PNG}", "{WebP}"].compactMap { props?[$0] as? [String: Any] }.first
        return max(0.02, group?["UnclampedDelayTime"] as? Double ?? group?["DelayTime"] as? Double ?? 0.1)
    }
}
