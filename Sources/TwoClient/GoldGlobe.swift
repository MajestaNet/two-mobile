// Copyright 2026 MajestaNet
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Shared push-to-talk mark for the phone and the watch.
/// Paths are the globe.svg network, ring-centered. Nodes stay on those junctions.
public enum GoldGlobeActivity: Equatable, Sendable {
    case ready
    case listening
    case sending
    case unavailable

    public static func talk(holding: Bool, sending: Bool, available: Bool) -> GoldGlobeActivity {
        if !available { return .unavailable }
        if holding { return .listening }
        if sending { return .sending }
        return .ready
    }

    public var accessibilityLabel: String {
        switch self {
        case .ready: "Hold to speak"
        case .listening: "Listening"
        case .sending: "Sending"
        case .unavailable: "Unavailable"
        }
    }
}

public struct GoldGlobe: View {
    public var activity: GoldGlobeActivity

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(activity: GoldGlobeActivity) {
        self.activity = activity
    }

    public var body: some View {
        let paused = reduceMotion || activity == .unavailable
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { timeline in
            Canvas { context, size in
                GoldGlobeDrawing.draw(
                    context: &context,
                    size: size,
                    time: timeline.date.timeIntervalSinceReferenceDate,
                    activity: activity,
                    reduceMotion: reduceMotion
                )
            }
        }
        .accessibilityHidden(true)
    }
}

/// Deep field behind the phone. Stars are fixed so the field does not shimmer.
public struct SpaceBackground: View {
    public init() {}

    public var body: some View {
        Canvas { context, size in
            SpaceDrawing.draw(context: &context, size: size)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

private enum Gold {
    static let hot = Color(red: 1, green: 0.98, blue: 0.91)
    static let highlight = Color(red: 1, green: 0.94, blue: 0.74)
    static let brand = Color(red: 246 / 255, green: 207 / 255, blue: 85 / 255)
    static let deep = Color(red: 176 / 255, green: 118 / 255, blue: 32 / 255)
    static let shadow = Color(red: 74 / 255, green: 46 / 255, blue: 14 / 255)
}

private enum MarkSpace {
    /// Ring extrema from globe.svg, in the path's own coordinates.
    static let cx = (562.062 + 499.821) / 2
    static let cy = (320.254 + 258.013) / 2
    static let radius = (562.062 - 499.821) / 2
    static let arcWidth = 0.6868 / radius
    static let ringWidth = 1.5024 / radius
    static let nodeRadius = 1.931 / radius

    static func v(_ x: Double, _ y: Double) -> Vec {
        Vec(x: (x - cx) / radius, y: (y - cy) / radius)
    }
}

private enum GoldGlobeDrawing {
    static func draw(
        context: inout GraphicsContext,
        size: CGSize,
        time: Double,
        activity: GoldGlobeActivity,
        reduceMotion: Bool
    ) {
        let side = min(size.width, size.height)
        guard side > 1 else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = side * 0.33
        let still = reduceMotion || activity == .unavailable
        let motion = still ? Motion.still : Motion.profile(activity)
        let clock = still ? 0 : time
        let breathe = 0.5 + 0.5 * sin(clock * motion.breathe)
        let wash: Double
        if reduceMotion && activity == .listening {
            wash = 0.2
        } else if reduceMotion && activity == .sending {
            wash = 0.12
        } else {
            wash = motion.wash * (0.62 + 0.38 * breathe)
        }
        let markRadius = radius * (1 + motion.throb * sin(clock * motion.breathe))
        let arcWidth = markRadius * MarkSpace.arcWidth
        let ringWidth = markRadius * MarkSpace.ringWidth
        let nodeRadius = markRadius * MarkSpace.nodeRadius

        if wash > 0.01 {
            let glowRadius = markRadius * 1.42
            let glow = CGRect(
                x: center.x - glowRadius,
                y: center.y - glowRadius,
                width: glowRadius * 2,
                height: glowRadius * 2
            )
            context.fill(
                Path(ellipseIn: glow),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: Gold.brand.opacity(wash), location: 0.2),
                        .init(color: Gold.deep.opacity(wash * 0.35), location: 0.62),
                        .init(color: Gold.brand.opacity(0), location: 1),
                    ]),
                    center: center,
                    startRadius: markRadius * 0.2,
                    endRadius: glowRadius
                )
            )
        }

