import CoreGraphics
import QuartzCore
import Foundation
import Testing
@testable import AetherEngine

@Suite("Picture fill geometry")
struct PictureFillGeometryTests {
    private let full = CGRect(x: 0, y: 0, width: 1, height: 1)
    private let scope = SyntheticFrame.centred(ratio: 2.39)

    private func close(_ a: CGRect, _ b: CGRect, _ e: CGFloat = 0.5) -> Bool {
        abs(a.minX - b.minX) <= e && abs(a.minY - b.minY) <= e && abs(a.width - b.width) <= e && abs(a.height - b.height) <= e
    }

    private func apply(_ t: CGAffineTransform, _ p: CGPoint, about c: CGPoint) -> CGPoint {
        let q = CGPoint(x: p.x - c.x, y: p.y - c.y).applying(t)
        return CGPoint(x: q.x + c.x, y: q.y + c.y)
    }

    @Test("the full frame as area reproduces aspect fill (Sodalite#118)", .timeLimit(.minutes(3)))
    func fullFrameEqualsAspectFill() {
        let plane = PictureFillGeometry.planeRect(presentationSize: CGSize(width: 1440, height: 1080), area: full,
                                                  bounds: CGSize(width: 1920, height: 1080))
        #expect(close(plane, CGRect(x: 0, y: -180, width: 1920, height: 1440)))
    }

    @Test("a 2.39 band in a 16:9 picture covers a 16:9 screen (Sodalite#118)", .timeLimit(.minutes(3)))
    func letterbox239CoversScreen() {
        let size = CGSize(width: 1920, height: 1080)
        let t = PictureFillGeometry.coverTransform(presentationSize: size, area: scope, bounds: size)
        #expect(abs(t.a - 1.3444) <= 0.001)
        #expect(abs(t.d - 1.3444) <= 0.001)
        let plane = PictureFillGeometry.planeRect(presentationSize: size, area: scope, bounds: size)
        #expect(close(plane, CGRect(x: -330.7, y: -186.0, width: 2581.3, height: 1452.0)))
    }

    @Test("an off-centre area is moved to the centre (Sodalite#118)", .timeLimit(.minutes(3)))
    func offCentreAreaIsCentred() {
        let size = CGSize(width: 1920, height: 1080)
        let area = scope.offsetBy(dx: 0, dy: -0.05)
        let t = PictureFillGeometry.coverTransform(presentationSize: size, area: area, bounds: size)
        let centre = CGPoint(x: 960, y: 540)
        let mapped = apply(t, CGPoint(x: area.midX * 1920, y: area.midY * 1080), about: centre)
        #expect(abs(mapped.x - 960) <= 0.5)
        #expect(abs(mapped.y - 540) <= 0.5)
    }

    @Test("the cover scale follows the bounds (Sodalite#118)", .timeLimit(.minutes(3)))
    func coverTransformFollowsBounds() {
        let size = CGSize(width: 1920, height: 1080)
        let pillar = SyntheticFrame.centred(ratio: 4.0 / 3.0)
        let tv = CGSize(width: 1920, height: 1080), phone = CGSize(width: 2556, height: 1179)
        let a = PictureFillGeometry.coverTransform(presentationSize: size, area: pillar, bounds: tv)
        let b = PictureFillGeometry.coverTransform(presentationSize: size, area: pillar, bounds: phone)
        #expect(abs(a.a - b.a) > 0.1)
        for (bounds, t) in [(tv, a), (phone, b)] {
            let plane = PictureFillGeometry.planeRect(presentationSize: size, area: pillar, bounds: bounds)
            let covered = CGRect(x: plane.minX + pillar.minX * plane.width, y: plane.minY + pillar.minY * plane.height,
                                 width: pillar.width * plane.width, height: pillar.height * plane.height)
            #expect(covered.minX <= 0.5 && covered.minY <= 0.5)
            #expect(covered.maxX >= bounds.width - 0.5 && covered.maxY >= bounds.height - 0.5)
            #expect(t.a == t.d)
        }
    }

    @Test("a picture that already covers the screen changes nothing (Sodalite#118)", .timeLimit(.minutes(3)))
    func noChangeWhenAlreadyCovering() {
        let size = CGSize(width: 2390, height: 1000)
        #expect(!PictureFillGeometry.changesPicture(presentationSize: size, area: full, bounds: size))
        let wide = CGSize(width: 1920, height: 1080)
        #expect(PictureFillGeometry.changesPicture(presentationSize: wide, area: scope, bounds: wide))
    }

