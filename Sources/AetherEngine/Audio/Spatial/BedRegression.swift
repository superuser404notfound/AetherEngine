// Only with the TrueHDObjectAudio or DTSXObjectAudio trait (both off by default).
#if TrueHDObjectAudio || DTSXObjectAudio
import Accelerate
import Foundation

/// Builds a `SpatialSpeakerLayout` bed out of a TrueHD stream's own channel-based presentation (the
/// 7.1 or 5.1 bed Dolby renders the same mix into), using the object presentation only as statistics.
///
/// Every output is a linear combination of that bed's channels, per frequency band:
/// `out = W · bed`, `W = R · A`, where `A` is the least-squares regression of the elements on the bed
/// (their cross-spectra with the bed over the bed's own covariance, smoothed per band) and `R` the
/// elements' gains into the layout. So each output takes from the bed exactly the part of it that
/// belongs to elements the layout places there. No element signal reaches an output, and no element
/// is ever reconstructed from the bed: the elements enter only through their cross-spectra.
///
/// An object presentation decoded without its matrix interpolation is right wherever the stream
/// does not interpolate, and drifts in between; what drifts is invisible in the bed (it lies in the
/// downmix's null space), so the regression cannot repair it, but it bounds the damage: per band the
/// output carries `energyBounds` times the bed's energy (a constant-power layout over Dolby's 7.1,
/// whose own objects measure 0.7 to 1.0 in power, lands inside), so a drifting element can misplace
/// energy but never add or remove it, and the output can never click.
///
/// A stream can instead carry its elements next to a bed they are folded into at known gains (DTS:X:
/// four heights, each in the bed speaker under it at -3 dB). Then the bed plays on its own speakers
/// and every element moves the part of the bed the regression attributes to it from its bed speaker
/// to its own: `W = D + (R − D · F) · A`, with `D` the bed's own speakers and `F` the folds. Still
/// nothing but the bed reaches an output, and nothing is subtracted from it sample by sample. Such
/// an output can carry up to twice the bed's energy (an element alone, folded at -3 dB), so the
/// bounds are `foldedEnergyBounds`.
///
/// The LFE is the bed's own, on the same delay.
///
/// Streaming: output frame i is input frame i − `latency`. The first `latency` frames after a reset
/// produce no output, and `drain` returns the ones still inside.
final class BedRegression {
    static let fftSize = 2048
    static let hop = 512
    static let latency = fftSize
    static let bandCount = 64
    /// Per-hop weight of the previous statistics (about 20 ms of memory).
    static let smoothing: Double = 0.5
    static let regularization: Double = 1e-3
    static let energyBounds: ClosedRange<Double> = 0.9...1.6
    /// Measured on 21 DTS:X windows: inside these the output is unchanged within 0.2 dB, while
    /// `energyBounds` cost up to 14 dB there.
    static let foldedEnergyBounds: ClosedRange<Double> = 0.5...2.5

    let layout: SpatialSpeakerLayout
    let bedRoles: [ObjectAudioRole]
    let folds: [ObjectAudioBedFold]

    // MARK: Configuration

    private let n = BedRegression.fftSize
    private let h = BedRegression.hop
    private let bins = BedRegression.fftSize / 2 + 1
    private let outputs: Int
    private let lfeOutput: Int
    /// Bed planes regressed on (all but the LFE), and the bed's LFE plane.
    private let bedInputs: [Int]
    private let bedLFE: Int?
    /// Where each regressed bed channel plays when nothing explains it (no placed element yet): its
    /// own speaker, or the panner's spot for it. `outputs` rows of `bedInputs.count`.
    private let fallback: [Float]
    /// Per element, `outputs` entries: −(D · F), what its fold takes from the bed's own speakers.
    /// Empty without folds.
    private let foldGains: [Float]
    private let bounds: ClosedRange<Double>
    private let bands: Int
    private let scale: Float

    // MARK: State

    private var elementCount = 0
    private var elementHistory: [Float] = []
    private var bedHistory: [Float]
    private var elementHop: [Float] = []
    private var bedHop: [Float]
    private var filled = 0
    private var accumulators: [Float]
    /// The `h` frames being handed out during the current hop.
    private var ready: [Float]
    private var consumed: Int64 = 0
    private var written: Int64 = 0

