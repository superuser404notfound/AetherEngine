import Foundation
import CoreVideo
import VideoToolbox
import AetherLibavutil

/// Supplies codec-declared display metadata without mutating immutable VideoToolbox output.
///
/// Frames with matching attachments return unchanged. A mismatch draws
/// into a decoder-owned pool through VideoToolbox's pixel-transfer path, avoiding CPU mapping and
/// per-frame IOSurface allocation. The lock serializes the transfer session and all mutable pool
/// state across VideoToolbox callback queues.
// All mutable session/pool state is protected by lock. Callers own the returned buffer's
// metadata writes; only immutable VT buffers enter the copy path, and each checkout is distinct.
final class VideoToolboxOutputMetadataNormalizer: @unchecked Sendable {
    private struct PoolFormat: Equatable {
        let width: Int
        let height: Int
        let pixelFormat: OSType
    }

    private let lock = NSLock()
    private var transferSession: VTPixelTransferSession?
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolFormat: PoolFormat?
    private var loggedFailure = false

    func applyingOutputMetadata(
        to imageBuffer: CVPixelBuffer,
        isModifiable: Bool,
        colorPrimaries: CFString?,
        transferFunction: CFString?,
        yCbCrMatrix: CFString?,
        pixelAspectRatio: AVRational?,
        hdr10: HDR10StaticMetadataSEI.Values = .none
    ) -> CVPixelBuffer {
        if Self.outputMetadataMatches(
            imageBuffer,
            colorPrimaries: colorPrimaries,
            transferFunction: transferFunction,
            yCbCrMatrix: yCbCrMatrix,
            pixelAspectRatio: pixelAspectRatio,
            hdr10: hdr10
        ) {
            return imageBuffer
        }

        let destination: CVPixelBuffer
        if isModifiable {
            destination = imageBuffer
        } else {
            guard let copiedBuffer = transferToOwnedBuffer(imageBuffer) else {
                logFailureOnce()
                return imageBuffer
            }
            destination = copiedBuffer
            CVBufferRemoveAllAttachments(destination)
            CVBufferPropagateAttachments(imageBuffer, destination)
        }

        Self.applyOutputMetadata(
            to: destination,
            colorPrimaries: colorPrimaries,
            transferFunction: transferFunction,
            yCbCrMatrix: yCbCrMatrix,
            pixelAspectRatio: pixelAspectRatio,
            hdr10: hdr10
        )
        return destination
    }

    private static func applyOutputMetadata(
        to imageBuffer: CVPixelBuffer,
        colorPrimaries: CFString?,
        transferFunction: CFString?,
        yCbCrMatrix: CFString?,
        pixelAspectRatio: AVRational?,
        hdr10: HDR10StaticMetadataSEI.Values
    ) {
        // AE#957: VideoToolbox drops the stream's HDR10 static metadata; nil leaves a value alone.
        if let masteringDisplay = hdr10.masteringDisplay {
            CVBufferSetAttachment(imageBuffer, kCVImageBufferMasteringDisplayColorVolumeKey,
                                  masteringDisplay as CFData, .shouldPropagate)
        }
        if let contentLightLevel = hdr10.contentLightLevel {
            CVBufferSetAttachment(imageBuffer, kCVImageBufferContentLightLevelInfoKey,
                                  contentLightLevel as CFData, .shouldPropagate)
        }
        if let colorPrimaries {
            CVBufferSetAttachment(
                imageBuffer,
                kCVImageBufferColorPrimariesKey,
                colorPrimaries,
                .shouldPropagate
            )
        }
        if let transferFunction {
            CVBufferSetAttachment(
                imageBuffer,
                kCVImageBufferTransferFunctionKey,
                transferFunction,
                .shouldPropagate
            )
        }
        if let yCbCrMatrix {
            CVBufferSetAttachment(
                imageBuffer,
                kCVImageBufferYCbCrMatrixKey,
                yCbCrMatrix,
                .shouldPropagate
            )
        }
        if let pixelAspectRatio {
            let aspect: NSDictionary = [
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey: Int(pixelAspectRatio.num),
                kCVImageBufferPixelAspectRatioVerticalSpacingKey: Int(pixelAspectRatio.den),
            ]
            CVBufferSetAttachment(imageBuffer, kCVImageBufferPixelAspectRatioKey, aspect, .shouldPropagate)
        } else {
            CVBufferRemoveAttachment(imageBuffer, kCVImageBufferPixelAspectRatioKey)
        }
    }