        if !still {
            let rings = activity == .listening ? 3 : 2
            for index in 0..<rings {
                let phase = fract(clock / motion.ringPeriod + Double(index) / Double(rings))
                let fade = (1 - phase) * (1 - phase)
                let ringRadius = radius * (0.88 + phase * 0.48)
                strokeCircle(
                    &context,
                    center: center,
                    radius: ringRadius,
                    shading: .color(Gold.brand.opacity(fade * motion.ringAlpha)),
                    width: max(1, arcWidth * 0.7)
                )
            }
        }

        drawSphere(&context, center: center, radius: markRadius - ringWidth * 0.12)

        let orbits = Array(GoldGlobeMark.measured.prefix(GoldGlobeMark.orbitCount))
        let network = Array(GoldGlobeMark.measured.dropFirst(GoldGlobeMark.orbitCount))
        drawWires(&context, curves: orbits, center: center, radius: markRadius, width: arcWidth)
        if !still {
            drawGleams(&context, curves: orbits, center: center, radius: markRadius, width: arcWidth, clock: clock, motion: motion)
        }
        drawRing(&context, center: center, radius: markRadius, width: ringWidth)
        drawWires(&context, curves: network, center: center, radius: markRadius, width: arcWidth)
        if !still {
            drawGleams(&context, curves: network, center: center, radius: markRadius, width: arcWidth, clock: clock, motion: motion)
        }

