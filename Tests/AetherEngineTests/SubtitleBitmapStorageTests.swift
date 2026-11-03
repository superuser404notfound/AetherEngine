import CoreGraphics
import Foundation
import Testing
@testable import AetherEngine

struct SubtitleBitmapStorageTests {
    @Test("retained subtitle images preserve rendered alpha after temporary storage is released")
    func losslessPixelsAndProviderLifetime() throws {
        let width = 256, height = 32
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    let alpha = x
                    bytes[offset] = UInt8(((y * 7 % 256) * alpha + 127) / 255)
                    bytes[offset + 1] = UInt8(((x * 13 % 256) * alpha + 127) / 255)
                    bytes[offset + 2] = UInt8(((x * 23 % 256) * alpha + 127) / 255)
                    bytes[offset + 3] = UInt8(alpha)
                }
            }
        }
        let original = try #require(makeImage(pixels, width: width, height: height))
        let retained = try #require(autoreleasepool { EmbeddedSubtitleDecoder.retainedBitmap(original) })
        #expect(retained.encodedByteCount > 0)
        #expect(retained.image.width == width)
        #expect(retained.image.height == height)
        #expect(!retained.image.shouldInterpolate)
        #expect(render(retained.image) == render(original))
        // Repeated presentation and backward seek use the same retained provider.
        #expect(render(retained.image) == render(original))
    }

    @Test("flat subtitle pixels retain compressed backing rather than a full RGBA plane")
    func flatSubtitleStorageIsSmaller() throws {
        let width = 1024, height = 96
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for y in 8..<88 {
                for x in 16..<1008 where (x + y) % 12 < 4 {
                    let offset = (y * width + x) * 4
                    bytes[offset] = 128; bytes[offset + 1] = 64
                    bytes[offset + 2] = 32; bytes[offset + 3] = 128
                }
            }
        }
        let original = try #require(makeImage(pixels, width: width, height: height))
        let retained = try #require(EmbeddedSubtitleDecoder.retainedBitmap(original))
        #expect(retained.encodedByteCount < pixels.count)
        #expect(render(retained.image) == render(original))
        let image = SubtitleImage(cgImage: retained.image, position: .zero,
                                  encodedBackingBytes: retained.encodedByteCount)
        #expect(image.encodedBackingBytes == retained.encodedByteCount)
    }

    private func makeImage(_ data: Data, width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private func render(_ image: CGImage) -> Data {
        var data = Data(count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }
}
