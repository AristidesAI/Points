import SwiftUI

// The video-processing progress indicator. NOT a flat left-to-right bar: it traces the screen
// EDGE as a rounded-rect loop that starts at TOP-CENTRE and fills CLOCKWISE all the way back
// round to top-centre. Used full-screen on the import/bake screen.

/// A rounded-rect edge path that BEGINS at top-centre and is wound clockwise, so `.trim(from:0,
/// to:progress)` fills clockwise from the top-centre seam.
struct EdgeLoopShape: Shape {
    var cornerRadius: CGFloat = 56
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        let midX = rect.midX
        p.move(to: CGPoint(x: midX, y: rect.minY))                      // seam: top centre
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))          // → along the top edge
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
                 startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)   // top-right corner
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))          // ↓ right edge
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)    // bottom-right corner
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))          // ← along the bottom edge
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)  // bottom-left corner
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))          // ↑ left edge
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false) // top-left corner
        p.addLine(to: CGPoint(x: midX, y: rect.minY))                   // → back to the seam
        return p
    }
}

/// Full-screen overlay: a faint edge track with the clockwise progress trace on top, plus a bright
/// head glow at the leading edge. Non-interactive; sits above the bake screen's content.
struct ScreenEdgeProgress: View {
    var progress: Double            // 0…1
    var lineWidth: CGFloat = 5
    var inset: CGFloat = 3
    private var clamped: Double { max(0, min(1, progress)) }

    var body: some View {
        let shape = EdgeLoopShape()
        ZStack {
            shape.stroke(Theme.line.opacity(0.45), lineWidth: 1)                    // full-loop track
            shape.trim(from: 0, to: clamped)
                .stroke(LinearGradient(colors: [Color(hex: 0x4DD0FF), Color(hex: 0x2E7BFF)],
                                       startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .shadow(color: Color(hex: 0x4DD0FF).opacity(0.75), radius: 7)
        }
        .padding(inset)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.linear(duration: 0.25), value: clamped)
    }
}