    private var snapshot = ObjectAudioGainSnapshot()
    private var hasSnapshot = false
    /// Layout gains (`elementCount` rows of `outputs`) for the last three hops, the oldest used: a
    /// frame spans four hops, so its centre lies two hops back from the newest input.
    private var gainRing: [[Float]] = [[], [], []]
    private var gainRingNewest = 0
    private var gainRingCount = 0

    /// Per band one `rows` × nb block, `rows` = nb + elementCount: the bed covariance (b_i · conj(b_j))
    /// in the first nb rows, then each element's cross-spectrum with the bed.
    private var stat: SplitBuffer<Double>

    // MARK: Scratch
    //
    // The hop runs through Accelerate end to end: a host's Debug build compiles this package
    // without optimisation, and the per-bin loops this replaced ran at 0.2x real time there (AE#1106).

    private let window: [Float]
    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup
    private var frameBuf: [Float]
    private var evenBuf: [Float], oddBuf: [Float], specRe: [Float], specIm: [Float]
    /// Spectra, `rows` × bins: the regressed bed planes, then the elements (zero while unplaced).
    private var spectra: SplitBuffer<Float>
    private var lfeRe: [Float], lfeIm: [Float]
    private var active: [Bool] = []
    /// The spectra in double, then regrouped per band (`rows` × that band's bins, band after band),
    /// and the bed conjugated, bin-major (bins × nb), so each band's statistics are one matrix product.
    private var spectraD: SplitBuffer<Double>
    private var banded: SplitBuffer<Double>
    private let bedConj: SplitBuffer<Double>
    private var bandedIndex: [Double] = []
    private let bedConjIndex: [Double]
    private var product: SplitBuffer<Double>
    private let bandEdges: [Int]
    /// Per bin, its place between band centres as `vDSP_vlint` reads it: lower band + fraction.
    private let bandPosition: [Float]
    /// Weights per (output, bed plane) row, `bands + 1` entries (the last repeats the top band, so
    /// the interpolation can always read one past).
    private let weights: SplitBuffer<Float>
    private let interpolated: SplitBuffer<Float>
    /// Layout gains of the placed elements (outputs × elementCount, LFE row zero), plus folds.
    private var elementGains: [Double] = []
    /// `fallback` in double with the LFE row zero: the D of the fold mode.
    private let bedFallback: [Double]
    private let cholesky: SplitBuffer<Double>, inverseL: SplitBuffer<Double>, inverseLH: SplitBuffer<Double>
    private let inverseM: SplitBuffer<Double>
    private var regression: SplitBuffer<Double>
    private let mix: SplitBuffer<Double>, mixCov: SplitBuffer<Double>
    private var outRe: [Float], outIm: [Float]
    private var timeBuf: [Float]

