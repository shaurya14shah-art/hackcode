import SwiftUI
import AppKit
import QuartzCore

/// Falling-glyph background (revived from HackCode 2.x), rebuilt on Core Animation:
/// - each column is a CALayer whose image is rendered only when its glyphs change;
/// - the falling motion is a CABasicAnimation interpolated by the system compositor, so HackCode itself
///   does almost no per-frame work (a SwiftUI Canvas redraw at 24 fps measured ~21% of a core);
/// - glyph mutations are throttled (a few columns, a few times per second);
/// - static when Reduce Motion is on, paused while the window is fully hidden, faster while HackCode works.
struct MatrixRainView: View {
    var isWorking: Bool
    var color: Color = Theme.accent
    var intensity: Double = 0.45
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MatrixRainLayerView(isWorking: isWorking, color: NSColor(color), intensity: intensity, reduceMotion: reduceMotion)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct MatrixRainLayerView: NSViewRepresentable {
    let isWorking: Bool
    let color: NSColor
    let intensity: Double
    let reduceMotion: Bool

    func makeNSView(context: Context) -> MatrixRainNSView {
        let view = MatrixRainNSView()
        view.configure(color: color, intensity: intensity, working: isWorking, reduceMotion: reduceMotion)
        return view
    }

    func updateNSView(_ view: MatrixRainNSView, context: Context) {
        view.configure(color: color, intensity: intensity, working: isWorking, reduceMotion: reduceMotion)
    }
}

final class MatrixRainNSView: NSView, CAAnimationDelegate {
    static let glyphs = Array("ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ0123456789ABCDEFZ:.=*+-<>¦|")
    static let fontSize: CGFloat = 13
    static let lineHeight: CGFloat = 16
    static let columnWidth: CGFloat = 18
    static let fallKey = "fall"

    private struct Column {
        let layer: CALayer
        var glyphs: [Character]
        var speed: CGFloat
    }