    private static func outputMetadataMatches(
        _ imageBuffer: CVPixelBuffer,
        colorPrimaries: CFString?,
        transferFunction: CFString?,
        yCbCrMatrix: CFString?,
        pixelAspectRatio: AVRational?,
        hdr10: HDR10StaticMetadataSEI.Values
    ) -> Bool {
        // Only a propagating attachment counts as a match: the subtitle compositor's copy carries
        // nothing else, so a matching value marked `.shouldNotPropagate` would be lost there.
        func attachment(_ key: CFString) -> CFTypeRef? {
            var mode = CVAttachmentMode.shouldPropagate
            guard let value = CVBufferCopyAttachment(imageBuffer, key, &mode),
                  mode == .shouldPropagate else { return nil }
            return value
        }

        if let colorPrimaries,
           attachment(kCVImageBufferColorPrimariesKey) as? String != colorPrimaries as String {
            return false
        }
        if let transferFunction,
           attachment(kCVImageBufferTransferFunctionKey) as? String != transferFunction as String {
            return false
        }
        if let yCbCrMatrix,
           attachment(kCVImageBufferYCbCrMatrixKey) as? String != yCbCrMatrix as String {
            return false
        }
        if let masteringDisplay = hdr10.masteringDisplay,
           attachment(kCVImageBufferMasteringDisplayColorVolumeKey) as? Data != masteringDisplay {
            return false
        }
        if let contentLightLevel = hdr10.contentLightLevel,
           attachment(kCVImageBufferContentLightLevelInfoKey) as? Data != contentLightLevel {
            return false
        }
        if let pixelAspectRatio {
            guard let aspect = attachment(kCVImageBufferPixelAspectRatioKey) as? NSDictionary,
                  aspect[kCVImageBufferPixelAspectRatioHorizontalSpacingKey] as? Int
                  == Int(pixelAspectRatio.num),
                  aspect[kCVImageBufferPixelAspectRatioVerticalSpacingKey] as? Int
                  == Int(pixelAspectRatio.den) else {
                return false
            }
        } else if CVBufferCopyAttachment(imageBuffer, kCVImageBufferPixelAspectRatioKey, nil) != nil {
            return false
        }
        return true
    }

    func reset() {
        lock.lock()
        let retiredSession = transferSession
        transferSession = nil
        pixelBufferPool = nil
        poolFormat = nil
        loggedFailure = false
        lock.unlock()
        if let retiredSession {
            VTPixelTransferSessionInvalidate(retiredSession)
        }
    }

    private func transferToOwnedBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }

        if transferSession == nil {
            var createdSession: VTPixelTransferSession?
            let status = VTPixelTransferSessionCreate(
                allocator: kCFAllocatorDefault,
                pixelTransferSessionOut: &createdSession
            )
            guard status == noErr, let createdSession else { return nil }
            VTSessionSetProperty(
                createdSession,
                key: kVTPixelTransferPropertyKey_RealTime,
                value: kCFBooleanTrue
            )
            transferSession = createdSession
        }

        let format = PoolFormat(
            width: CVPixelBufferGetWidth(source),
            height: CVPixelBufferGetHeight(source),
            pixelFormat: CVPixelBufferGetPixelFormatType(source)
        )
        if pixelBufferPool == nil || poolFormat != format {
            var createdPool: CVPixelBufferPool?
            let pixelBufferAttributes: NSDictionary = [
                kCVPixelBufferPixelFormatTypeKey: format.pixelFormat,
                kCVPixelBufferWidthKey: format.width,
                kCVPixelBufferHeightKey: format.height,
                kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            let status = CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                nil,
                pixelBufferAttributes,
                &createdPool
            )
            guard status == kCVReturnSuccess, let createdPool else { return nil }
            pixelBufferPool = createdPool
            poolFormat = format
        }

        guard let transferSession, let pixelBufferPool else { return nil }
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pixelBufferPool,
            &destination
        ) == kCVReturnSuccess, let destination else {
            return nil
        }
        let transferStatus = VTPixelTransferSessionTransferImage(
            transferSession,
            from: source,
            to: destination
        )
        guard transferStatus == noErr || copyPixels(from: source, to: destination) else {
            return nil
        }
        return destination
    }

    /// Failure-only CPU fallback. The normal path stays GPU-side through `VTPixelTransferSession`;
    /// this preserves metadata correctness if a platform rejects a same-format transfer.
    private func copyPixels(
        from source: CVPixelBuffer,
        to destination: CVPixelBuffer
    ) -> Bool {
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else {
            return false
        }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else {
            return false
        }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        let planeCount = CVPixelBufferGetPlaneCount(source)
        guard planeCount == CVPixelBufferGetPlaneCount(destination) else { return false }
        if planeCount == 0 {
            guard let sourceBase = CVPixelBufferGetBaseAddress(source),
                  let destinationBase = CVPixelBufferGetBaseAddress(destination),
                  CVPixelBufferGetDataSize(source) == CVPixelBufferGetDataSize(destination) else {
                return false
            }
            memcpy(destinationBase, sourceBase, CVPixelBufferGetDataSize(source))
            return true
        }

        for plane in 0..<planeCount {
            guard let sourceBase = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                  let destinationBase = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else {
                return false
            }
            let rows = min(
                CVPixelBufferGetHeightOfPlane(source, plane),
                CVPixelBufferGetHeightOfPlane(destination, plane)
            )
            let sourceBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let destinationBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
            let bytesPerRow = min(sourceBytesPerRow, destinationBytesPerRow)
            for row in 0..<rows {
                memcpy(
                    destinationBase.advanced(by: row * destinationBytesPerRow),
                    sourceBase.advanced(by: row * sourceBytesPerRow),
                    bytesPerRow
                )
            }
        }
        return true
    }

    private func logFailureOnce() {
        lock.lock()
        let shouldLog = !loggedFailure
        loggedFailure = true
        lock.unlock()
        if shouldLog {
            EngineLog.emit(
                "[HardwareVideoDecoder] unable to normalize immutable frame metadata",
                category: .swPlayback
            )
        }
    }

    deinit {
        reset()
    }
}