    init(layout: SpatialSpeakerLayout, bedRoles: [ObjectAudioRole], folds: [ObjectAudioBedFold] = []) {
        self.layout = layout
        self.bedRoles = bedRoles
        self.folds = folds
        outputs = layout.channelCount
        lfeOutput = layout.lfeIndex
        bedLFE = bedRoles.firstIndex(of: .lfe)
        bedInputs = bedRoles.indices.filter { bedRoles[$0] != .lfe }

        let panner = AllocentricPanner(layout: layout)
        var fallback = [Float](repeating: 0, count: layout.channelCount * bedInputs.count)
        var row: [Float] = []
        for (j, plane) in bedInputs.enumerated() {
            let position: SIMD3<Float>
            switch bedRoles[plane] {
            case .bed(let speaker):
                if let direct = layout.speakers.firstIndex(of: speaker) {
                    fallback[direct * bedInputs.count + j] = 1
                    continue
                }
                position = speaker.position
            case .fixed(let p): position = p
            default: position = SIMD3(0.5, 0.5, 0)
            }
            panner.pointGains(position, into: &row)
            for c in 0..<layout.channelCount { fallback[c * bedInputs.count + j] = row[c] }
        }
        self.fallback = fallback
        bounds = folds.isEmpty ? Self.energyBounds : Self.foldedEnergyBounds
        let elements = (folds.map(\.element).max() ?? -1) + 1
        var foldGains = [Float](repeating: 0, count: elements * layout.channelCount)
        for fold in folds {
            guard let j = bedInputs.firstIndex(of: fold.plane) else { continue }
            for c in 0..<layout.channelCount {
                foldGains[fold.element * layout.channelCount + c] -= fold.gain * fallback[c * bedInputs.count + j]
            }
        }
        self.foldGains = foldGains

        var edges = [0]
        for i in 0..<Self.bandCount {
            let e = Int((2 * pow(Double(bins) / 2, Double(i) / Double(Self.bandCount - 1))).rounded())
            if e > edges.last! { edges.append(min(e, bins)) }
        }
        if edges.last! < bins { edges.append(bins) }
        bands = edges.count - 1
        bandEdges = edges
        var centers = [Float](repeating: 0, count: bands)
        for b in 0..<bands { centers[b] = Float(edges[b] + edges[b + 1] - 1) / 2 }
        // W between band centres, linear: below the first and above the last centre a band's own.
        var position = [Float](repeating: 0, count: bins)
        var lower = 0
        for k in 0..<bins {
            let fk = Float(k)
            while lower + 1 < bands, centers[lower + 1] <= fk { lower += 1 }
            let upper = min(lower + 1, bands - 1)
            var t: Float = 0
            if upper != lower, fk > centers[lower] {
                t = min(1, (fk - centers[lower]) / (centers[upper] - centers[lower]))
            }
            position[k] = Float(lower) + t
        }
        bandPosition = position

        // Periodic Hann, square-rooted for analysis and synthesis: four frames per sample sum to 2.
        // vDSP's packed real DFT scales a forward and inverse round trip by 2n.
        let size = Self.fftSize
        window = (0..<size).map { (0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(size))).squareRoot() }
        scale = 1 / (2 * Float(size) * 2)
        forward = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .FORWARD)!
        inverse = vDSP_DFT_zrop_CreateSetup(forward, vDSP_Length(size), .INVERSE)!

        let nb = bedInputs.count, outputs = layout.channelCount
        bedHistory = [Float](repeating: 0, count: bedRoles.count * n)
        bedHop = [Float](repeating: 0, count: bedRoles.count * h)
        accumulators = [Float](repeating: 0, count: outputs * n)
        ready = [Float](repeating: 0, count: outputs * h)
        frameBuf = [Float](repeating: 0, count: n)
        evenBuf = [Float](repeating: 0, count: n / 2)
        oddBuf = evenBuf; specRe = evenBuf; specIm = evenBuf
        lfeRe = [Float](repeating: 0, count: bins); lfeIm = lfeRe
        stat = SplitBuffer(bands * nb * nb)
        spectra = SplitBuffer(nb * bins)
        spectraD = SplitBuffer(nb * bins)
        banded = SplitBuffer(nb * bins)
        bedConj = SplitBuffer(bins * nb)
        var conjIndex = [Double](repeating: 0, count: bins * nb)
        for k in 0..<bins { for j in 0..<nb { conjIndex[k * nb + j] = Double(j * bins + k) } }
        bedConjIndex = conjIndex
        product = SplitBuffer(bands * nb * nb)
        weights = SplitBuffer(outputs * nb * (bands + 1))
        interpolated = SplitBuffer(bins)
        var bedFallback = [Double](repeating: 0, count: outputs * nb)
        for o in 0..<outputs where o != layout.lfeIndex {
            for j in 0..<nb { bedFallback[o * nb + j] = Double(fallback[o * nb + j]) }
        }
        self.bedFallback = bedFallback
        cholesky = SplitBuffer(nb * nb); inverseL = SplitBuffer(nb * nb); inverseLH = SplitBuffer(nb * nb)
        inverseM = SplitBuffer(nb * nb)
        regression = SplitBuffer(0)
        mix = SplitBuffer(outputs * nb); mixCov = SplitBuffer(outputs * nb)
        outRe = [Float](repeating: 0, count: outputs * bins); outIm = outRe
        timeBuf = [Float](repeating: 0, count: n)
        rebuildBandedIndex()
    }

    deinit {
        vDSP_DFT_DestroySetup(forward)
        vDSP_DFT_DestroySetup(inverse)
    }

    /// Frames taken in that have not come out yet.
    var backlog: Int { Int(consumed - written) }

    func reset() {
        for i in elementHistory.indices { elementHistory[i] = 0 }
        for i in bedHistory.indices { bedHistory[i] = 0 }
        for i in accumulators.indices { accumulators[i] = 0 }
        for i in ready.indices { ready[i] = 0 }
        stat.clear()
        gainRingCount = 0
        hasSnapshot = false
        filled = 0
        consumed = 0
        written = 0
    }

    /// Element gains into the layout, as `ObjectAudioPlacement` tracks them, for the frames passed next.
    func setGains(_ source: ObjectAudioGainSnapshot) {
        snapshot = source
        hasSnapshot = true
    }

    /// Take `frameCount` frames (`elements` / `bed` nil: silence, to run the tail out) and write the
    /// frames that complete into `output`, one plane per layout channel. Returns how many.
    @discardableResult
    func process(elements: [UnsafePointer<Float>]?, bed: [UnsafePointer<Float>]?, frameCount: Int,
                 output: [UnsafeMutablePointer<Float>]) -> Int {
        let count = elements?.count ?? elementCount
        if count != elementCount { resizeElements(count) }
        var taken = 0
        var out = 0
        while taken < frameCount {
            let take = min(h - filled, frameCount - taken)
            elementHop.withUnsafeMutableBufferPointer { hop in
                for c in 0..<elementCount {
                    let dst = hop.baseAddress! + c * h + filled
                    if let elements { dst.update(from: elements[c] + taken, count: take) }
                    else { dst.update(repeating: 0, count: take) }
                }
            }
            bedHop.withUnsafeMutableBufferPointer { hop in
                for c in 0..<bedRoles.count {
                    let dst = hop.baseAddress! + c * h + filled
                    if let bed, c < bed.count { dst.update(from: bed[c] + taken, count: take) }
                    else { dst.update(repeating: 0, count: take) }
                }
            }
            let skip = Int(max(0, min(Int64(take), Int64(Self.latency) - consumed)))
            if take > skip {
                ready.withUnsafeBufferPointer { r in
                    for c in 0..<outputs {
                        (output[c] + out).update(from: r.baseAddress! + c * h + filled + skip, count: take - skip)
                    }
                }
                out += take - skip
            }
            consumed += Int64(take)
            filled += take
            taken += take
            if filled == h {
                filled = 0
                processHop()
            }
        }
        written += Int64(out)
        return out
    }

    /// The frames still inside, run out with silence, then a reset.
    func drain(output: [UnsafeMutablePointer<Float>]) -> Int {
        let pending = backlog
        guard pending > 0 else { reset(); return 0 }
        var out = 0
        var remaining = Self.latency
        var cursor = output
        while remaining > 0, out < pending {
            let step = min(remaining, h)
            let got = process(elements: nil, bed: nil, frameCount: step, output: cursor)
            let keep = min(got, pending - out)
            out += keep
            cursor = cursor.map { $0 + keep }
            remaining -= step
        }
        reset()
        return out
    }

    private func resizeElements(_ count: Int) {
        let nb = bedInputs.count, oldRows = nb + elementCount, rows = nb + count
        elementCount = count
        elementHistory = [Float](repeating: 0, count: count * n)
        elementHop = [Float](repeating: 0, count: count * h)
        active = [Bool](repeating: false, count: count)
        for i in gainRing.indices { gainRing[i] = [Float](repeating: 0, count: count * outputs) }
        gainRingCount = 0
        // The bed covariance carries over, the cross-spectra start from zero.
        let resized = SplitBuffer<Double>(bands * rows * nb)
        for b in 0..<bands {
            resized.copy(from: stat, at: b * oldRows * nb, to: b * rows * nb, count: nb * nb)
        }
        stat = resized
        spectra = SplitBuffer(rows * bins)
        spectraD = SplitBuffer(rows * bins)
        banded = SplitBuffer(rows * bins)
        product = SplitBuffer(bands * rows * nb)
        regression = SplitBuffer(count * nb)
        elementGains = [Double](repeating: 0, count: outputs * count)
        rebuildBandedIndex()
    }

    /// Where each entry of the per-band regrouping comes from in the spectra.
    private func rebuildBandedIndex() {
        let rows = bedInputs.count + elementCount
        bandedIndex = [Double](repeating: 0, count: rows * bins)
        for b in 0..<bands {
            let e0 = bandEdges[b], m = bandEdges[b + 1] - e0
            for r in 0..<rows {
                for k in 0..<m { bandedIndex[rows * e0 + r * m + k] = Double(r * bins + e0 + k) }
            }
        }
    }

    // MARK: - Hop

    private func processHop() {
        shiftIn(&elementHistory, from: elementHop, channels: elementCount)
        shiftIn(&bedHistory, from: bedHop, channels: bedRoles.count)
        pushGains()
        transformInputs()
        accumulateStatistics()
        let gains = gainRingCount > 0 ? gainRing[(gainRingNewest + 3 - (gainRingCount - 1)) % 3] : nil
        solveWeights(gains: gains)
        applyWeights()
        synthesize()
    }

    private func shiftIn(_ history: inout [Float], from hopBuffer: [Float], channels: Int) {
        let n = self.n, h = self.h
        history.withUnsafeMutableBufferPointer { hist in
            hopBuffer.withUnsafeBufferPointer { hop in
                for c in 0..<channels {
                    let p = hist.baseAddress! + c * n
                    p.update(from: p + h, count: n - h)
                    (p + n - h).update(from: hop.baseAddress! + c * h, count: h)
                }
            }
        }
    }

    private func pushGains() {
        guard hasSnapshot, snapshot.positions.count == elementCount,
              snapshot.layoutGains.count == elementCount * outputs else { return }
        gainRingNewest = (gainRingNewest + 1) % 3
        gainRingCount = min(gainRingCount + 1, 3)
        gainRing[gainRingNewest].withUnsafeMutableBufferPointer { ring in
            for k in 0..<elementCount {
                // The LFE and objects without metadata yet are placed nowhere.
                let placed = snapshot.positions[k] != nil
                for c in 0..<outputs {
                    ring[k * outputs + c] = placed && c != lfeOutput ? snapshot.layoutGains[k * outputs + c] : 0
                }
            }
        }
    }

    private func spectrum(_ source: UnsafePointer<Float>, re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>) {
        frameBuf.withUnsafeMutableBufferPointer { f in
            vDSP_vmul(source, 1, window, 1, f.baseAddress!, 1, vDSP_Length(n))
        }
        frameBuf.withUnsafeBufferPointer { f in
            evenBuf.withUnsafeMutableBufferPointer { e in
                oddBuf.withUnsafeMutableBufferPointer { o in
                    f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { c in
                        var split = DSPSplitComplex(realp: e.baseAddress!, imagp: o.baseAddress!)
                        vDSP_ctoz(c, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
            }
        }
        vDSP_DFT_Execute(forward, evenBuf, oddBuf, &specRe, &specIm)
        let half = n / 2
        specRe.withUnsafeBufferPointer { r in
            specIm.withUnsafeBufferPointer { i in
                re.update(from: r.baseAddress!, count: half)
                im.update(from: i.baseAddress!, count: half)
                re[half] = i[0]
                im[0] = 0
                im[half] = 0
            }
        }
    }

    private func transformInputs() {
        let bins = self.bins, nb = bedInputs.count
        bedHistory.withUnsafeBufferPointer { hist in
            for (j, plane) in bedInputs.enumerated() {
                spectrum(hist.baseAddress! + plane * n, re: spectra.re + j * bins, im: spectra.im + j * bins)
            }
            if let bedLFE {
                lfeRe.withUnsafeMutableBufferPointer { re in
                    lfeIm.withUnsafeMutableBufferPointer { im in
                        spectrum(hist.baseAddress! + bedLFE * n, re: re.baseAddress!, im: im.baseAddress!)
                    }
                }
            }
        }
        let ring = gainRingCount > 0 ? gainRing[(gainRingNewest + 3 - (gainRingCount - 1)) % 3] : nil
        elementHistory.withUnsafeBufferPointer { hist in
            for k in 0..<elementCount {
                var placed = false
                if let ring { for c in 0..<outputs where ring[k * outputs + c] != 0 { placed = true; break } }
                active[k] = placed
                let row = (nb + k) * bins
                // An unplaced element adds nothing to its cross-spectra, which then only decay.
                guard placed else {
                    vDSP_vclr(spectra.re + row, 1, vDSP_Length(bins))
                    vDSP_vclr(spectra.im + row, 1, vDSP_Length(bins))
                    continue
                }
                spectrum(hist.baseAddress! + k * n, re: spectra.re + row, im: spectra.im + row)
            }
        }
    }

    /// Recursive band statistics: covariance of the bed, cross-spectra of every placed element with
    /// it. Per band that is one matrix product, (bed and elements) times the conjugated bed.
    private func accumulateStatistics() {
        let nb = bedInputs.count, rows = nb + elementCount, bins = self.bins
        guard nb > 0 else { return }
        let total = vDSP_Length(rows * bins)
        vDSP_vspdp(spectra.re, 1, spectraD.re, 1, total)
        vDSP_vspdp(spectra.im, 1, spectraD.im, 1, total)
        vDSP_vindexD(spectraD.re, bandedIndex, 1, banded.re, 1, total)
        vDSP_vindexD(spectraD.im, bandedIndex, 1, banded.im, 1, total)
        let bedCount = vDSP_Length(bins * nb)
        var w = 1 - Self.smoothing, minusW = -w
        vDSP_vindexD(spectraD.re, bedConjIndex, 1, bedConj.re, 1, bedCount)
        vDSP_vindexD(spectraD.im, bedConjIndex, 1, bedConj.im, 1, bedCount)
        vDSP_vsmulD(bedConj.re, 1, &w, bedConj.re, 1, bedCount)
        vDSP_vsmulD(bedConj.im, 1, &minusW, bedConj.im, 1, bedCount)
        var b = 0
        while b < bands {
            let e0 = bandEdges[b], m = bandEdges[b + 1] - e0
            var a = banded.split(at: rows * e0)
            var c = bedConj.split(at: e0 * nb)
            var p = product.split(at: b * rows * nb)
            vDSP_zmmulD(&a, 1, &c, 1, &p, 1, vDSP_Length(rows), vDSP_Length(nb), vDSP_Length(m))
            b += 1
        }
        var smoothing = Self.smoothing
        let count = vDSP_Length(bands * rows * nb)
        vDSP_vsmaD(stat.re, 1, &smoothing, product.re, 1, stat.re, 1, count)
        vDSP_vsmaD(stat.im, 1, &smoothing, product.im, 1, stat.im, 1, count)
    }

    /// Per band: A = cross · (cov + reg)⁻¹ through a Cholesky factor, W = R · A, then the energy bound.
    private func solveWeights(gains: [Float]?) {
        let nb = bedInputs.count, K = elementCount, O = outputs, rows = nb + K, stride = bands + 1
        weights.clear()
        guard nb > 0 else { return }
        guard let gains, active.contains(true) else {
            for r in 0..<(O * nb) {
                var value = fallback[r]
                vDSP_vfill(&value, weights.re + r * stride, 1, vDSP_Length(stride))
            }
            return
        }
        let folded = !foldGains.isEmpty
        for o in 0..<O {
            for e in 0..<K {
                var g = 0.0
                if o != lfeOutput, active[e] {
                    g = Double(gains[e * O + o])
                    if folded, e * O + o < foldGains.count { g += Double(foldGains[e * O + o]) }
                }
                elementGains[o * K + e] = g
            }
        }
        let L = cholesky, Z = inverseL, ZH = inverseLH
        var b = 0
        while b < bands {
            defer { b += 1 }
            let base = b * rows * nb
            let cr = stat.re + base, ci = stat.im + base
            var trace = 0.0
            var i = 0
            while i < nb { trace += cr[i * nb + i]; i += 1 }
            guard trace > 1e-12 else { continue }
            let reg = Self.regularization * trace / Double(nb) + 1e-15
            guard factor(cr, ci, reg: reg, into: L, nb: nb) else { continue }
            invertLower(L, into: Z, adjoint: ZH, nb: nb)
            // M⁻¹ = L⁻ᴴ L⁻¹, and each element's row a = x · M⁻¹.
            var zh = ZH.split(at: 0), z = Z.split(at: 0), mInv = inverseM.split(at: 0)
            vDSP_zmmulD(&zh, 1, &z, 1, &mInv, 1, vDSP_Length(nb), vDSP_Length(nb), vDSP_Length(nb))
            var cross = stat.split(at: base + nb * nb), a = regression.split(at: 0)
            vDSP_zmmulD(&cross, 1, &mInv, 1, &a, 1, vDSP_Length(K), vDSP_Length(nb), vDSP_Length(nb))
            // W = R · A (real gains), or with folds D + (R − D · F) · A
            vDSP_mmulD(elementGains, 1, regression.re, 1, mix.re, 1, vDSP_Length(O), vDSP_Length(nb), vDSP_Length(K))
            vDSP_mmulD(elementGains, 1, regression.im, 1, mix.im, 1, vDSP_Length(O), vDSP_Length(nb), vDSP_Length(K))
            if folded { vDSP_vaddD(mix.re, 1, bedFallback, 1, mix.re, 1, vDSP_Length(O * nb)) }
            // Energy bound: trace(W C Wᴴ) against trace(C), the LFE row being zero.
            var w = mix.split(at: 0), cov = stat.split(at: base), wc = mixCov.split(at: 0)
            vDSP_zmmulD(&w, 1, &cov, 1, &wc, 1, vDSP_Length(O), vDSP_Length(nb), vDSP_Length(nb))
            var eoRe = 0.0, eoIm = 0.0
            vDSP_dotprD(mixCov.re, 1, mix.re, 1, &eoRe, vDSP_Length(O * nb))
            vDSP_dotprD(mixCov.im, 1, mix.im, 1, &eoIm, vDSP_Length(O * nb))
            let eo = eoRe + eoIm
            var g = 1.0
            if eo > 1e-15 {
                let r = eo / trace
                if r > bounds.upperBound { g = (bounds.upperBound / r).squareRoot() }
                else if r < bounds.lowerBound { g = (bounds.lowerBound / r).squareRoot() }
            }
            vDSP_vsmulD(mix.re, 1, &g, mix.re, 1, vDSP_Length(O * nb))
            vDSP_vsmulD(mix.im, 1, &g, mix.im, 1, vDSP_Length(O * nb))
            vDSP_vdpsp(mix.re, 1, weights.re + b, stride, vDSP_Length(O * nb))
            vDSP_vdpsp(mix.im, 1, weights.im + b, stride, vDSP_Length(O * nb))
        }
        var one: Float = 1
        vDSP_vsmul(weights.re + bands - 1, stride, &one, weights.re + bands, stride, vDSP_Length(O * nb))
        vDSP_vsmul(weights.im + bands - 1, stride, &one, weights.im + bands, stride, vDSP_Length(O * nb))
    }

    /// Cholesky factor L (lower) of the band's covariance plus `reg` on the diagonal: M = L Lᴴ.
    private func factor(_ cr: UnsafePointer<Double>, _ ci: UnsafePointer<Double>, reg: Double,
                        into L: SplitBuffer<Double>, nb: Int) -> Bool {
        let lr = L.re, li = L.im
        var j = 0
        while j < nb {
            var d = cr[j * nb + j] + reg
            var k = 0
            while k < j { d -= lr[j * nb + k] * lr[j * nb + k] + li[j * nb + k] * li[j * nb + k]; k += 1 }
            guard d > 0 else { return false }
            let l = d.squareRoot()
            lr[j * nb + j] = l; li[j * nb + j] = 0
            var i = j + 1
            while i < nb {
                // L[i][j] = (M[i][j] − Σ L[i][k] conj(L[j][k])) / L[j][j]
                var sr = cr[i * nb + j], si = ci[i * nb + j]
                k = 0
                while k < j {
                    let pr = lr[i * nb + k], pi = li[i * nb + k], qr = lr[j * nb + k], qi = li[j * nb + k]
                    sr -= pr * qr + pi * qi
                    si -= pi * qr - pr * qi
                    k += 1
                }
                lr[i * nb + j] = sr / l; li[i * nb + j] = si / l
                i += 1
            }
            j += 1
        }
        return true
    }

    /// Z = L⁻¹ (lower) by forward substitution, and Zᴴ beside it.
    private func invertLower(_ L: SplitBuffer<Double>, into Z: SplitBuffer<Double>, adjoint ZH: SplitBuffer<Double>, nb: Int) {
        let lr = L.re, li = L.im, zr = Z.re, zi = Z.im
        Z.clear()
        var c = 0
        while c < nb {
            zr[c * nb + c] = 1 / lr[c * nb + c]
            var i = c + 1
            while i < nb {
                var sr = 0.0, si = 0.0
                var k = c
                while k < i {
                    let ar = lr[i * nb + k], ai = li[i * nb + k], br = zr[k * nb + c], bi = zi[k * nb + c]
                    sr -= ar * br - ai * bi
                    si -= ar * bi + ai * br
                    k += 1
                }
                let d = lr[i * nb + i]
                zr[i * nb + c] = sr / d; zi[i * nb + c] = si / d
                i += 1
            }
            c += 1
        }
        var r = 0
        while r < nb {
            var col = 0
            while col < nb {
                ZH.re[r * nb + col] = zr[col * nb + r]
                ZH.im[r * nb + col] = -zi[col * nb + r]
                col += 1
            }
            r += 1
        }
    }

    /// Output spectra: W interpolated linearly between band centres, times the bed; the LFE is the bed's.
    private func applyWeights() {
        let nb = bedInputs.count, O = outputs, bins = self.bins, stride = bands + 1
        let count = vDSP_Length(bins)
        outRe.withUnsafeMutableBufferPointer { orr in
        outIm.withUnsafeMutableBufferPointer { oi in
            vDSP_vclr(orr.baseAddress!, 1, vDSP_Length(O * bins))
            vDSP_vclr(oi.baseAddress!, 1, vDSP_Length(O * bins))
            bandPosition.withUnsafeBufferPointer { position in
                var w = interpolated.split(at: 0)
                for o in 0..<O where o != lfeOutput {
                    var out = DSPSplitComplex(realp: orr.baseAddress! + o * bins, imagp: oi.baseAddress! + o * bins)
                    for j in 0..<nb {
                        let row = (o * nb + j) * stride
                        vDSP_vlint(weights.re + row, position.baseAddress!, 1, interpolated.re, 1, count, vDSP_Length(stride))
                        vDSP_vlint(weights.im + row, position.baseAddress!, 1, interpolated.im, 1, count, vDSP_Length(stride))
                        var x = spectra.split(at: j * bins)
                        vDSP_zvma(&w, 1, &x, 1, &out, 1, &out, 1, count)
                    }
                }
            }
            if bedLFE != nil {
                (orr.baseAddress! + lfeOutput * bins).update(from: lfeRe, count: bins)
                (oi.baseAddress! + lfeOutput * bins).update(from: lfeIm, count: bins)
            }
        }}
    }

    /// Inverse transforms, synthesis window, overlap-add; the completed hop moves to `ready`.
    private func synthesize() {
        let half = n / 2, bins = self.bins
        var sc = scale
        for o in 0..<outputs {
            outRe.withUnsafeBufferPointer { r in
                outIm.withUnsafeBufferPointer { i in
                    evenBuf.withUnsafeMutableBufferPointer { e in e.baseAddress!.update(from: r.baseAddress! + o * bins, count: half) }
                    oddBuf.withUnsafeMutableBufferPointer { od in od.baseAddress!.update(from: i.baseAddress! + o * bins, count: half) }
                    oddBuf[0] = r[o * bins + half]
                }
            }
            vDSP_DFT_Execute(inverse, evenBuf, oddBuf, &specRe, &specIm)
            specRe.withUnsafeBufferPointer { r in
                specIm.withUnsafeBufferPointer { i in
                    timeBuf.withUnsafeMutableBufferPointer { t in
                        t.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { c in
                            var split = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: r.baseAddress!),
                                                        imagp: UnsafeMutablePointer(mutating: i.baseAddress!))
                            vDSP_ztoc(&split, 1, c, 2, vDSP_Length(half))
                        }
                    }
                }
            }
            timeBuf.withUnsafeMutableBufferPointer { t in
                vDSP_vmul(t.baseAddress!, 1, window, 1, t.baseAddress!, 1, vDSP_Length(n))
                vDSP_vsmul(t.baseAddress!, 1, &sc, t.baseAddress!, 1, vDSP_Length(n))
            }
            accumulators.withUnsafeMutableBufferPointer { acc in
                let a = acc.baseAddress! + o * n
                vDSP_vadd(a, 1, timeBuf, 1, a, 1, vDSP_Length(n))
                ready.withUnsafeMutableBufferPointer { r in (r.baseAddress! + o * h).update(from: a, count: h) }
                a.update(from: a + h, count: n - h)
                (a + n - h).update(repeating: 0, count: h)
            }
        }
    }
}

