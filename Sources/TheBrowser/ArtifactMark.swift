import SwiftUI

struct ArtifactMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2.25, style: .continuous)
                .stroke(lineWidth: 1.25)
                .frame(width: 11, height: 13)

            SparkShape()
                .fill()
                .frame(width: 6, height: 6)
        }
    }
}

private struct SparkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        let cy = rect.midY
        let r = min(rect.width, rect.height) / 2
        let inner = r * 0.32

        var path = Path()
        path.move(to: CGPoint(x: cx, y: cy - r))
        path.addQuadCurve(to: CGPoint(x: cx + r, y: cy),
                          control: CGPoint(x: cx + inner, y: cy - inner))
        path.addQuadCurve(to: CGPoint(x: cx, y: cy + r),
                          control: CGPoint(x: cx + inner, y: cy + inner))
        path.addQuadCurve(to: CGPoint(x: cx - r, y: cy),
                          control: CGPoint(x: cx - inner, y: cy + inner))
        path.addQuadCurve(to: CGPoint(x: cx, y: cy - r),
                          control: CGPoint(x: cx - inner, y: cy - inner))
        path.closeSubpath()
        return path
    }
}