    @Test("an unknown size or empty bounds gives the identity (Sodalite#118)", .timeLimit(.minutes(3)))
    func degenerateInputsAreIdentity() {
        #expect(PictureFillGeometry.coverTransform(presentationSize: .zero, area: scope,
                                                   bounds: CGSize(width: 1920, height: 1080)).isIdentity)
        #expect(PictureFillGeometry.coverTransform(presentationSize: CGSize(width: 1920, height: 1080), area: scope,
                                                   bounds: .zero).isIdentity)
    }

    @Test("a bottom-left anchored, y-up layer maps the area centre to the middle (Sodalite#118)", .timeLimit(.minutes(3)))
    func sublayerTransformForYUpLayer() {
        let size = CGSize(width: 1920, height: 1080)
        let area = scope.offsetBy(dx: 0, dy: -0.05)
        let t = PictureFillGeometry.coverTransform(presentationSize: size, area: area, bounds: size)
        let m = PictureFillGeometry.sublayerTransform(t, bounds: CGRect(origin: .zero, size: size),
                                                      anchorPoint: .zero, yUp: true)
        // In y-up coordinates the area's centre sits at 1080 - midY.
        let p = CGPoint(x: area.midX * 1920, y: 1080 - area.midY * 1080).applying(m)
        #expect(abs(p.x - 960) <= 0.5)
        #expect(abs(p.y - 540) <= 0.5)
    }
}

@Suite("Engine fill area")
struct EngineFillAreaTests {
    @MainActor
    @Test("a fill area lays the engine's layers out aspect-fit and nil restores the host's gravity (Sodalite#118)",
          .timeLimit(.minutes(3)))
    func fillAreaOverridesGravity() throws {
        let engine = try AetherEngine()
        engine.videoGravity = .resizeAspectFill
        #expect(engine.effectiveVideoGravity == .resizeAspectFill)
        engine.setFillPictureArea(SyntheticFrame.centred(ratio: 2.39))
        #expect(engine.effectiveVideoGravity == .resizeAspect)
        #expect(engine.videoGravity == .resizeAspectFill)
        engine.setFillPictureArea(nil)
        #expect(engine.effectiveVideoGravity == .resizeAspectFill)
    }

    @MainActor
    @Test("a bound view zooms once the software size is known (Sodalite#118)", .timeLimit(.minutes(3)))
    func boundViewGetsSublayerTransform() throws {
        let engine = try AetherEngine()
        let view = AetherPlayerView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        engine.bind(view: view)
        engine.setFillPictureArea(SyntheticFrame.centred(ratio: 2.39))
        engine.softwareDisplaySize = CGSize(width: 1920, height: 1080)
        #if canImport(UIKit)
        let host: CALayer = view.layer
        #else
        let host: CALayer = try #require(view.layer)
        #endif
        let t = CATransform3DGetAffineTransform(host.sublayerTransform)
        #expect(abs(t.a - 1.3444) <= 0.001)
        engine.setFillPictureArea(nil)
        #expect(CATransform3DIsIdentity(host.sublayerTransform))
        engine.unbind(view: view)
    }

    @MainActor
    private func hostLayer(_ view: AetherPlayerView) throws -> CALayer {
        #if canImport(UIKit)
        return view.layer
        #else
        return try #require(view.layer)
        #endif
    }

    @MainActor
    @Test("the zoom holds while the picture size is briefly unknown (a held still across a rebuild) (Sodalite#118)",
          .timeLimit(.minutes(3)))
    func zoomHoldsWhilePlaneIsUnknown() throws {
        let engine = try AetherEngine()
        let view = AetherPlayerView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        engine.bind(view: view)
        engine.setFillPictureArea(SyntheticFrame.centred(ratio: 2.39))
        engine.softwareDisplaySize = CGSize(width: 1920, height: 1080)
        engine.softwareDisplaySize = nil
        let t = CATransform3DGetAffineTransform(try hostLayer(view).sublayerTransform)
        #expect(abs(t.a - 1.3444) <= 0.001)
        engine.unbind(view: view)
    }

    @MainActor
    @Test("a surface the layer falls back to after an unbind keeps the zoom (Sodalite#118)", .timeLimit(.minutes(3)))
    func fallbackSurfaceKeepsZoom() throws {
        let engine = try AetherEngine()
        let first = AetherPlayerView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let second = AetherPlayerView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        engine.bind(view: first)
        engine.setFillPictureArea(SyntheticFrame.centred(ratio: 2.39))
        engine.softwareDisplaySize = CGSize(width: 1920, height: 1080)
        engine.bind(view: second)
        engine.unbind(view: second)
        let t = CATransform3DGetAffineTransform(try hostLayer(first).sublayerTransform)
        #expect(abs(t.a - 1.3444) <= 0.001)
        engine.unbind(view: first)
    }

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    @MainActor
    @Test("a detached view gives clipping back even with no layer hosted (Sodalite#118)", .timeLimit(.minutes(3)))
    func detachRestoresClipping() throws {
        let view = AetherPlayerView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let host = try hostLayer(view)
        host.masksToBounds = false
        view.setFill(area: SyntheticFrame.centred(ratio: 2.39), softwarePresentationSize: nil, animated: false)
        #expect(host.masksToBounds)
        view.detach()
        #expect(!host.masksToBounds)
    }
    #endif
}