/// A split-complex buffer in raw memory, so the hop's Accelerate calls take it without an `Array`
/// access in between.
private final class SplitBuffer<T: FloatingPoint> {
    let re: UnsafeMutablePointer<T>
    let im: UnsafeMutablePointer<T>
    let count: Int

    init(_ count: Int) {
        self.count = count
        re = .allocate(capacity: max(1, count)); re.initialize(repeating: 0, count: max(1, count))
        im = .allocate(capacity: max(1, count)); im.initialize(repeating: 0, count: max(1, count))
    }

    deinit { re.deallocate(); im.deallocate() }

    func clear() {
        re.update(repeating: 0, count: max(1, count))
        im.update(repeating: 0, count: max(1, count))
    }

    func copy(from other: SplitBuffer<T>, at source: Int, to destination: Int, count: Int) {
        (re + destination).update(from: other.re + source, count: count)
        (im + destination).update(from: other.im + source, count: count)
    }
}

private extension SplitBuffer where T == Float {
    func split(at offset: Int) -> DSPSplitComplex { DSPSplitComplex(realp: re + offset, imagp: im + offset) }
}

private extension SplitBuffer where T == Double {
    func split(at offset: Int) -> DSPDoubleSplitComplex { DSPDoubleSplitComplex(realp: re + offset, imagp: im + offset) }
}
#endif
