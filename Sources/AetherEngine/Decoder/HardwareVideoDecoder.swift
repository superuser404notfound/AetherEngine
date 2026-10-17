import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// VTDecompressionSession-backed HEVC decoder for the SoftwarePlaybackHost pipeline.
/// Owns the decoded-frame pool, IOSurface lifetime, and session teardown explicitly
/// (AVPlayer's opaque state grows unbounded on long 4K HDR sessions).
/// Same surface as SoftwareVideoDecoder so the host can swap without rewiring the demux loop.
final class HardwareVideoDecoder: VideoDecodingPipeline, @unchecked Sendable {

    // MARK: - Public surface (mirrors SoftwareVideoDecoder)

    /// Guarded by `skipLock` (not `lock`): close() holds `lock` across the VT drain that calls back into onFrame,
    /// so using `lock` here would deadlock. Multi-word closure swap is a data race without the guard.
    var onFrame: DecodedFrameHandler? {
        get { skipLock.lock(); defer { skipLock.unlock() }; return _onFrame }
        set { skipLock.lock(); _onFrame = newValue; skipLock.unlock() }
    }
    private var _onFrame: DecodedFrameHandler?
    /// Not yet wired on the VT side (follow-up: read AV_PKT_DATA_DYNAMIC_HDR10_PLUS before decode,
    /// mirror SoftwareVideoDecoder.extractHDR10PlusBytes). Flag kept so host wiring stays identical to SW path.
    var onFirstHDR10PlusDetected: (@Sendable () -> Void)?
    var onA53Captions: (@Sendable ([CCDataParser.CCTriplet], Double) -> Void)?
    var onDecodedFormat: (@Sendable (DecodedVideoFormat) -> Void)?
    private var streamColor = ColorDescription.unspecified
    private var streamCodecID = AV_CODEC_ID_NONE
    private var streamProfile = AV_PROFILE_UNKNOWN
    private var reportedPixelBufferType: OSType = 0

    /// Skip pre-seek RASL frames to avoid the "fast forward" effect; decoded for reference but not delivered.
    /// Guarded by `skipLock` not `lock`: close() holds `lock` across VTDecompressionSessionWaitForAsynchronousFrames,
    /// which waits for the very callback that would need it (deadlock). CMTime is multi-word: old unsynchronized access was torn-read + ARC race.
    var skipUntilPTS: CMTime? {
        get { skipLock.lock(); defer { skipLock.unlock() }; return _skipUntilPTS }
        set { skipLock.lock(); _skipUntilPTS = newValue; skipLock.unlock() }
    }
    private var _skipUntilPTS: CMTime?
    private let skipLock = NSLock()

    /// Clear the skip threshold only if it is still the one we acted on.
    private func clearSkip(ifStillAt threshold: CMTime) {
        skipLock.lock()
        if let current = _skipUntilPTS, CMTimeCompare(current, threshold) == 0 {
            _skipUntilPTS = nil
        }
        skipLock.unlock()
    }

    // MARK: - Internals

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var timeBase: AVRational = AVRational(num: 1, den: 90000)
    private var width: Int32 = 0
    private var height: Int32 = 0

    /// Color metadata from codecpar, re-applied to every CVPixelBuffer.
    /// VTDecompressionSession should propagate these from SPS+hvcC but has been observed not to;
    /// without them an HDR buffer renders as desaturated SDR on AVSampleBufferDisplayLayer.
    private var colorPrimaries: CFString?
    private var colorTransfer: CFString?
    private var colorMatrix: CFString?

    /// #354: the stream's pixel aspect ratio, re-applied to every CVPixelBuffer for the same reason
    /// the colorimetry is: nothing else puts it there. The renderer builds its format description
    /// from the delivered buffer, so a ratio that is not an attachment on that buffer never reaches
    /// the layer, and anamorphic content is displayed at its coded dimensions. nil for square pixels
    /// and for a ratio the policy rejects, which is the case where coded dimensions ARE correct.
    ///
    /// Resolved once at `open()`, not per frame: VT delivers pixel buffers rather than `AVFrame`s, so
    /// the per-frame source `SoftwareVideoDecoder` prefers does not exist here. That also makes the
    /// #177 latch unnecessary, since one resolution cannot oscillate.
    private var pixelAspectRatio: AVRational?

