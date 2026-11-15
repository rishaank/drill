// Shared look: Liquid Glass on macOS 26+, standard materials and bordered controls before it. Plus the ring, the sounds and the haptics.
import SwiftUI
import AVFoundation

// Drill's teal: bright on dark, deep enough for white text on light.
let tealNS = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    ? NSColor(srgbRed: 0.369, green: 0.918, blue: 0.831, alpha: 1) : NSColor(srgbRed: 0.059, green: 0.463, blue: 0.431, alpha: 1) }
let amberNS = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    ? NSColor(srgbRed: 0.984, green: 0.749, blue: 0.141, alpha: 1) : NSColor(srgbRed: 0.698, green: 0.314, blue: 0, alpha: 1) }
extension Color {
    static let drill = Color(nsColor: tealNS)
    static let amber = Color(nsColor: amberNS)
    static let heroTop = Color(red: 0.043, green: 0.31, blue: 0.282)
    static let heroGlow = Color(red: 0.102, green: 0.549, blue: 0.498)
    static let mint = Color(red: 0.561, green: 0.953, blue: 0.882)
}
extension Font {
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font { .system(size: size, weight: weight, design: .rounded) }
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font { .system(size: size, weight: weight, design: .serif) }
    // Card text is set in New York, which has no sub/superscript digits: formulas (SO₄²⁻, x²) stay in SF.
    static func card(_ text: String, _ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        text.range(of: "[₀-₉⁰-⁹⁺⁻₊₋]", options: .regularExpression) != nil ? .system(size: size, weight: weight) : serif(size, weight)
    }
}

extension View {
    // A real glass capsule on macOS 26; a bordered one before. Only the main action is tinted; the rest are plain glass.
    @ViewBuilder func glassButton(prominent: Bool = false, tint: Color = .drill) -> some View {
        if #available(macOS 26, *) {
            if prominent { buttonStyle(.glassProminent).tint(tint).buttonBorderShape(.capsule) } else { buttonStyle(.glass).tint(nil).buttonBorderShape(.capsule) }
        } else if #available(macOS 14, *) {
            if prominent { buttonStyle(.borderedProminent).tint(tint).buttonBorderShape(.capsule) } else { buttonStyle(.bordered).buttonBorderShape(.capsule) }
        } else {
            if prominent { buttonStyle(.borderedProminent).tint(tint) } else { buttonStyle(.bordered) }
        }
    }
    // A glass surface (tinted, optionally reacting to the pointer); a material before macOS 26.
    @ViewBuilder func glass(_ shape: some Shape = Capsule(), tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background { ZStack { shape.fill(.regularMaterial); if let tint { shape.fill(tint.opacity(0.35)) } } }
        }
    }
    @ViewBuilder func glassGroup(spacing: CGFloat? = nil) -> some View {
        if #available(macOS 26, *) { GlassEffectContainer(spacing: spacing) { self } } else { self }
    }
    @ViewBuilder func numericText(_ value: Double) -> some View {
        if #available(macOS 14, *) { contentTransition(.numericText(value: value)) } else { self }
    }
    // Content surfaces (cards, the schedule board): solid, never glass.
    func card(_ radius: CGFloat = 22) -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
    }
}

// Mastery ring, p from 0 to 1. Animates whenever p changes.
struct Ring: View {
    var p: Double
    var width: CGFloat = 3.5
    var color = Color.drill
    var track = Color.primary.opacity(0.11)
    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: width)
            Circle().trim(from: 0, to: max(0.0001, p)).stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90)).opacity(p > 0 ? 1 : 0)
        }
        .padding(width / 2)
        .animation(.spring(response: 0.9, dampingFraction: 0.9), value: p)
    }
}

// Pressing anything custom: a quick squeeze on mouse-down, a spring back on release.
struct Squeeze: ButtonStyle {
    var scale: CGFloat = 0.97
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? scale : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.08) : .spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// A miss shakes sideways.
struct Shake: GeometryEffect {
    var t: CGFloat
    var animatableData: CGFloat { get { t } set { t = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform { ProjectionTransform(CGAffineTransform(translationX: 5 * sin(t * .pi * 4), y: 0)) }
}

// Lays children out like words in a paragraph (fill-in-the-blank sentences).
struct Flow: Layout {
    var spacing: CGFloat = 0, line: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(proposal.width ?? .infinity, subviews).last.map { CGSize(width: proposal.width ?? $0.w, height: $0.y + $0.h) } ?? .zero
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, h: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x + z.width > b.maxX && x > b.minX { x = b.minX; y += h + line; h = 0 }
            s.place(at: CGPoint(x: x, y: y + (h > 0 ? (h - z.height) / 2 : 0)), proposal: .unspecified)
            x += z.width + spacing; h = max(h, z.height)
        }
    }
    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [(w: CGFloat, y: CGFloat, h: CGFloat)] {
        var out: [(w: CGFloat, y: CGFloat, h: CGFloat)] = [], x: CGFloat = 0, y: CGFloat = 0, h: CGFloat = 0, w: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x + z.width > width && x > 0 { out.append((w, y, h)); x = 0; y += h + line; h = 0 }
            x += z.width + spacing; w = max(w, x); h = max(h, z.height)
        }
        out.append((w, y, h)); return out
    }
}

// Sound and touch on the same frame as the answer: a chime that climbs a semitone with each answer in a row, a soft knock for a miss.
@MainActor enum Feel {
    static let engine = AVAudioEngine()
    static let player = AVAudioPlayerNode()
    static var ready = false
    static var soundOn = true
    static let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!

    static func play(_ kind: String, streak: Int = 0) {
        NSHapticFeedbackManager.defaultPerformer.perform(kind == "wrong" ? .generic : .levelChange, performanceTime: .now)
        guard soundOn else { return }
        let up = pow(2, Double(min(streak, 12)) / 12)
        let notes: [(Double, Double)] = ["right": [(659 * up, 0), (988 * up, 0.07)], "wrong": [(196, 0), (147, 0.06)],
            "round": [(523, 0), (659, 0.09), (784, 0.18)], "done": [(523, 0), (659, 0.1), (784, 0.2), (1047, 0.3)]][kind] ?? []
        let short = kind == "right" || kind == "wrong", peak: Float = kind == "wrong" ? 0.09 : 0.06
        let len = 0.8 + (notes.last?.1 ?? 0), n = Int(len * 44100)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return }
        buf.frameLength = AVAudioFrameCount(n)
        let out = buf.floatChannelData![0]
        for i in 0..<n { out[i] = 0 }
        for (f, at) in notes {
            let start = Int(at * 44100), decay = short ? 0.22 : 0.7
            for i in 0..<Int(0.8 * 44100) where start + i < n {
                let t = Double(i) / 44100
                let env = t < 0.008 ? Float(t / 0.008) * peak : peak * Float(pow(0.0001 / Double(peak), (t - 0.008) / (decay - 0.008)))
                let w = sin(2 * .pi * f * t)
                let wave = kind == "wrong" ? Float(2 / Double.pi * asin(w)) : Float(w)  // triangle for a miss
                out[start + i] += (t > decay ? 0 : env) * wave
            }
        }
        if !ready {
            engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
            do { try engine.start(); ready = true } catch { return }
        }
        player.scheduleBuffer(buf, at: nil)
        if !player.isPlaying { player.play() }
    }
}
