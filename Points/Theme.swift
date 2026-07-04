import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// 02 SIGNAL — near-black flat theme (chosen from Plans/mockup/palettes.html).
enum Theme {
    static let bg = Color(hex: 0x0E0E0E)
    static let panel = Color(hex: 0x181818)
    static let line = Color(hex: 0x2E2E2E)
    static let text = Color(hex: 0xF2F2F2)
    static let text2 = Color(hex: 0x8A8A8A)
    static let accent = Color(hex: 0xFFFFFF)
    static let pin = Color(hex: 0xDDDDDD)
    static let danger = Color(hex: 0xFF453A)

    // Node family colors
    static let famSource = Color(hex: 0xE06C60)
    static let famGrid = Color(hex: 0xE0995F)
    static let famFilter = Color(hex: 0xE0453A)   // cleanup / depth-filter nodes — red
    static let famShape = Color(hex: 0xC3D05E)
    static let famMove = Color(hex: 0x6FCE7D)
    static let famColor = Color(hex: 0xD86FC0)
    static let famSignal = Color(hex: 0xCFCFCF)
    static let famBody = Color(hex: 0x5FD0CD)
    static let famTime = Color(hex: 0x9D86E8)
    static let famStage = Color(hex: 0x6F9FDD)
    static let famTools = Color(hex: 0x909090)
}