    private var columns: [Column] = []
    private var color: NSColor = .systemGreen
    private var working = false
    private var reduceMotion = false
    private var mutationTimer: Timer?
    private var builtForSize: CGSize = .zero
    private var occlusionObserver: NSObjectProtocol?
    private let font = NSFont.monospacedSystemFont(ofSize: MatrixRainNSView.fontSize, weight: .medium)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func configure(color: NSColor, intensity: Double, working: Bool, reduceMotion: Bool) {
        layer?.opacity = Float(intensity)
        let colorChanged = !color.isEqual(self.color)
        self.color = color
        if working != self.working {
            self.working = working
            setRootSpeed(working ? 1.9 : 1)
            for i in columns.indices { render(i) }   // heads turn white while working
        }
        if reduceMotion != self.reduceMotion {
            self.reduceMotion = reduceMotion
            rebuild(force: true)
        }
        if colorChanged { for i in columns.indices { render(i) } }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        guard let window else {
            // Leaving the window (or being torn down): stop all timers/observers; nothing outlives the view.
            mutationTimer?.invalidate()
            mutationTimer = nil
            return
        }
        layer?.contentsScale = window.backingScaleFactor
        // Pause completely while the window is not visible on screen.
        occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateForOcclusion() }
        }
        startMutationTimer()
    }

    override func layout() {
        super.layout()
        rebuild(force: false)
    }

    // MARK: Columns

    private func rebuild(force: Bool) {
        let size = bounds.size
        guard size.width > 1, size.height > 1 else { return }
        if !force, abs(size.width - builtForSize.width) < 1, abs(size.height - builtForSize.height) < 1 { return }
        builtForSize = size
        columns.forEach { $0.layer.removeFromSuperlayer() }
        columns.removeAll()
        let count = max(1, Int(size.width / Self.columnWidth))
        for i in 0..<count {
            let layer = CALayer()
            layer.contentsScale = window?.backingScaleFactor ?? 2
            layer.anchorPoint = CGPoint(x: 0.5, y: 1)    // position.y = head (bottom) of the trail
            layer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
            self.layer?.addSublayer(layer)
            columns.append(Column(layer: layer, glyphs: Self.randomGlyphs(), speed: CGFloat.random(in: 70...210)))
            render(i)
            let x = CGFloat(i) * Self.columnWidth + Self.columnWidth / 2
            if reduceMotion {
                layer.position = CGPoint(x: x, y: CGFloat.random(in: 0...size.height))
            } else {
                startFall(i, x: x, from: CGFloat.random(in: -size.height...size.height))
            }
        }
    }

    private func startFall(_ i: Int, x: CGFloat, from startY: CGFloat) {
        let layer = columns[i].layer
        let height = layer.bounds.height
        let endY = bounds.height + height
        let distance = max(1, endY - startY)
        let anim = CABasicAnimation(keyPath: "position.y")
        anim.fromValue = startY
        anim.toValue = endY
        anim.duration = CFTimeInterval(distance / columns[i].speed)
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        anim.isRemovedOnCompletion = true
        anim.delegate = self
        anim.setValue(i, forKey: "column")
        layer.position = CGPoint(x: x, y: endY)     // model value = final position
        layer.add(anim, forKey: Self.fallKey)
    }

    nonisolated func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        guard flag, let i = anim.value(forKey: "column") as? Int else { return }
        MainActor.assumeIsolated {
            guard i < columns.count, !reduceMotion else { return }
            // Recycle the column above the top edge with fresh glyphs and speed.
            columns[i].glyphs = Self.randomGlyphs()
            columns[i].speed = CGFloat.random(in: 70...210)
            render(i)
            startFall(i, x: columns[i].layer.position.x, from: -CGFloat.random(in: 20...max(40, bounds.height * 0.5)))
        }
    }

    /// Renders a column's trail (fading glyphs + bright head) into the layer's image.
    private func render(_ i: Int) {
        let glyphs = columns[i].glyphs
        let scale = window?.backingScaleFactor ?? 2
        let size = CGSize(width: Self.columnWidth, height: CGFloat(glyphs.count) * Self.lineHeight)
        // Render in the screen's colour space: a DeviceRGB image is colour-converted by Core Animation on every commit.
        let space = window?.screen?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let base = color.usingColorSpace(window?.screen?.colorSpace ?? .displayP3) ?? color
        for (index, glyph) in glyphs.enumerated() {
            let isHead = index == glyphs.count - 1
            let fade = CGFloat(index + 1) / CGFloat(glyphs.count)
            let glyphColor: NSColor = isHead ? (working ? .white : base.blended(withFraction: 0.55, of: .white) ?? base)
                                             : base.withAlphaComponent(0.15 + fade * (working ? 0.85 : 0.75))
            let text = NSAttributedString(string: String(glyph), attributes: [.font: font, .foregroundColor: glyphColor])
            let w = text.size().width
            // CoreGraphics origin is bottom-left: glyph 0 at the top, head at the bottom.
            let y = size.height - CGFloat(index + 1) * Self.lineHeight + 2
            text.draw(at: CGPoint(x: (size.width - w) / 2, y: y))
        }
        NSGraphicsContext.current = previous
        let layer = columns[i].layer
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.contents = ctx.makeImage()
    }

    private func startMutationTimer() {
        mutationTimer?.invalidate()
        guard !reduceMotion else { return }
        // A handful of glyph swaps per tick keeps the "living code" feel without re-rendering every column.
        mutationTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.columns.isEmpty, self.window?.occlusionState.contains(.visible) == true else { return }
                for _ in 0..<min(4, self.columns.count) {
                    let i = Int.random(in: 0..<self.columns.count)
                    let g = Int.random(in: 0..<self.columns[i].glyphs.count)
                    self.columns[i].glyphs[g] = Self.glyphs.randomElement() ?? "0"
                    self.render(i)
                }
            }
        }
    }

    private func updateForOcclusion() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        setRootSpeed(visible ? (working ? 1.9 : 1) : 0)
    }

    /// Changes animation speed without making columns jump (standard CALayer time-offset technique).
    private func setRootSpeed(_ speed: Float) {
        guard let root = layer, root.speed != speed else { return }
        let now = CACurrentMediaTime()
        let localTime = root.convertTime(now, from: nil)
        root.speed = speed
        root.timeOffset = localTime
        root.beginTime = now
    }

    #if DEBUG || SNAPSHOT_HARNESS
    /// Snapshot support: pins every column at its current on-screen (presentation) position so a static
    /// capture shows the rain, then `debugResume()` restarts the fall.
    func debugFreeze() {
        for c in columns {
            if let p = c.layer.presentation()?.position { c.layer.position = p }
            c.layer.removeAnimation(forKey: Self.fallKey)
        }
    }

    func debugResume() { rebuild(force: true) }

    static func all(in view: NSView) -> [MatrixRainNSView] {
        (view as? MatrixRainNSView).map { [$0] } ?? view.subviews.flatMap { all(in: $0) }
    }
    #endif

    private static func randomGlyphs() -> [Character] {
        (0..<Int.random(in: 8...26)).map { _ in glyphs.randomElement() ?? "0" }
    }
}
