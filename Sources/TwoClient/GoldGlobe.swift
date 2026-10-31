// Copyright 2026 MajestaNet
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Shared push-to-talk mark for the phone and the watch.
/// Geometry matches the gold globe: a ring, the network arcs, and the nodes.
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

private enum GoldGlobeDrawing {
    static let gold = Color(red: 246 / 255, green: 207 / 255, blue: 85 / 255)

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

        if wash > 0.01 {
            let glow = CGRect(
                x: center.x - markRadius,
                y: center.y - markRadius,
                width: markRadius * 2,
                height: markRadius * 2
            )
            context.fill(
                Path(ellipseIn: glow),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: gold.opacity(wash), location: 0.15),
                        .init(color: gold.opacity(0), location: 1),
                    ]),
                    center: center,
                    startRadius: markRadius * 0.08,
                    endRadius: markRadius
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
                    color: gold.opacity(fade * motion.ringAlpha),
                    width: max(1, radius * 0.016)
                )
            }
        }

        var arcs = Path()
        for curve in GoldGlobeMark.curves {
            guard let first = curve.first else { continue }
            arcs.move(to: point(first.a, center, markRadius))
            for segment in curve {
                arcs.addCurve(
                    to: point(segment.d, center, markRadius),
                    control1: point(segment.b, center, markRadius),
                    control2: point(segment.c, center, markRadius)
                )
            }
        }
        context.stroke(
            arcs,
            with: .color(gold.opacity(0.9)),
            style: StrokeStyle(lineWidth: radius * 0.02, lineCap: .round, lineJoin: .round)
        )
        strokeCircle(
            &context,
            center: center,
            radius: markRadius,
            color: gold,
            width: radius * 0.044
        )

        if !still {
            for (index, curve) in GoldGlobeMark.curves.enumerated() {
                spark(&context, curve: curve, phase: clock * motion.sparkSpeed + Double(index) * 0.17, center: center, radius: markRadius, core: radius * 0.046)
                if motion.sparkExtra {
                    spark(&context, curve: curve, phase: clock * motion.sparkSpeed + Double(index) * 0.17 + 0.5, center: center, radius: markRadius, core: radius * 0.034)
                }
            }
        }

        for (index, node) in GoldGlobeMark.nodes.enumerated() {
            let pulse = 1 + motion.dotAmp * sin(clock * motion.dotFreq + (motion.flightSync ? 0 : Double(index) * 0.7))
            let cycle = fract(clock * motion.flightSpeed + (motion.flightSync ? 0 : Double(index) * 0.113))
            let outward = flight(cycle)
            let place = node + node.unit * (outward * motion.flightReach)
            let alpha = 1 - outward * 0.4
            let core = radius * 0.066 * pulse * (1 - outward * 0.18)
            disc(&context, at: point(place, center, markRadius), radius: core, alpha: alpha)
        }
    }

    private static func spark(
        _ context: inout GraphicsContext,
        curve: [Cubic],
        phase: Double,
        center: CGPoint,
        radius: CGFloat,
        core: CGFloat
    ) {
        let loop = fract(phase)
        let forward = loop < 0.5
        let travel = smooth(forward ? loop * 2 : (1 - loop) * 2)
        let fade = sin(travel * .pi)
        guard fade > 0.04 else { return }
        let head = point(on: curve, t: travel)
        let trailT = forward ? max(0, travel - 0.07) : min(1, travel + 0.07)
        let trail = point(on: curve, t: trailT)
        disc(&context, at: point(trail, center, radius), radius: core * 0.72, alpha: fade * 0.38)
        disc(&context, at: point(head, center, radius), radius: core, alpha: fade)
    }

    private static func flight(_ cycle: Double) -> Double {
        if cycle < 0.58 { return 0 }
        if cycle < 0.78 { return smooth((cycle - 0.58) / 0.20) }
        return 1 - smooth((cycle - 0.78) / 0.22)
    }

    private static func disc(_ context: inout GraphicsContext, at center: CGPoint, radius: CGFloat, alpha: Double) {
        guard alpha > 0.02, radius > 0.2 else { return }
        fillCircle(&context, center: center, radius: radius * 1.65, color: gold.opacity(0.16 * alpha))
        fillCircle(&context, center: center, radius: radius, color: gold.opacity(min(1, alpha)))
    }

    private static func strokeCircle(
        _ context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        color: Color,
        width: CGFloat
    ) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: width)
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

    private static func point(_ vector: Vec, _ center: CGPoint, _ radius: CGFloat) -> CGPoint {
        CGPoint(x: center.x + CGFloat(vector.x) * radius, y: center.y + CGFloat(vector.y) * radius)
    }

    private static func point(on curve: [Cubic], t: Double) -> Vec {
        let clamped = min(max(t, 0), 0.999999)
        let scaled = clamped * Double(curve.count)
        let index = min(curve.count - 1, Int(scaled))
        return curve[index].point(scaled - Double(index))
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
    var sparkSpeed: Double
    var sparkExtra: Bool
    var flightSpeed: Double
    var flightReach: Double
    var flightSync: Bool
    var dotAmp: Double
    var dotFreq: Double
    var ringPeriod: Double
    var ringAlpha: Double
    var wash: Double
    var throb: Double
    var breathe: Double

    static let still = Motion(
        sparkSpeed: 0, sparkExtra: false, flightSpeed: 0, flightReach: 0, flightSync: true,
        dotAmp: 0, dotFreq: 0, ringPeriod: 1, ringAlpha: 0, wash: 0.045, throb: 0, breathe: 0
    )

    static func profile(_ activity: GoldGlobeActivity) -> Motion {
        switch activity {
        case .ready:
            return Motion(
                sparkSpeed: 0.28, sparkExtra: false, flightSpeed: 0.2, flightReach: 0.36, flightSync: false,
                dotAmp: 0.14, dotFreq: 2.2, ringPeriod: 2.7, ringAlpha: 0.3, wash: 0.08, throb: 0.014, breathe: 1.6
            )
        case .listening:
            return Motion(
                sparkSpeed: 0.82, sparkExtra: true, flightSpeed: 0.6, flightReach: 0.46, flightSync: false,
                dotAmp: 0.22, dotFreq: 5.6, ringPeriod: 0.9, ringAlpha: 0.66, wash: 0.22, throb: 0.032, breathe: 4.4
            )
        case .sending:
            return Motion(
                sparkSpeed: 0.42, sparkExtra: false, flightSpeed: 0.9, flightReach: 0.18, flightSync: true,
                dotAmp: 0.18, dotFreq: 3.5, ringPeriod: 1.3, ringAlpha: 0.48, wash: 0.15, throb: 0.022, breathe: 2.8
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

    static func * (lhs: Vec, rhs: Double) -> Vec {
        Vec(x: lhs.x * rhs, y: lhs.y * rhs)
    }

    var unit: Vec {
        let length = hypot(x, y)
        guard length > 0.0001 else { return Vec(x: 0, y: -1) }
        return self * (1 / length)
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
}

private enum GoldGlobeMark {
    static func v(_ x: Double, _ y: Double) -> Vec { Vec(x: x, y: y) }

    /// Node positions in ring-radius units. The ring is the unit circle.
    static let nodes: [Vec] = [
        v(-0.2276, -0.6483),
        v(0.2965, -0.7241),
        v(0.6138, -0.4758),
        v(-0.1103, -0.0689),
        v(-0.5793, -0.2483),
        v(-0.5241, 0.1586),
        v(-0.3379, 0.7724),
        v(0.1793, 0.7793),
        v(0.6483, 0.2138),
    ]

    static let curves: [[Cubic]] = [
        [
            Cubic(a: v(-0.5655, -0.8247), b: v(-0.9655, -0.8552), c: v(-1.1310, -0.5241), d: v(-1.0828, -0.1241)),
            Cubic(a: v(-1.0828, -0.1241), b: v(-1.0345, 0.3724), c: v(-0.7034, 0.7586), d: v(-0.3379, 0.7724)),
        ],
        [
            Cubic(a: v(0.2966, -0.7241), b: v(0.4207, -1.0414), c: v(0.6621, -1.1379), d: v(0.7863, -0.9103)),
            Cubic(a: v(0.7863, -0.9103), b: v(0.8483, -0.7793), c: v(0.8690, -0.6483), d: v(0.8138, -0.5811)),
        ],
        [
            Cubic(a: v(0.1793, 0.7173), b: v(0.4345, 0.9586), c: v(0.6414, 1.0414), d: v(0.7793, 0.9449)),
            Cubic(a: v(0.7793, 0.9449), b: v(0.9104, 0.8552), c: v(0.9242, 0.6759), d: v(0.8138, 0.5812)),
        ],
        [
            Cubic(a: v(-0.2276, -0.6483), b: v(0.1724, -0.6621), c: v(0.5724, -0.3862), d: v(0.6483, 0.2138)),
        ],
        [
            Cubic(a: v(-0.1103, -0.0689), b: v(0.1931, -0.0483), c: v(0.4345, -0.2207), d: v(0.6138, -0.4758)),
        ],
        [
            Cubic(a: v(-0.5241, 0.1586), b: v(-0.5586, 0.4621), c: v(-0.4414, 0.6276), d: v(-0.3379, 0.7724)),
        ],
        [
            Cubic(a: v(-0.5793, -0.2483), b: v(-0.3104, -0.3103), c: v(-0.2414, 0.4966), d: v(0.1793, 0.7173)),
        ],
    ]
}
