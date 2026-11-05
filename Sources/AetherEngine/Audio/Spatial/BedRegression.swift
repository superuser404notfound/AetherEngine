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
    private let bandOfBin: [Int]
    private let bandCenters: [Float]
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

    /// Per band: bed covariance (nb × nb) and element-bed cross-spectra (elementCount × nb).
    private var covRe: [Double], covIm: [Double]
    private var crossRe: [Double] = [], crossIm: [Double] = []

    // MARK: Scratch

    private let window: [Float]
    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup
    private var frameBuf: [Float]
    private var evenBuf: [Float], oddBuf: [Float], specRe: [Float], specIm: [Float]
    private var bedRe: [Float], bedIm: [Float]
    private var lfeRe: [Float], lfeIm: [Float]
    private var elemRe: [Float] = [], elemIm: [Float] = []
    private var active: [Bool] = []
    private var weightRe: [Float], weightIm: [Float]
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
        var bandOfBin = [Int](repeating: 0, count: bins)
        var centers = [Float](repeating: 0, count: bands)
        for b in 0..<bands {
            for k in edges[b]..<edges[b + 1] { bandOfBin[k] = b }
            centers[b] = Float(edges[b] + edges[b + 1] - 1) / 2
        }
        self.bandOfBin = bandOfBin
        bandCenters = centers

        // Periodic Hann, square-rooted for analysis and synthesis: four frames per sample sum to 2.
        // vDSP's packed real DFT scales a forward and inverse round trip by 2n.
        let size = Self.fftSize
        window = (0..<size).map { (0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(size))).squareRoot() }
        scale = 1 / (2 * Float(size) * 2)
        forward = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .FORWARD)!
        inverse = vDSP_DFT_zrop_CreateSetup(forward, vDSP_Length(size), .INVERSE)!

        let nb = bedInputs.count
        bedHistory = [Float](repeating: 0, count: bedRoles.count * n)
        bedHop = [Float](repeating: 0, count: bedRoles.count * h)
        accumulators = [Float](repeating: 0, count: outputs * n)
        ready = [Float](repeating: 0, count: outputs * h)
        frameBuf = [Float](repeating: 0, count: n)
        evenBuf = [Float](repeating: 0, count: n / 2)
        oddBuf = evenBuf; specRe = evenBuf; specIm = evenBuf
        bedRe = [Float](repeating: 0, count: nb * bins); bedIm = bedRe
        lfeRe = [Float](repeating: 0, count: bins); lfeIm = lfeRe
        covRe = [Double](repeating: 0, count: bands * nb * nb); covIm = covRe
        weightRe = [Float](repeating: 0, count: bands * outputs * nb); weightIm = weightRe
        outRe = [Float](repeating: 0, count: outputs * bins); outIm = outRe
        timeBuf = [Float](repeating: 0, count: n)
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
        for i in covRe.indices { covRe[i] = 0; covIm[i] = 0 }
        for i in crossRe.indices { crossRe[i] = 0; crossIm[i] = 0 }
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
        elementCount = count
        elementHistory = [Float](repeating: 0, count: count * n)
        elementHop = [Float](repeating: 0, count: count * h)
        elemRe = [Float](repeating: 0, count: count * bins); elemIm = elemRe
        active = [Bool](repeating: false, count: count)
        crossRe = [Double](repeating: 0, count: bands * count * bedInputs.count); crossIm = crossRe
        for i in gainRing.indices { gainRing[i] = [Float](repeating: 0, count: count * outputs) }
        gainRingCount = 0
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
        let bins = self.bins
        bedHistory.withUnsafeBufferPointer { hist in
            bedRe.withUnsafeMutableBufferPointer { re in
                bedIm.withUnsafeMutableBufferPointer { im in
                    for (j, plane) in bedInputs.enumerated() {
                        spectrum(hist.baseAddress! + plane * n, re: re.baseAddress! + j * bins, im: im.baseAddress! + j * bins)
                    }
                }
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
            elemRe.withUnsafeMutableBufferPointer { re in
                elemIm.withUnsafeMutableBufferPointer { im in
                    for k in 0..<elementCount {
                        var placed = false
                        if let ring { for c in 0..<outputs where ring[k * outputs + c] != 0 { placed = true; break } }
                        active[k] = placed
                        guard placed else { continue }
                        spectrum(hist.baseAddress! + k * n, re: re.baseAddress! + k * bins, im: im.baseAddress! + k * bins)
                    }
                }
            }
        }
    }

    /// Recursive band statistics: covariance of the bed, cross-spectra of every placed element with it.
    private func accumulateStatistics() {
        let nb = bedInputs.count, K = elementCount, bins = self.bins
        let a = Self.smoothing, w = 1 - a
        for i in covRe.indices { covRe[i] *= a; covIm[i] *= a }
        for i in crossRe.indices { crossRe[i] *= a; crossIm[i] *= a }
        bedRe.withUnsafeBufferPointer { br in
        bedIm.withUnsafeBufferPointer { bi in
        elemRe.withUnsafeBufferPointer { er in
        elemIm.withUnsafeBufferPointer { ei in
        covRe.withUnsafeMutableBufferPointer { cr in
        covIm.withUnsafeMutableBufferPointer { ci in
        crossRe.withUnsafeMutableBufferPointer { xr in
        crossIm.withUnsafeMutableBufferPointer { xi in
            for k in 0..<bins {
                let band = bandOfBin[k]
                let cBase = band * nb * nb
                for i in 0..<nb {
                    let ar = Double(br[i * bins + k]), ai = Double(bi[i * bins + k])
                    for j in i..<nb {
                        let cr2 = Double(br[j * bins + k]), ci2 = Double(bi[j * bins + k])
                        // b_i · conj(b_j)
                        cr[cBase + i * nb + j] += w * (ar * cr2 + ai * ci2)
                        ci[cBase + i * nb + j] += w * (ai * cr2 - ar * ci2)
                    }
                }
                let xBase = band * K * nb
                for e in 0..<K where active[e] {
                    let sr = Double(er[e * bins + k]), si = Double(ei[e * bins + k])
                    for j in 0..<nb {
                        let cr2 = Double(br[j * bins + k]), ci2 = Double(bi[j * bins + k])
                        xr[xBase + e * nb + j] += w * (sr * cr2 + si * ci2)
                        xi[xBase + e * nb + j] += w * (si * cr2 - sr * ci2)
                    }
                }
            }
        }}}}}}}}
    }

    /// Per band: A = cross · (cov + reg)⁻¹ by Cholesky, W = R · A, then the energy bound.
    private func solveWeights(gains: [Float]?) {
        let nb = bedInputs.count, K = elementCount, O = outputs
        for i in weightRe.indices { weightRe[i] = 0; weightIm[i] = 0 }
        guard nb > 0 else { return }
        guard let gains, active.contains(true) else {
            for band in 0..<bands {
                for i in 0..<(O * nb) { weightRe[band * O * nb + i] = fallback[i] }
            }
            return
        }
        var mr = [Double](repeating: 0, count: nb * nb), mi = mr   // Hermitian matrix, then its Cholesky factor L
        var yr = [Double](repeating: 0, count: nb), yi = yr
        var ar = [Double](repeating: 0, count: K * nb), ai = ar
        var wr = [Double](repeating: 0, count: O * nb), wi = wr
        for band in 0..<bands {
            let cBase = band * nb * nb
            var trace = 0.0
            for i in 0..<nb { trace += covRe[cBase + i * nb + i] }
            guard trace > 1e-12 else { continue }
            let reg = Self.regularization * trace / Double(nb) + 1e-15
            for i in 0..<nb {
                for j in 0..<nb {
                    if j >= i { mr[i * nb + j] = covRe[cBase + i * nb + j]; mi[i * nb + j] = covIm[cBase + i * nb + j] }
                    else { mr[i * nb + j] = covRe[cBase + j * nb + i]; mi[i * nb + j] = -covIm[cBase + j * nb + i] }
                }
                mr[i * nb + i] += reg
            }
            // Cholesky M = L Lᴴ, L lower, stored in place.
            var ok = true
            for j in 0..<nb {
                var d = mr[j * nb + j]
                for k in 0..<j { d -= mr[j * nb + k] * mr[j * nb + k] + mi[j * nb + k] * mi[j * nb + k] }
                guard d > 0 else { ok = false; break }
                let l = d.squareRoot()
                mr[j * nb + j] = l; mi[j * nb + j] = 0
                for i in (j + 1)..<max(j + 1, nb) {
                    // L[i][j] = (M[i][j] − Σ L[i][k] conj(L[j][k])) / L[j][j]
                    var sr = mr[i * nb + j], si = mi[i * nb + j]
                    for k in 0..<j {
                        let pr = mr[i * nb + k], pi = mi[i * nb + k], qr = mr[j * nb + k], qi = mi[j * nb + k]
                        sr -= pr * qr + pi * qi
                        si -= pi * qr - pr * qi
                    }
                    mr[i * nb + j] = sr / l; mi[i * nb + j] = si / l
                }
            }
            guard ok else { continue }
            // Row a of A solves a · M = x, i.e. M aᴴ = xᴴ (M Hermitian).
            let xBase = band * K * nb
            for e in 0..<K {
                guard active[e] else { for j in 0..<nb { ar[e * nb + j] = 0; ai[e * nb + j] = 0 }; continue }
                // forward: L y = xᴴ
                for i in 0..<nb {
                    var sr = crossRe[xBase + e * nb + i], si = -crossIm[xBase + e * nb + i]
                    for k in 0..<i {
                        let lr = mr[i * nb + k], li = mi[i * nb + k]
                        sr -= lr * yr[k] - li * yi[k]
                        si -= lr * yi[k] + li * yr[k]
                    }
                    let l = mr[i * nb + i]
                    yr[i] = sr / l; yi[i] = si / l
                }
                // back: Lᴴ z = y, then a = zᴴ
                for i in stride(from: nb - 1, through: 0, by: -1) {
                    var sr = yr[i], si = yi[i]
                    for k in (i + 1)..<max(i + 1, nb) {
                        // Lᴴ[i][k] = conj(L[k][i])
                        let lr = mr[k * nb + i], li = -mi[k * nb + i]
                        let zr = ar[e * nb + k], zi = -ai[e * nb + k]
                        sr -= lr * zr - li * zi
                        si -= lr * zi + li * zr
                    }
                    let l = mr[i * nb + i]
                    ar[e * nb + i] = sr / l; ai[e * nb + i] = -(si / l)
                }
            }
            // W = R · A, or with folds D + (R − D · F) · A
            let folded = !foldGains.isEmpty
            for o in 0..<O {
                for j in 0..<nb {
                    wr[o * nb + j] = folded ? Double(fallback[o * nb + j]) : 0
                    wi[o * nb + j] = 0
                }
                guard o != lfeOutput else { continue }
                for e in 0..<K where active[e] {
                    var g = Double(gains[e * O + o])
                    if folded, e * O + o < foldGains.count { g += Double(foldGains[e * O + o]) }
                    guard g != 0 else { continue }
                    for j in 0..<nb { wr[o * nb + j] += g * ar[e * nb + j]; wi[o * nb + j] += g * ai[e * nb + j] }
                }
            }
            // Energy bound: trace(W C Wᴴ) against trace(C).
            var eo = 0.0
            for o in 0..<O where o != lfeOutput {
                for i in 0..<nb {
                    // (W C)[o][i] = Σ_j W[o][j] C[j][i]
                    var tr = 0.0, ti = 0.0
                    for j in 0..<nb {
                        let cr = j <= i ? covRe[cBase + j * nb + i] : covRe[cBase + i * nb + j]
                        let ci = j <= i ? covIm[cBase + j * nb + i] : -covIm[cBase + i * nb + j]
                        tr += wr[o * nb + j] * cr - wi[o * nb + j] * ci
                        ti += wr[o * nb + j] * ci + wi[o * nb + j] * cr
                    }
                    // · conj(W[o][i])
                    eo += tr * wr[o * nb + i] + ti * wi[o * nb + i]
                }
            }
            var g = 1.0
            if eo > 1e-15 {
                let r = eo / trace
                if r > bounds.upperBound { g = (bounds.upperBound / r).squareRoot() }
                else if r < bounds.lowerBound { g = (bounds.lowerBound / r).squareRoot() }
            }
            let wBase = band * O * nb
            for i in 0..<(O * nb) { weightRe[wBase + i] = Float(wr[i] * g); weightIm[wBase + i] = Float(wi[i] * g) }
        }
    }

    /// Output spectra: W interpolated linearly between band centres, times the bed; the LFE is the bed's.
    private func applyWeights() {
        let nb = bedInputs.count, O = outputs, bins = self.bins
        for i in outRe.indices { outRe[i] = 0; outIm[i] = 0 }
        weightRe.withUnsafeBufferPointer { wr in
        weightIm.withUnsafeBufferPointer { wi in
        bedRe.withUnsafeBufferPointer { br in
        bedIm.withUnsafeBufferPointer { bi in
        outRe.withUnsafeMutableBufferPointer { orr in
        outIm.withUnsafeMutableBufferPointer { oi in
            var lower = 0
            for k in 0..<bins {
                let fk = Float(k)
                while lower + 1 < bands, bandCenters[lower + 1] <= fk { lower += 1 }
                let upper = min(lower + 1, bands - 1)
                var t: Float = 0
                if upper != lower, fk > bandCenters[lower] {
                    t = min(1, (fk - bandCenters[lower]) / (bandCenters[upper] - bandCenters[lower]))
                }
                let l0 = lower * O * nb, u0 = upper * O * nb
                for o in 0..<O where o != lfeOutput {
                    var sr: Float = 0, si: Float = 0
                    for j in 0..<nb {
                        let w1r = wr[l0 + o * nb + j], w1i = wi[l0 + o * nb + j]
                        let cr = w1r + (wr[u0 + o * nb + j] - w1r) * t
                        let ci = w1i + (wi[u0 + o * nb + j] - w1i) * t
                        let xr = br[j * bins + k], xi = bi[j * bins + k]
                        sr += cr * xr - ci * xi
                        si += cr * xi + ci * xr
                    }
                    orr[o * bins + k] = sr
                    oi[o * bins + k] = si
                }
            }
        }}}}}}
        if bedLFE != nil {
            outRe.withUnsafeMutableBufferPointer { o in (o.baseAddress! + lfeOutput * bins).update(from: lfeRe, count: bins) }
            outIm.withUnsafeMutableBufferPointer { o in (o.baseAddress! + lfeOutput * bins).update(from: lfeIm, count: bins) }
        }
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
#endif