    /// Protects `session` across the demux thread (decode), main thread (close/flush), and VT callback (delivery).
    private let lock = NSLock()

    /// When true, wrap the packet's AVBuffer with a CMBlockBuffer that holds
    /// an `av_buffer_ref` and unrefs it on disposal (dolby-vision-fel.md §5.4).
    var useCustomBlockSource: Bool = false

    #if DEBUG
    /// Called after a packet has been handed to VideoToolbox (whatever the status it returned), and
    /// not for one the epoch gate or a missing session refused.
    var onSubmittedToVideoToolboxForTesting: (() -> Void)?
    var onBlockBufferAllocatedForTesting: ((CMBlockBuffer) -> Void)?
    #endif

    /// AE#492: the epoch a fed packet must carry. Guarded by `epochLock`, a leaf lock held only for a
    /// read or a write of this integer (nothing is taken, awaited or called while it is held), so
    /// `DualLayerVideoDecoder` can move this decoder's epoch from inside its own critical section
    /// without nesting into `lock`, which `decode` may hold across a blocking VideoToolbox call whose
    /// output callbacks need the owner's lock. `decode` and `flush()` still read and bump it while
    /// holding `lock`, so a flush and a feed cannot interleave; `adoptFeedEpoch` alone moves it
    /// without `lock`, and only ever to the owner's current epoch.
    private var _feedEpoch: UInt64 = 0
    private let epochLock = NSLock()
    private var currentEpoch: UInt64 {
        epochLock.lock(); defer { epochLock.unlock() }; return _feedEpoch
    }
    var feedEpoch: UInt64 { currentEpoch }

    /// Moves this decoder onto the feed epoch its owner is already in. `DualLayerVideoDecoder` calls it
    /// (a) when it opens the enhancement decoder lazily, after a `flush()` may have moved its own
    /// epoch, and (b) from inside its `flush()` critical section, so that a post-seek packet fed with
    /// the new epoch while the owner is still draining this decoder is accepted, instead of being
    /// dropped as stale by a decoder that has not yet been flushed. Takes only `epochLock`.
    func adoptFeedEpoch(_ epoch: UInt64) {
        epochLock.lock(); _feedEpoch = epoch; epochLock.unlock()
    }

    /// AE#739: the system invalidates the session behind our back (iOS screen lock, media services
    /// reset), after which every `VTDecompressionSessionDecodeFrame` returns `kVTInvalidSessionErr`.
    /// Fired once per lost session, on the decode thread. The owner decides when to `rebuildSession()`,
    /// because only it knows whether the app is in the foreground and where the playhead is.
    var onSessionLost: (@Sendable () -> Void)? {
        get { skipLock.lock(); defer { skipLock.unlock() }; return _onSessionLost }
        set { skipLock.lock(); _onSessionLost = newValue; skipLock.unlock() }
    }
    private var _onSessionLost: (@Sendable () -> Void)?

    /// AE#739, all guarded by `lock`. `sessionLost` drops every packet instead of feeding a dead
    /// session; `awaitingKeyframe` drops packets after a rebuild until one the new session can start
    /// from.
    private var sessionLost = false
    private var awaitingKeyframe = false
    private var droppedAwaitingKeyframe = 0
    private var decoderSpecification: NSDictionary?
    /// Guarded by `lock`. False for a session opened from parameter sets, which `makeSession` and a
    /// rebuild then create without `PropagatePerFrameHDRDisplayMetadata`.
    private var propagatesHDRDisplayMetadata = true
    private var pixelBufferAttributes: NSDictionary?

    /// Heap-allocated box carrying a weak self reference for the C decompression callback's refCon.
    /// Separate object so we can pass UnsafeMutablePointer<RefConBox> to VT without unsafe bit-casts.
    /// `fileprivate` so the file-level C callback can access the type.
    private var refConBox: Unmanaged<RefConBox>?

    fileprivate final class RefConBox {
        weak var decoder: HardwareVideoDecoder?
        init(_ decoder: HardwareVideoDecoder) { self.decoder = decoder }
    }