        for node in GoldGlobeMark.nodes {
            drawNode(&context, at: place(node, center, markRadius), radius: nodeRadius)
        }
    }

    private static func drawSphere(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let light = CGPoint(x: center.x - radius * 0.32, y: center.y - radius * 0.38)
        context.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: Color(red: 0.45, green: 0.58, blue: 0.72), location: 0),
                    .init(color: Color(red: 0.20, green: 0.33, blue: 0.48), location: 0.20),
                    .init(color: Color(red: 27 / 255, green: 46 / 255, blue: 70 / 255), location: 0.46),
                    .init(color: Color(red: 0.05, green: 0.10, blue: 0.17), location: 0.78),
                    .init(color: Color(red: 0.02, green: 0.04, blue: 0.07), location: 1),
                ]),
                center: light,
                startRadius: radius * 0.02,
                endRadius: radius * 1.62
            )
        )
        let sheen = CGRect(
            x: light.x - radius * 0.16,
            y: light.y - radius * 0.10,
            width: radius * 0.32,
            height: radius * 0.20
        )
        context.fill(
            Path(ellipseIn: sheen),
            with: .radialGradient(
                Gradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0)]),
                center: CGPoint(x: sheen.midX, y: sheen.midY),
                startRadius: 0,
                endRadius: min(sheen.width, sheen.height) * 0.6
            )
        )
    }

    private static func drawWires(
        _ context: inout GraphicsContext,
        curves: [MeasuredCurve],
        center: CGPoint,
        radius: CGFloat,
        width: CGFloat
    ) {
        let path = wirePath(curves, center: center, radius: radius)
        let shading = metalShading(center: center, radius: radius)
        context.stroke(
            path,
            with: .color(Gold.shadow.opacity(0.55)),
            style: StrokeStyle(lineWidth: width * 1.38, lineCap: .round, lineJoin: .round)
        )
        context.stroke(path, with: shading, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        context.stroke(
            path,
            with: specularShading(center: center, radius: radius),
            style: StrokeStyle(lineWidth: width * 0.34, lineCap: .round, lineJoin: .round)
        )
    }

    private static func drawRing(
        _ context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        width: CGFloat
    ) {
        strokeCircle(&context, center: center, radius: radius, shading: .color(Gold.shadow.opacity(0.7)), width: width * 1.32)
        strokeCircle(&context, center: center, radius: radius, shading: ringShading(center: center), width: width)
        strokeCircle(
            &context,
            center: center,
            radius: radius,
            shading: ringSpecular(center: center),
            width: width * 0.28
        )
    }

    private static func drawGleams(
        _ context: inout GraphicsContext,
        curves: [MeasuredCurve],
        center: CGPoint,
        radius: CGFloat,
        width: CGFloat,
        clock: Double,
        motion: Motion
    ) {
        for (index, curve) in curves.enumerated() {
            gleam(&context, curve: curve, phase: clock * motion.gleamSpeed + Double(index) * 0.17, center: center, radius: radius, width: width)
            if motion.gleamExtra {
                gleam(&context, curve: curve, phase: clock * motion.gleamSpeed + Double(index) * 0.17 + 0.5, center: center, radius: radius, width: width)
            }
        }
    }

    /// A bright bead and its tail, both samples of the same cubic. The tail is a sub-curve, not a chord.
    private static func gleam(
        _ context: inout GraphicsContext,
        curve: MeasuredCurve,
        phase: Double,
        center: CGPoint,
        radius: CGFloat,
        width: CGFloat
    ) {
        let loop = fract(phase)
        let forward = loop < 0.5
        let travel = smooth(forward ? loop * 2 : (1 - loop) * 2)
        let fade = sin(travel * .pi)
        guard fade > 0.04 else { return }
        let behind = forward ? max(0, travel - 0.09) : min(1, travel + 0.09)
        let span = curve.cubics(from: min(travel, behind), to: max(travel, behind))
        if span.isEmpty == false {
            var path = Path()
            add(span, to: &path, center: center, radius: radius)
            context.stroke(
                path,
                with: .color(Gold.hot.opacity(0.95 * fade)),
                style: StrokeStyle(lineWidth: width * 0.72, lineCap: .round, lineJoin: .round)
            )
        }
        let head = place(curve.point(at: travel), center, radius)
        let headRadius = max(width * 0.48, 0.8)
        fillCircle(&context, center: head, radius: headRadius * 2.1, color: Gold.highlight.opacity(0.28 * fade))
        fillCircle(&context, center: head, radius: headRadius, color: Gold.hot.opacity(min(1, fade)))
    }

    private static func drawNode(_ context: inout GraphicsContext, at center: CGPoint, radius: CGFloat) {
        fillCircle(&context, center: center, radius: radius * 1.42, color: Gold.brand.opacity(0.12))
        let light = CGPoint(x: center.x - radius * 0.34, y: center.y - radius * 0.40)
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: Gold.hot, location: 0),
                    .init(color: Gold.highlight, location: 0.22),
                    .init(color: Gold.brand, location: 0.5),
                    .init(color: Gold.deep, location: 0.8),
                    .init(color: Gold.shadow, location: 1),
                ]),
                center: light,
                startRadius: 0,
                endRadius: radius * 1.6
            )
        )
        fillCircle(&context, center: light, radius: radius * 0.24, color: Color.white.opacity(0.82))
    }

    private static func metalShading(center: CGPoint, radius: CGFloat) -> GraphicsContext.Shading {
        .linearGradient(
            Gradient(stops: [
                .init(color: Gold.highlight, location: 0),
                .init(color: Gold.brand, location: 0.34),
                .init(color: Color(red: 214 / 255, green: 158 / 255, blue: 48 / 255), location: 0.68),
                .init(color: Gold.deep, location: 1),
            ]),
            startPoint: CGPoint(x: center.x - radius, y: center.y - radius),
            endPoint: CGPoint(x: center.x + radius, y: center.y + radius)
        )
    }

    private static func specularShading(center: CGPoint, radius: CGFloat) -> GraphicsContext.Shading {
        .linearGradient(
            Gradient(stops: [
                .init(color: Color.white.opacity(0.92), location: 0),
                .init(color: Gold.highlight.opacity(0.45), location: 0.28),
                .init(color: Color.white.opacity(0), location: 0.58),
            ]),
            startPoint: CGPoint(x: center.x - radius, y: center.y - radius),
            endPoint: CGPoint(x: center.x + radius * 0.2, y: center.y + radius * 0.2)
        )
    }

    private static func ringShading(center: CGPoint) -> GraphicsContext.Shading {
        .conicGradient(
            Gradient(stops: [
                .init(color: Gold.brand, location: 0),
                .init(color: Gold.deep, location: 0.08),
                .init(color: Gold.shadow, location: 0.16),
                .init(color: Gold.deep, location: 0.30),
                .init(color: Gold.brand, location: 0.46),
                .init(color: Gold.highlight, location: 0.60),
                .init(color: Gold.hot, location: 0.68),
                .init(color: Gold.highlight, location: 0.78),
                .init(color: Gold.brand, location: 1),
            ]),
            center: center,
            angle: .degrees(0)
        )
    }

    private static func ringSpecular(center: CGPoint) -> GraphicsContext.Shading {
        .conicGradient(
            Gradient(stops: [
                .init(color: Color.white.opacity(0), location: 0),
                .init(color: Color.white.opacity(0), location: 0.56),
                .init(color: Color.white.opacity(0.8), location: 0.67),
                .init(color: Color.white.opacity(0), location: 0.80),
                .init(color: Color.white.opacity(0), location: 1),
            ]),
            center: center,
            angle: .degrees(0)
        )
    }

    private static func wirePath(_ curves: [MeasuredCurve], center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        for curve in curves {
            add(curve.cubics, to: &path, center: center, radius: radius)
        }
        return path
    }

    private static func add(_ cubics: [Cubic], to path: inout Path, center: CGPoint, radius: CGFloat) {
        guard let first = cubics.first else { return }
        path.move(to: place(first.a, center, radius))
        for cubic in cubics {
            path.addCurve(
                to: place(cubic.d, center, radius),
                control1: place(cubic.b, center, radius),
                control2: place(cubic.c, center, radius)
            )
        }
    }

    private static func strokeCircle(
        _ context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        shading: GraphicsContext.Shading,
        width: CGFloat
    ) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.stroke(Path(ellipseIn: rect), with: shading, style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    private static func fillCircle(
        _ context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        color: Color
    ) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: rect), with: .color(color))
    }

    private static func place(_ vector: Vec, _ center: CGPoint, _ radius: CGFloat) -> CGPoint {
        CGPoint(x: center.x + CGFloat(vector.x) * radius, y: center.y + CGFloat(vector.y) * radius)
    }

    private static func smooth(_ value: Double) -> Double {
        let t = min(max(value, 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func fract(_ value: Double) -> Double {
        value - floor(value)
    }
}

private struct Motion {
    var gleamSpeed: Double
    var gleamExtra: Bool
    var ringPeriod: Double
    var ringAlpha: Double
    var wash: Double
    var throb: Double
    var breathe: Double

    static let still = Motion(
        gleamSpeed: 0, gleamExtra: false,
        ringPeriod: 1, ringAlpha: 0, wash: 0.05, throb: 0, breathe: 0
    )

    static func profile(_ activity: GoldGlobeActivity) -> Motion {
        switch activity {
        case .ready:
            return Motion(
                gleamSpeed: 0.28, gleamExtra: false,
                ringPeriod: 2.7, ringAlpha: 0.28, wash: 0.10, throb: 0.012, breathe: 1.6
            )
        case .listening:
            return Motion(
                gleamSpeed: 0.82, gleamExtra: true,
                ringPeriod: 0.9, ringAlpha: 0.62, wash: 0.22, throb: 0.028, breathe: 4.4
            )
        case .sending:
            return Motion(
                gleamSpeed: 0.42, gleamExtra: false,
                ringPeriod: 1.3, ringAlpha: 0.46, wash: 0.16, throb: 0.02, breathe: 2.8
            )
        case .unavailable:
            return .still
        }
    }
}

private struct Vec {
    var x: Double
    var y: Double

    static func + (lhs: Vec, rhs: Vec) -> Vec {
        Vec(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    static func - (lhs: Vec, rhs: Vec) -> Vec {
        Vec(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    static func * (lhs: Vec, rhs: Double) -> Vec {
        Vec(x: lhs.x * rhs, y: lhs.y * rhs)
    }
}

private struct Cubic {
    var a: Vec
    var b: Vec
    var c: Vec
    var d: Vec

    func point(_ t: Double) -> Vec {
        let u = 1 - t
        return a * (u * u * u) + b * (3 * u * u * t) + c * (3 * u * t * t) + d * (t * t * t)
    }

    func split(at t: Double) -> (Cubic, Cubic) {
        let t = min(max(t, 0), 1)
        func mix(_ p: Vec, _ q: Vec) -> Vec { p + (q - p) * t }
        let ab = mix(a, b)
        let bc = mix(b, c)
        let cd = mix(c, d)
        let abc = mix(ab, bc)
        let bcd = mix(bc, cd)
        let mid = mix(abc, bcd)
        return (Cubic(a: a, b: ab, c: abc, d: mid), Cubic(a: mid, b: bcd, c: cd, d: d))
    }

    func subcurve(from t0: Double, to t1: Double) -> Cubic {
        let start = min(max(t0, 0), 1)
        let end = min(max(t1, 0), 1)
        if end - start < 1e-5 {
            let p = point(start)
            return Cubic(a: p, b: p, c: p, d: p)
        }
        if start <= 1e-6 && end >= 1 - 1e-6 { return self }
        if start >= 1 - 1e-6 {
            let p = point(1)
            return Cubic(a: p, b: p, c: p, d: p)
        }
        let localEnd = (end - start) / (1 - start)
        return split(at: start).1.split(at: localEnd).0
    }
}

private struct MeasuredCubic {
    var cubic: Cubic
    var mark: [(t: Double, s: Double)]
    var length: Double

    init(_ cubic: Cubic) {
        self.cubic = cubic
        let steps = 48
        var samples: [(Double, Double)] = [(0, 0)]
        var length = 0.0
        var previous = cubic.point(0)
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let next = cubic.point(t)
            length += hypot(next.x - previous.x, next.y - previous.y)
            samples.append((t, length))
            previous = next
        }
        mark = samples
        self.length = length
    }

    func parameter(atLocalDistance distance: Double) -> Double {
        if distance <= 0 || length <= 0 { return 0 }
        if distance >= length { return 1 }
        var lo = 0
        var hi = mark.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if mark[mid].s <= distance { lo = mid } else { hi = mid }
        }
        let left = mark[lo]
        let right = mark[hi]
        let span = right.s - left.s
        let fraction = span > 1e-9 ? (distance - left.s) / span : 0
        return left.t + (right.t - left.t) * fraction
    }
}

private struct MeasuredCurve {
    var cubics: [Cubic]
    var parts: [MeasuredCubic]
    var length: Double

    init(_ cubics: [Cubic]) {
        self.cubics = cubics
        parts = cubics.map { MeasuredCubic($0) }
        length = parts.reduce(0) { $0 + $1.length }
    }

    func point(at fraction: Double) -> Vec {
        let target = min(max(fraction, 0), 1) * length
        var cursor = 0.0
        for (index, part) in parts.enumerated() {
            let end = cursor + part.length
            if target <= end || index == parts.count - 1 {
                return part.cubic.point(part.parameter(atLocalDistance: target - cursor))
            }
            cursor = end
        }
        return cubics.last?.d ?? Vec(x: 0, y: 0)
    }

    func cubics(from start: Double, to end: Double) -> [Cubic] {
        let lower = min(start, end) * length
        let upper = max(start, end) * length
        guard upper - lower > 1e-5 else { return [] }
        var result: [Cubic] = []
        var cursor = 0.0
        for part in parts {
            let pieceEnd = cursor + part.length
            let from = max(lower, cursor)
            let to = min(upper, pieceEnd)
            if to - from > 1e-5, part.length > 0 {
                let t0 = part.parameter(atLocalDistance: from - cursor)
                let t1 = part.parameter(atLocalDistance: to - cursor)
                result.append(part.cubic.subcurve(from: t0, to: t1))
            }
            cursor = pieceEnd
        }
        return result
    }
}

private enum GoldGlobeMark {
    static let orbitCount = 3

    static func v(_ x: Double, _ y: Double) -> Vec { MarkSpace.v(x, y) }

    static func curve(_ raw: [(Double, Double)]) -> [Cubic] {
        var cubics: [Cubic] = []
        var index = 0
        while index + 3 < raw.count {
            cubics.append(Cubic(
                a: v(raw[index].0, raw[index].1),
                b: v(raw[index + 1].0, raw[index + 1].1),
                c: v(raw[index + 2].0, raw[index + 2].1),
                d: v(raw[index + 3].0, raw[index + 3].1)
            ))
            index += 3
        }
        return cubics
    }

    /// Node centers from globe.svg. The ring is the unit circle.
    static let nodes: [Vec] = [
        v(523.859, 268.959),
        v(540.17, 266.598),
        v(550.043, 274.325),
        v(527.508, 286.988),
        v(512.913, 281.407),
        v(514.63, 294.07),
        v(520.425, 313.172),
        v(536.522, 313.386),
        v(551.116, 295.787),
    ]

    /// Cubic control points copied from globe.svg. The first three paths orbit outside the ring.
    static let curves: [[Cubic]] = [
        curve([
            (513.343, 263.467), (500.894, 262.52), (495.743, 272.822), (497.245, 285.271),
            (498.748, 300.724), (509.05, 312.743), (520.425, 313.172),
        ]),
        curve([
            (540.171, 266.598), (544.034, 256.725), (551.546, 253.72), (555.41, 260.803),
            (557.341, 264.881), (557.985, 268.959), (556.268, 271.048),
        ]),
        curve([
            (536.522, 311.455), (544.464, 318.967), (550.902, 321.543), (555.195, 318.538),
            (559.273, 315.748), (559.702, 310.168), (556.268, 307.22),
        ]),
        curve([
            (523.859, 268.959), (536.307, 268.53), (548.755, 277.115), (551.116, 295.787),
        ]),
        curve([
            (527.508, 286.988), (536.951, 287.631), (544.463, 282.266), (550.043, 274.325),
        ]),
        curve([
            (514.63, 294.07), (513.557, 303.514), (517.206, 308.665), (520.425, 313.172),
        ]),
        curve([
            (512.913, 281.407), (521.283, 279.476), (523.43, 304.587), (536.522, 311.455),
        ]),
    ]

    static let measured: [MeasuredCurve] = curves.map { MeasuredCurve($0) }
}

private enum SpaceDrawing {
    struct Star {
        var x: Double
        var y: Double
        var radius: Double
        var alpha: Double
        var warm: Int
    }

    static let stars: [Star] = {
        var state: UInt64 = 0xA11CE
        func unit() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
        var stars: [Star] = []
        for _ in 0..<128 {
            let roll = unit()
            let bright = roll < 0.07
            stars.append(Star(
                x: unit(),
                y: unit(),
                radius: bright ? 1.15 + unit() * 0.85 : 0.35 + unit() * 0.7,
                alpha: bright ? 0.55 + unit() * 0.4 : 0.16 + unit() * 0.38,
                warm: unit() < 0.08 ? 2 : (unit() < 0.22 ? 1 : 0)
            ))
        }
        return stars
    }()

    static func draw(context: inout GraphicsContext, size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let bounds = CGRect(origin: .zero, size: size)
        context.fill(
            Path(bounds),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color(red: 8 / 255, green: 16 / 255, blue: 30 / 255), location: 0),
                    .init(color: Color(red: 16 / 255, green: 34 / 255, blue: 54 / 255), location: 0.26),
                    .init(color: Color(red: 27 / 255, green: 46 / 255, blue: 70 / 255), location: 0.46),
                    .init(color: Color(red: 12 / 255, green: 26 / 255, blue: 44 / 255), location: 0.72),
                    .init(color: Color(red: 5 / 255, green: 10 / 255, blue: 18 / 255), location: 1),
                ]),
                startPoint: CGPoint(x: size.width / 2, y: 0),
                endPoint: CGPoint(x: size.width / 2, y: size.height)
            )
        )

        let poolCenter = CGPoint(x: size.width / 2, y: size.height * 0.44)
        let pool = min(size.width, size.height) * 0.62
        context.fill(
            Path(bounds),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: Color(red: 0.29, green: 0.44, blue: 0.62).opacity(0.38), location: 0),
                    .init(color: Color(red: 0.29, green: 0.44, blue: 0.62).opacity(0), location: 1),
                ]),
                center: poolCenter,
                startRadius: 0,
                endRadius: pool
            )
        )
        context.fill(
            Path(bounds),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: Gold.brand.opacity(0.07), location: 0),
                    .init(color: Gold.brand.opacity(0), location: 1),
                ]),
                center: poolCenter,
                startRadius: 0,
                endRadius: pool * 0.55
            )
        )

        for star in stars {
            let center = CGPoint(x: star.x * size.width, y: star.y * size.height)
            let color: Color
            switch star.warm {
            case 2: color = Gold.highlight
            case 1: color = Color(red: 0.78, green: 0.86, blue: 1)
            default: color = Color.white
            }
            if star.radius > 1.1 {
                let halo = star.radius * 4.5
                let rect = CGRect(x: center.x - halo, y: center.y - halo, width: halo * 2, height: halo * 2)
                context.fill(
                    Path(ellipseIn: rect),
                    with: .radialGradient(
                        Gradient(colors: [color.opacity(star.alpha * 0.45), color.opacity(0)]),
                        center: center,
                        startRadius: 0,
                        endRadius: halo
                    )
                )
            }
            let rect = CGRect(
                x: center.x - star.radius,
                y: center.y - star.radius,
                width: star.radius * 2,
                height: star.radius * 2
            )
            context.fill(Path(ellipseIn: rect), with: .color(color.opacity(star.alpha)))
        }

        let vignette = max(size.width, size.height) * 0.78
        context.fill(
            Path(bounds),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: Color.black.opacity(0), location: 0.42),
                    .init(color: Color.black.opacity(0.22), location: 0.74),
                    .init(color: Color.black.opacity(0.58), location: 1),
                ]),
                center: CGPoint(x: size.width / 2, y: size.height * 0.46),
                startRadius: 0,
                endRadius: vignette
            )
        )
    }
}
