import Foundation

// §13 v2 — shared easing curves for the trigger layer (Curve node + Envelope shaping).
// nonisolated so control-rate eval can call apply() from the render/main path with no actor hop.
// (Math validated in Plans/TriggerSystem/Easing.swift; compact subset here.)

nonisolated enum EasingCurve: String, Codable, CaseIterable, Sendable {
    case linear
    case quadIn, quadOut, quadInOut
    case cubicIn, cubicOut, cubicInOut
    case expoOut
    case sineInOut
    case backOut
    case bounceOut
    case elasticOut

    /// Map normalised progress t∈[0,1] → shaped value (back/elastic/bounce overshoot on purpose).
    func apply(_ tIn: Float) -> Float {
        let t = min(max(tIn, 0), 1)
        switch self {
        case .linear: return t
        case .quadIn: return t * t
        case .quadOut: return 1 - (1 - t) * (1 - t)
        case .quadInOut: return t < 0.5 ? 2 * t * t : 1 - powf(-2 * t + 2, 2) / 2
        case .cubicIn: return t * t * t
        case .cubicOut: return 1 - powf(1 - t, 3)
        case .cubicInOut: return t < 0.5 ? 4 * t * t * t : 1 - powf(-2 * t + 2, 3) / 2
        case .expoOut: return t == 1 ? 1 : 1 - powf(2, -10 * t)
        case .sineInOut: return -(cosf(Float.pi * t) - 1) / 2
        case .backOut:
            let c1: Float = 1.70158, c3: Float = 1.70158 + 1
            return 1 + c3 * powf(t - 1, 3) + c1 * powf(t - 1, 2)
        case .bounceOut:
            let n1: Float = 7.5625, d1: Float = 2.75
            var x = t
            if x < 1 / d1 { return n1 * x * x }
            else if x < 2 / d1 { x -= 1.5 / d1; return n1 * x * x + 0.75 }
            else if x < 2.5 / d1 { x -= 2.25 / d1; return n1 * x * x + 0.9375 }
            else { x -= 2.625 / d1; return n1 * x * x + 0.984375 }
        case .elasticOut:
            if t == 0 { return 0 }; if t == 1 { return 1 }
            let c4 = (2 * Float.pi) / 3
            return powf(2, -10 * t) * sinf((t * 10 - 0.75) * c4) + 1
        }
    }
}