    /// Keeps `packet.buf` alive for the lifetime of a CMBlockBuffer that wraps
    /// the packet's data without copying it (dolby-vision-fel.md §5.4).
    final class CustomBlockSource {
        var avBuf: UnsafeMutablePointer<AVBufferRef>?
        let dataPtr: UnsafeMutableRawPointer
        /// Set by the block source's `FreeBlock`, which releases the retain the refCon carries. CoreMedia
        /// may call it from inside a failed `CMBlockBufferCreateWithMemoryBlock` (after `AllocateBlock`),
        /// and `makeBlockBuffer` must then not release that retain a second time.
        var freeBlockRan = false

        /// `data` is the packet's own payload pointer. It is not always `buf->data`: the Matroska
        /// demuxer hands out packets whose `data` sits inside a larger buffer (observed at +4 on P7
        /// MKV remuxes), so block memory taken from `buf->data` starts early and VideoToolbox sees
        /// a corrupt sample (-12909). Defaults to `buf->data` for callers that own the whole buffer.
        init?(buf: UnsafeMutablePointer<AVBufferRef>, data: UnsafeMutablePointer<UInt8>? = nil) {
            guard let data = data ?? buf.pointee.data, let ref = av_buffer_ref(buf) else { return nil }
            self.avBuf = ref
            self.dataPtr = UnsafeMutableRawPointer(data)
        }

        func releaseBuffer() {
            if avBuf != nil {
                av_buffer_unref(&avBuf)
            }
        }

        deinit {
            releaseBuffer()
        }
    }

    /// Wraps a packet's payload in a CMBlockBuffer without copying it. The block buffer owns
    /// `blockSource` (and with it the `av_buffer_ref` of `packet.buf`) until CoreMedia frees the
    /// block; if the buffer cannot be created the reference is released here, so the caller has
    /// nothing to clean up. `dataLength` is the size of the payload when it differs from the block
    /// (only a test needs that, to make the creation fail).
    static func makeBlockBuffer(wrapping blockSource: CustomBlockSource, size: Int, dataLength: Int? = nil) -> (buffer: CMBlockBuffer?, status: OSStatus) {
        var source = CMBlockBufferCustomBlockSource(
            version: kCMBlockBufferCustomBlockSourceVersion,
            AllocateBlock: { refCon, _ in
                guard let refCon else { return nil }
                let holder = Unmanaged<CustomBlockSource>.fromOpaque(refCon).takeUnretainedValue()
                return holder.dataPtr
            },
            FreeBlock: { refCon, _memoryBlock, _size in
                guard let refCon else { return }
                let holder = Unmanaged<CustomBlockSource>.fromOpaque(refCon).takeRetainedValue()
                holder.freeBlockRan = true
                holder.releaseBuffer()
            },
            refCon: Unmanaged.passRetained(blockSource).toOpaque()
        )
        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: size,
            blockAllocator: kCFAllocatorNull,
            customBlockSource: &source,
            offsetToData: 0,
            dataLength: dataLength ?? size,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        // `blockSource` is still held by this frame, so reading the flag is safe even after FreeBlock
        // dropped the refCon's retain. On a failure CoreMedia calls FreeBlock synchronously or not at
        // all; release here only in the second case.
        if status != kCMBlockBufferNoErr, !blockSource.freeBlockRan, let refCon = source.refCon {
            Unmanaged<CustomBlockSource>.fromOpaque(refCon).takeRetainedValue().releaseBuffer()
        }
        return (blockBuffer, status)
    }

    // MARK: - Lifecycle

    func open(stream: UnsafeMutablePointer<AVStream>, onFrame: @escaping DecodedFrameHandler) throws {
        self.onFrame = onFrame

        guard let codecpar = stream.pointee.codecpar else {
            throw VideoDecoderError.noCodecParameters
        }

        timeBase = stream.pointee.time_base
        width = codecpar.pointee.width
        height = codecpar.pointee.height

        // #354: both declared sources, because only one of them is the container's. The bitstream
        // ratio reaches codecpar, while a container-declared one reaches AVStream alone (Matroska's
        // DisplayWidth quotient, MP4's `pasp`), which is where every DVD remuxed to MKV carries it.
        pixelAspectRatio = Self.resolvePixelAspectRatio(
            bitstream: codecpar.pointee.sample_aspect_ratio,
            container: stream.pointee.sample_aspect_ratio,
            width: width,
            height: height
        )
        if let sar = pixelAspectRatio {
            EngineLog.emit(
                "[HWDecoder] SAR \(sar.num):\(sar.den) on \(width)x\(height) "
                + "(bitstream=\(codecpar.pointee.sample_aspect_ratio.num):"
                + "\(codecpar.pointee.sample_aspect_ratio.den) "
                + "container=\(stream.pointee.sample_aspect_ratio.num):"
                + "\(stream.pointee.sample_aspect_ratio.den))",
                category: .swPlayback
            )
        }

        guard codecpar.pointee.codec_id == AV_CODEC_ID_HEVC else {
            throw VideoDecoderError.unsupportedCodec(id: codecpar.pointee.codec_id.rawValue)
        }

        // 1. Build CMVideoFormatDescription from the hvcC extradata via
        //    kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms (same shape AVFoundation uses for .mp4/.mkv).
        guard let extradata = codecpar.pointee.extradata, codecpar.pointee.extradata_size > 0 else {
            throw VideoDecoderError.noExtradata
        }
        let hvcCData = Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
        var fd: CMVideoFormatDescription?
        let atomsDict: NSDictionary = ["hvcC": hvcCData]
        let extensions: NSDictionary = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atomsDict,
        ]
        let fdStatus = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC,
            width: width,
            height: height,
            extensions: extensions,
            formatDescriptionOut: &fd
        )
        guard fdStatus == noErr, let formatDesc = fd else {
            throw VideoDecoderError.formatDescriptionFailed(status: fdStatus)
        }
        formatDescription = formatDesc

        // 2. Require hardware so VT fails outright rather than silently falling back to SW
        //    (which would show only as pathological CPU + frame drops at 4K).
        let decoderSpec: NSDictionary = [
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true,
        ]

        // 3. Pixel buffer attributes: 10-bit biplanar for HDR, 8-bit for SDR; IOSurface-backed for Metal rendering.
        let bitsPerSample = codecpar.pointee.bits_per_raw_sample
        let isHDRTransfer = ColorAttachments.isHDRTransfer(codecpar.pointee.color_trc)
        let use10Bit = bitsPerSample > 8 || isHDRTransfer

        streamColor = ColorDescription(codecpar: codecpar)
        streamCodecID = codecpar.pointee.codec_id
        streamProfile = codecpar.pointee.profile
        self.colorPrimaries = ColorAttachments.primaries(codecpar.pointee.color_primaries)
        self.colorTransfer = ColorAttachments.transfer(codecpar.pointee.color_trc)
        self.colorMatrix = ColorAttachments.matrix(codecpar.pointee.color_space)
        let pixelFormat: OSType = use10Bit
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        let pixelBufferAttrs: NSDictionary = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
            kCVPixelBufferMetalCompatibilityKey: true,
        ]

        decoderSpecification = decoderSpec
        pixelBufferAttributes = pixelBufferAttrs

        // 4. Output callback: C function dispatches into handleDecodedFrame via refCon.
        let box = RefConBox(self)
        let unmanaged = Unmanaged.passRetained(box)
        refConBox = unmanaged

        let created = makeSession(formatDescription: formatDesc, refCon: unmanaged)
        guard let createdSession = created.session else {
            unmanaged.release()
            refConBox = nil
            throw VideoDecoderError.sessionCreationFailed(status: created.status)
        }
        session = createdSession

        EngineLog.emit(
            "[HardwareVideoDecoder] opened HEVC \(width)x\(height) "
            + "\(use10Bit ? "10-bit" : "8-bit") "
            + "transfer=\(codecpar.pointee.color_trc.rawValue)",
            category: .swPlayback
        )
    }

    /// The one place a session is created, so `open()` and `rebuildSession()` cannot drift apart.
    private func makeSession(
        formatDescription: CMVideoFormatDescription, refCon: Unmanaged<RefConBox>
    ) -> (session: VTDecompressionSession?, status: OSStatus) {
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: hwDecoderOutputCallback,
            decompressionOutputRefCon: refCon.toOpaque()
        )
        var sessionOut: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: decoderSpecification,
            imageBufferAttributes: pixelBufferAttributes,
            outputCallback: &callback,
            decompressionSessionOut: &sessionOut
        )
        guard status == noErr, let created = sessionOut else { return (nil, status) }
        // Pass through per-frame HDR metadata for correct tone mapping; unknown-key set returns -12911 on older OSes (swallowed).
        // Not on a session opened from parameter sets: see `open(parameterSets:timeBase:onFrame:)`.
        if propagatesHDRDisplayMetadata {
            VTSessionSetProperty(
                created,
                key: kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata,
                value: kCFBooleanTrue
            )
        }
        return (created, noErr)
    }

    /// AE#739: replace the session with a fresh one built from the same format description and
    /// attributes, keeping the refCon box so every callback and setting carries over. Bumps the feed
    /// epoch and drops packets until the next keyframe, which is the first one a new session can
    /// decode. Returns false when VT refuses (the app is still in the background, typically); the
    /// decoder then stays lost and drops every packet until a later call succeeds.
    @discardableResult
    func rebuildSession() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let formatDescription, let refConBox else { return false }
        if let old = session {
            VTDecompressionSessionInvalidate(old)
            session = nil
        }
        epochLock.lock(); _feedEpoch &+= 1; epochLock.unlock()
        let created = makeSession(formatDescription: formatDescription, refCon: refConBox)
        guard let fresh = created.session else {
            sessionLost = true
            EngineLog.emit(
                "[HardwareVideoDecoder] AE#739 session rebuild refused (status \(created.status))",
                category: .swPlayback
            )
            return false
        }
        session = fresh
        sessionLost = false
        awaitingKeyframe = true
        droppedAwaitingKeyframe = 0
        EngineLog.emit("[HardwareVideoDecoder] AE#739 session rebuilt", category: .swPlayback)
        return true
    }

    #if DEBUG
    /// Invalidate the live session without forgetting it, which is what the system does on an iOS
    /// screen lock: the next decode returns `kVTInvalidSessionErr`. For the aetherctl harness.
    func invalidateSessionForTesting() {
        lock.lock()
        if let session { VTDecompressionSessionInvalidate(session) }
        lock.unlock()
    }
    #endif

    /// Opens a decoder session from raw HEVC parameter sets (VPS, SPS, PPS), used for the Enhancement Layer (EL)
    /// in Dolby Vision Profile 7 dual-layer decoding.
    func open(
        parameterSets: [[UInt8]],
        timeBase: AVRational,
        onFrame: @escaping DecodedFrameHandler
    ) throws {
        self.onFrame = onFrame
        self.timeBase = timeBase

        guard parameterSets.count >= 3 else {
            throw VideoDecoderError.noExtradata
        }

        var ptrs: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        var allocations: [UnsafeMutablePointer<UInt8>] = []
        defer {
            for a in allocations { a.deallocate() }
        }
        for ps in parameterSets {
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: ps.count)
            ps.withUnsafeBufferPointer { src in
                if let base = src.baseAddress {
                    p.initialize(from: base, count: ps.count)
                }
            }
            allocations.append(p)
            ptrs.append(UnsafePointer(p))
            sizes.append(ps.count)
        }

        var fd: CMVideoFormatDescription?
        let fdStatus = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: parameterSets.count,
            parameterSetPointers: ptrs,
            parameterSetSizes: sizes,
            nalUnitHeaderLength: 4,
            extensions: nil,
            formatDescriptionOut: &fd
        )
        guard fdStatus == noErr, let formatDesc = fd else {
            throw VideoDecoderError.formatDescriptionFailed(status: fdStatus)
        }

        let dims = CMVideoFormatDescriptionGetDimensions(formatDesc)
        self.width = dims.width
        self.height = dims.height

        var decoderSpec: NSDictionary?
        if #available(tvOS 17.0, iOS 17.0, *) {
            decoderSpec = [
                kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true,
            ]
        }

        self.colorPrimaries = kCVImageBufferColorPrimaries_ITU_R_2020
        self.colorTransfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        self.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_2020

        let pixelBufferAttrs: NSDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
            kCVPixelBufferMetalCompatibilityKey: true,
        ]

        let box = RefConBox(self)
        let unmanaged = Unmanaged.passRetained(box)

        // `session` is read by `decode`/`flush`/`close` on other threads: install it under `lock`.
        lock.lock()
        propagatesHDRDisplayMetadata = false
        decoderSpecification = decoderSpec
        pixelBufferAttributes = pixelBufferAttrs
        let created = makeSession(formatDescription: formatDesc, refCon: unmanaged)
        guard let createdSession = created.session else {
            lock.unlock()
            unmanaged.release()
            throw VideoDecoderError.sessionCreationFailed(status: created.status)
        }
        formatDescription = formatDesc
        session = createdSession
        refConBox = unmanaged
        lock.unlock()

        // Deliberately no `kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata` here,
        // unlike `open(stream:)`. This path builds the base layer's session when its parameter sets
        // arrive in band, and the enhancement layer's session always. The dual-layer decoder
        // attaches its own Dolby Vision RPU to every frame it delivers (composed or bypassed) from
        // the RPU it extracted; letting VideoToolbox propagate HDR display metadata as well would put a
        // second, possibly different, attachment on the base-layer buffer a bypassed frame goes out as.

        EngineLog.emit(
            "[HardwareVideoDecoder] opened secondary HEVC \(width)x\(height) 10-bit from parameter sets",
            category: .swPlayback
        )
    }

    // MARK: - Decode

    func decode(packet: UnsafeMutablePointer<AVPacket>, epoch: UInt64? = nil) {
        lock.lock()
        // AE#492: see `SoftwareVideoDecoder.decode`. Same rule, same lock as `flush()`.
        if let epoch, epoch != currentEpoch { lock.unlock(); return }
        guard session != nil, !sessionLost, let formatDesc = formatDescription else {
            lock.unlock()
            return
        }
        lock.unlock()

        // Wrap the packet (HEVC length-prefix framing from FFmpeg's matroska demuxer, already the VT-expected format)
        // in a CMBlockBuffer+CMSampleBuffer. Copy once: VT may retain the buffer past the call (async decode),
        // and AVPacket storage is reused for the next packet.
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return }
        let size = Int(packet.pointee.size)

        var blockBuffer: CMBlockBuffer?
        var blockStatus: OSStatus = noErr
        var copied: UnsafeMutableRawPointer?

        if useCustomBlockSource,
           let buf = packet.pointee.buf,
           let blockSource = CustomBlockSource(buf: buf, data: data) {
            // Design §5.4: no copy. The CMBlockBuffer holds an `av_buffer_ref` of
            // `packet.buf` and unrefs it in FreeBlock, so VT can retain the data past
            // the call without a copy.
            (blockBuffer, blockStatus) = Self.makeBlockBuffer(wrapping: blockSource, size: size)
            #if DEBUG
            if let bb = blockBuffer {
                onBlockBufferAllocatedForTesting?(bb)
            }
            #endif
        } else {
            // Fallback: copy into newly allocated memory when custom block source is disabled,
            // packet has no AVBufferRef (e.g. synthetic test packet), or av_buffer_ref failed.
            copied = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 1)
            copied?.copyMemory(from: data, byteCount: size)
            blockStatus = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: copied,
                blockLength: size,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: size,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }
        guard blockStatus == kCMBlockBufferNoErr, let bb = blockBuffer else {
            // CMBlockBuffer takes ownership only on success; we own the allocation on failure.
            copied?.deallocate()
            return
        }
        let pts = SourceTimestampBounds.cmTime(ticks: packet.pointee.pts, timeBase: timeBase)
        let dts = SourceTimestampBounds.cmTime(ticks: packet.pointee.dts, timeBase: timeBase)
        let dur = packet.pointee.duration > 0
            ? SourceTimestampBounds.cmTime(ticks: packet.pointee.duration, timeBase: timeBase)
            : CMTime.invalid

        var timing = CMSampleTimingInfo(duration: dur, presentationTimeStamp: pts, decodeTimeStamp: dts)
        var sampleSize = size

        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sb = sampleBuffer else { return }

        // Tag non-keyframes as DependsOnOthers so VT can drop pre-seek RASL frames after a flush.
        if (packet.pointee.flags & AV_PKT_FLAG_KEY) == 0 {
            if let attachArray = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
               CFArrayGetCount(attachArray) > 0 {
                let dict = unsafeBitCast(
                    CFArrayGetValueAtIndex(attachArray, 0),
                    to: CFMutableDictionary.self
                )
                CFDictionarySetValue(
                    dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_DependsOnOthers).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }

        // Audit DEC-4: the epoch check and the send sit under one hold of `lock`, or a flush landing
        // while the sample buffer is built lets a pre-seek packet into VT after it. Safe to hold:
        // the output callback never takes `lock`, and `close()` already holds it across the VT wait.
        lock.lock()
        if let epoch, epoch != currentEpoch { lock.unlock(); return }
        guard let session = self.session, !sessionLost else { lock.unlock(); return }
        var recoveredAfterDropping: Int?
        if awaitingKeyframe {
            guard (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0 else {
                droppedAwaitingKeyframe += 1
                lock.unlock()
                return
            }
            awaitingKeyframe = false
            recoveredAfterDropping = droppedAwaitingKeyframe
        }
        // Async decode with temporal queueing; callback fires on VT's internal queue.
        var infoFlags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sb,
            flags: [._EnableAsynchronousDecompression, ._EnableTemporalProcessing],
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        // AE#739: permanent for this session. Still under the hold that fed it, so a rebuild cannot
        // land between the call and the verdict and have the new session condemned for the old one.
        let lostNow = decodeStatus == kVTInvalidSessionErr && !sessionLost
        if lostNow { sessionLost = true }
        lock.unlock()
        #if DEBUG
        onSubmittedToVideoToolboxForTesting?()
        #endif
        if let recoveredAfterDropping {
            EngineLog.emit(
                "[HardwareVideoDecoder] AE#739 recovered at keyframe pts=\(packet.pointee.pts) "
                + "after dropping \(recoveredAfterDropping) packet(s)",
                category: .swPlayback
            )
        }
        if lostNow {
            EngineLog.emit(
                "[HardwareVideoDecoder] AE#739 session invalidated by the system (\(decodeStatus)) "
                + "at pts=\(packet.pointee.pts); dropping video until it is rebuilt",
                category: .swPlayback
            )
            onSessionLost?()
        } else if decodeStatus != noErr {
            EngineLog.emit(
                "[HardwareVideoDecoder] decode error \(decodeStatus) at pts=\(packet.pointee.pts)",
                category: .swPlayback
            )
        }
    }

    func flush() { flush(bumpingEpoch: true) }

    /// The flush a `DualLayerVideoDecoder` makes: its owner has already moved this decoder's epoch with
    /// `adoptFeedEpoch` (inside its own critical section), so bumping it again here would retire the
    /// post-seek packets the owner has been feeding since.
    func flushKeepingEpoch() { flush(bumpingEpoch: false) }

    private func flush(bumpingEpoch: Bool) {
        lock.lock()
        if bumpingEpoch {   // AE#492
            epochLock.lock(); _feedEpoch &+= 1; epochLock.unlock()
        }
        let session = self.session
        lock.unlock()
        guard let session else { return }
        // Drain in-flight frames then signal a discontinuity so VT drops its reference picture state.
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionFinishDelayedFrames(session)
    }

    func close() {
        lock.lock()
        if let session = session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        formatDescription = nil
        lock.unlock()

        if let box = refConBox {
            box.release()
            refConBox = nil
        }
        onFrame = nil
    }

    deinit {
        close()
    }

    // MARK: - Pixel aspect ratio (#354)

    /// The ratio to attach, or nil when there is nothing to correct. Bitstream first, container
    /// second (`declaredStreamSAR`), then the same two gates the libavcodec path runs: the #177
    /// component bound and the #290 display aspect the ratio produces on this frame. Square pixels
    /// return nil rather than 1:1, because attaching a correction of one is a correction a consumer
    /// cannot tell from a real one.
    static func resolvePixelAspectRatio(
        bitstream: AVRational, container: AVRational, width: Int32, height: Int32
    ) -> AVRational? {
        PixelAspectPolicy.declaredPixelAspect(
            bitstream: bitstream, container: container, width: width, height: height)
    }

    // MARK: - Callback handling (called from VT's queue)

    /// Invoked by `hwDecoderOutputCallback`; delivers CVPixelBuffer+PTS, honouring `skipUntilPTS` for seek-pre-roll.
    fileprivate func handleDecodedFrame(
        imageBuffer: CVImageBuffer,
        pts: CMTime
    ) {
        if let threshold = skipUntilPTS {
            if CMTimeCompare(pts, threshold) < 0 {
                return
            }
            // Compare-and-clear: a concurrent seek can install a new threshold; blindly nil-ing would discard it.
            clearSkip(ifStillAt: threshold)
        }

        // Attach color metadata; without it HDR PQ content shows as desaturated SDR on AVSampleBufferDisplayLayer.
        if let primaries = colorPrimaries {
            CVBufferSetAttachment(imageBuffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        }
        if let transfer = colorTransfer {
            CVBufferSetAttachment(imageBuffer, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
        }
        if let matrix = colorMatrix {
            CVBufferSetAttachment(imageBuffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        }

        // #354: without this the renderer's format description carries no pixel aspect ratio and
        // anamorphic content is displayed at its coded dimensions.
        if let sar = pixelAspectRatio {
            let aspect: NSDictionary = [
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey: Int(sar.num),
                kCVImageBufferPixelAspectRatioVerticalSpacingKey: Int(sar.den),
            ]
            CVBufferSetAttachment(imageBuffer, kCVImageBufferPixelAspectRatioKey, aspect, .shouldPropagate)
        } else {
            // A recycled pool buffer can carry a stale attachment from an earlier stream.
            CVBufferRemoveAttachment(imageBuffer, kCVImageBufferPixelAspectRatioKey)
        }

        reportDecodedFormat(imageBuffer)
        onFrame?(imageBuffer, pts, nil)
    }

    /// VideoToolbox decodes straight into the display buffer, so the buffer IS the decoded picture; its
    /// colour is what this decoder attached, which is the stream's declaration.
    private func reportDecodedFormat(_ buffer: CVImageBuffer) {
        guard let onDecodedFormat else { return }
        let type = CVPixelBufferGetPixelFormatType(buffer)
        guard type != reportedPixelBufferType else { return }
        reportedPixelBufferType = type
        onDecodedFormat(DecodedVideoFormat(
            frame: VideoStreamFormat(
                pixelFormat: DecodedVideoFormat.libavPixelFormat(forPixelBufferType: type),
                declaredBitDepth: 0,
                color: streamColor,
                codecID: streamCodecID,
                profile: streamProfile),
            pixelBufferFormat: DecodedVideoFormat.fourCC(type)))
    }
}

// MARK: - C callback

private func hwDecoderOutputCallback(
    decompressionOutputRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    imageBuffer: CVImageBuffer?,
    presentationTimeStamp: CMTime,
    presentationDuration: CMTime
) {
    guard status == noErr, let imageBuffer = imageBuffer else { return }
    guard let refCon = decompressionOutputRefCon else { return }
    let box = Unmanaged<HardwareVideoDecoder.RefConBox>
        .fromOpaque(refCon).takeUnretainedValue()
    box.decoder?.handleDecodedFrame(
        imageBuffer: imageBuffer,
        pts: presentationTimeStamp
    )
}

/// AE#739: a decoder whose VideoToolbox sessions the system can invalidate behind its back, and that
/// can build them again. The host recovers through this rather than through one decoder type.
protocol VideoSessionRebuilding: AnyObject {
    var onSessionLost: (@Sendable () -> Void)? { get set }
    @discardableResult func rebuildSession() -> Bool
}

extension HardwareVideoDecoder: VideoSessionRebuilding {}
