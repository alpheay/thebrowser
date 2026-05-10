import CoreGraphics
import Foundation
import SwiftUI

// Official brand marks rendered from their canonical SVG paths
// (sourced from simple-icons, MIT). Both use a 24x24 viewBox.
private enum SVGPaths {
    static let openAI = """
    M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z
    """

    static let claude = """
    m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z
    """
}

// MARK: - Shapes

private struct BrandMarkShape: Shape {
    let pathData: String
    let viewBox: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        let cgPath = SVGPath.cgPath(from: pathData)
        let scale = min(rect.width, rect.height) / viewBox
        let drawnSize = viewBox * scale
        let dx = rect.minX + (rect.width - drawnSize) / 2
        let dy = rect.minY + (rect.height - drawnSize) / 2
        var transform = CGAffineTransform(translationX: dx, y: dy)
            .scaledBy(x: scale, y: scale)
        if let scaled = cgPath.copy(using: &transform) {
            return Path(scaled)
        }
        return Path(cgPath)
    }
}

struct OpenAIMark: View {
    var body: some View {
        BrandMarkShape(pathData: SVGPaths.openAI)
            .fill(.foreground)
    }
}

struct ClaudeMark: View {
    var body: some View {
        BrandMarkShape(pathData: SVGPaths.claude)
            .fill(.foreground)
    }
}

// MARK: - Provider mark dispatcher

struct ProviderMark: View {
    let provider: AIProviderKind
    var size: CGFloat

    var body: some View {
        Group {
            switch provider {
            case .codex:
                OpenAIMark()
            case .claude:
                ClaudeMark()
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(provider.displayName)
    }
}

// MARK: - SVG path parser

enum SVGPath {
    static func cgPath(from svg: String) -> CGPath {
        let path = CGMutablePath()
        var idx = svg.startIndex
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicCtrl: CGPoint? = nil
        var lastQuadCtrl: CGPoint? = nil
        var lastCommand: Character = "M"

        func skipSeparators() {
            while idx < svg.endIndex {
                let c = svg[idx]
                if c.isWhitespace || c == "," { idx = svg.index(after: idx) }
                else { break }
            }
        }

        func parseNum() -> CGFloat? {
            skipSeparators()
            guard idx < svg.endIndex else { return nil }
            let begin = idx
            if svg[idx] == "+" || svg[idx] == "-" {
                idx = svg.index(after: idx)
            }
            var sawDigit = false
            while idx < svg.endIndex && svg[idx].isASCII && svg[idx].isNumber {
                idx = svg.index(after: idx)
                sawDigit = true
            }
            if idx < svg.endIndex && svg[idx] == "." {
                idx = svg.index(after: idx)
                while idx < svg.endIndex && svg[idx].isASCII && svg[idx].isNumber {
                    idx = svg.index(after: idx)
                    sawDigit = true
                }
            }
            if idx < svg.endIndex && (svg[idx] == "e" || svg[idx] == "E") {
                idx = svg.index(after: idx)
                if idx < svg.endIndex && (svg[idx] == "+" || svg[idx] == "-") {
                    idx = svg.index(after: idx)
                }
                while idx < svg.endIndex && svg[idx].isASCII && svg[idx].isNumber {
                    idx = svg.index(after: idx)
                }
            }
            guard sawDigit else {
                idx = begin
                return nil
            }
            return CGFloat(Double(svg[begin..<idx]) ?? 0)
        }

        func parseFlag() -> CGFloat? {
            skipSeparators()
            guard idx < svg.endIndex else { return nil }
            let c = svg[idx]
            if c == "0" || c == "1" {
                idx = svg.index(after: idx)
                return c == "1" ? 1 : 0
            }
            return nil
        }

        while idx < svg.endIndex {
            skipSeparators()
            guard idx < svg.endIndex else { break }

            let ch = svg[idx]
            let cmd: Character

            if ch.isLetter {
                cmd = ch
                idx = svg.index(after: idx)
                lastCommand = ch
            } else {
                // Implicit repeat: after M/m an implicit L/l, otherwise repeat last
                switch lastCommand {
                case "M": cmd = "L"
                case "m": cmd = "l"
                default: cmd = lastCommand
                }
            }

            switch cmd {
            case "M":
                guard let x = parseNum(), let y = parseNum() else { return path }
                current = CGPoint(x: x, y: y)
                subpathStart = current
                path.move(to: current)
                lastCubicCtrl = nil
                lastQuadCtrl = nil
            case "m":
                guard let dx = parseNum(), let dy = parseNum() else { return path }
                current = CGPoint(x: current.x + dx, y: current.y + dy)
                subpathStart = current
                path.move(to: current)
                lastCubicCtrl = nil
                lastQuadCtrl = nil
            case "L":
                guard let x = parseNum(), let y = parseNum() else { return path }
                current = CGPoint(x: x, y: y)
                path.addLine(to: current)
                lastCubicCtrl = nil
                lastQuadCtrl = nil
            case "l":
                guard let dx = parseNum(), let dy = parseNum() else { return path }
                current = CGPoint(x: current.x + dx, y: current.y + dy)
                path.addLine(to: current)
                lastCubicCtrl = nil
                lastQuadCtrl = nil
            case "H":
                guard let x = parseNum() else { return path }
                current = CGPoint(x: x, y: current.y)
                path.addLine(to: current)
                lastCubicCtrl = nil
                lastQuadCtrl = nil
            case "h":
                guard let dx = parseNum() else { return path }
                current = CGPoint(x: current.x + dx, y: current.y)
                path.addLine(to: current)
                lastCubicCtrl = nil
                lastQuadCtrl = nil
            case "V":
                guard let y = parseNum() else { return path }
                current = CGPoint(x: current.x, y: y)
                path.addLine(to: current)
                lastCubicCtrl = nil
                lastQuadCtrl = nil
            case "v":
                guard let dy = parseNum() else { return path }
                current = CGPoint(x: current.x, y: current.y + dy)
                path.addLine(to: current)
                lastCubicCtrl = nil
                lastQuadCtrl = nil
            case "C":
                guard let x1 = parseNum(), let y1 = parseNum(),
                      let x2 = parseNum(), let y2 = parseNum(),
                      let x = parseNum(), let y = parseNum() else { return path }
                let c1 = CGPoint(x: x1, y: y1)
                let c2 = CGPoint(x: x2, y: y2)
                current = CGPoint(x: x, y: y)
                path.addCurve(to: current, control1: c1, control2: c2)
                lastCubicCtrl = c2
                lastQuadCtrl = nil
            case "c":
                guard let x1 = parseNum(), let y1 = parseNum(),
                      let x2 = parseNum(), let y2 = parseNum(),
                      let x = parseNum(), let y = parseNum() else { return path }
                let c1 = CGPoint(x: current.x + x1, y: current.y + y1)
                let c2 = CGPoint(x: current.x + x2, y: current.y + y2)
                let p = CGPoint(x: current.x + x, y: current.y + y)
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
                lastCubicCtrl = c2
                lastQuadCtrl = nil
            case "S":
                guard let x2 = parseNum(), let y2 = parseNum(),
                      let x = parseNum(), let y = parseNum() else { return path }
                let c1: CGPoint
                if let last = lastCubicCtrl {
                    c1 = CGPoint(x: 2 * current.x - last.x, y: 2 * current.y - last.y)
                } else { c1 = current }
                let c2 = CGPoint(x: x2, y: y2)
                let p = CGPoint(x: x, y: y)
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
                lastCubicCtrl = c2
                lastQuadCtrl = nil
            case "s":
                guard let x2 = parseNum(), let y2 = parseNum(),
                      let x = parseNum(), let y = parseNum() else { return path }
                let c1: CGPoint
                if let last = lastCubicCtrl {
                    c1 = CGPoint(x: 2 * current.x - last.x, y: 2 * current.y - last.y)
                } else { c1 = current }
                let c2 = CGPoint(x: current.x + x2, y: current.y + y2)
                let p = CGPoint(x: current.x + x, y: current.y + y)
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
                lastCubicCtrl = c2
                lastQuadCtrl = nil
            case "Q":
                guard let x1 = parseNum(), let y1 = parseNum(),
                      let x = parseNum(), let y = parseNum() else { return path }
                let c = CGPoint(x: x1, y: y1)
                current = CGPoint(x: x, y: y)
                path.addQuadCurve(to: current, control: c)
                lastQuadCtrl = c
                lastCubicCtrl = nil
            case "q":
                guard let x1 = parseNum(), let y1 = parseNum(),
                      let x = parseNum(), let y = parseNum() else { return path }
                let c = CGPoint(x: current.x + x1, y: current.y + y1)
                current = CGPoint(x: current.x + x, y: current.y + y)
                path.addQuadCurve(to: current, control: c)
                lastQuadCtrl = c
                lastCubicCtrl = nil
            case "T":
                guard let x = parseNum(), let y = parseNum() else { return path }
                let c: CGPoint
                if let last = lastQuadCtrl {
                    c = CGPoint(x: 2 * current.x - last.x, y: 2 * current.y - last.y)
                } else { c = current }
                current = CGPoint(x: x, y: y)
                path.addQuadCurve(to: current, control: c)
                lastQuadCtrl = c
                lastCubicCtrl = nil
            case "t":
                guard let x = parseNum(), let y = parseNum() else { return path }
                let c: CGPoint
                if let last = lastQuadCtrl {
                    c = CGPoint(x: 2 * current.x - last.x, y: 2 * current.y - last.y)
                } else { c = current }
                current = CGPoint(x: current.x + x, y: current.y + y)
                path.addQuadCurve(to: current, control: c)
                lastQuadCtrl = c
                lastCubicCtrl = nil
            case "A", "a":
                guard let rx = parseNum(), let ry = parseNum(),
                      let xRot = parseNum(),
                      let largeArc = parseFlag(), let sweep = parseFlag(),
                      let xRaw = parseNum(), let yRaw = parseNum() else { return path }
                let endPoint: CGPoint
                if cmd == "a" {
                    endPoint = CGPoint(x: current.x + xRaw, y: current.y + yRaw)
                } else {
                    endPoint = CGPoint(x: xRaw, y: yRaw)
                }
                addArc(
                    to: path, from: current, to: endPoint,
                    rx: rx, ry: ry, xAxisRotation: xRot,
                    largeArc: largeArc != 0, sweep: sweep != 0
                )
                current = endPoint
                lastCubicCtrl = nil
                lastQuadCtrl = nil
            case "Z", "z":
                path.closeSubpath()
                current = subpathStart
                lastCubicCtrl = nil
                lastQuadCtrl = nil
            default:
                // Unknown command — bail rather than infinite loop
                return path
            }
        }
        return path
    }

    // SVG endpoint-arc to a sequence of cubic bezier segments.
    // Reference: https://www.w3.org/TR/SVG/implnote.html#ArcImplementationNotes
    private static func addArc(
        to path: CGMutablePath,
        from p1: CGPoint, to p2: CGPoint,
        rx rxIn: CGFloat, ry ryIn: CGFloat,
        xAxisRotation: CGFloat,
        largeArc: Bool, sweep: Bool
    ) {
        if p1 == p2 { return }
        var rx = abs(rxIn)
        var ry = abs(ryIn)
        if rx == 0 || ry == 0 {
            path.addLine(to: p2)
            return
        }

        let phi = xAxisRotation * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)

        let dx = (p1.x - p2.x) / 2
        let dy = (p1.y - p2.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let s = sqrt(lambda)
            rx *= s
            ry *= s
        }

        let sign: CGFloat = (largeArc == sweep) ? -1 : 1
        let num = max(0, rx*rx*ry*ry - rx*rx*y1p*y1p - ry*ry*x1p*x1p)
        let den = rx*rx*y1p*y1p + ry*ry*x1p*x1p
        let coef = den == 0 ? 0 : sign * sqrt(num / den)
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * -(ry * x1p / rx)

        let cx = cosPhi * cxp - sinPhi * cyp + (p1.x + p2.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p1.y + p2.y) / 2

        func angleBetween(_ u: CGPoint, _ v: CGPoint) -> CGFloat {
            let lenU = sqrt(u.x * u.x + u.y * u.y)
            let lenV = sqrt(v.x * v.x + v.y * v.y)
            guard lenU > 0, lenV > 0 else { return 0 }
            var c = (u.x * v.x + u.y * v.y) / (lenU * lenV)
            c = max(-1, min(1, c))
            let s: CGFloat = (u.x * v.y - u.y * v.x) >= 0 ? 1 : -1
            return s * acos(c)
        }

        let v1 = CGPoint(x: (x1p - cxp) / rx, y: (y1p - cyp) / ry)
        let v2 = CGPoint(x: (-x1p - cxp) / rx, y: (-y1p - cyp) / ry)
        let theta1 = angleBetween(CGPoint(x: 1, y: 0), v1)
        var deltaTheta = angleBetween(v1, v2)
        if !sweep && deltaTheta > 0 { deltaTheta -= 2 * .pi }
        else if sweep && deltaTheta < 0 { deltaTheta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(deltaTheta) / (.pi / 2))))
        let delta = deltaTheta / CGFloat(segments)
        let t = (8.0 / 3.0) * sin(delta / 4) * sin(delta / 4) / sin(delta / 2)

        for i in 0..<segments {
            let theta = theta1 + CGFloat(i) * delta
            let nextTheta = theta + delta
            let cosT = cos(theta), sinT = sin(theta)
            let cosN = cos(nextTheta), sinN = sin(nextTheta)

            let c1ux = cosT - t * sinT
            let c1uy = sinT + t * cosT
            let c2ux = cosN + t * sinN
            let c2uy = sinN - t * cosN

            let c1x = cosPhi * (rx * c1ux) - sinPhi * (ry * c1uy) + cx
            let c1y = sinPhi * (rx * c1ux) + cosPhi * (ry * c1uy) + cy
            let c2x = cosPhi * (rx * c2ux) - sinPhi * (ry * c2uy) + cx
            let c2y = sinPhi * (rx * c2ux) + cosPhi * (ry * c2uy) + cy
            let endX = cosPhi * (rx * cosN) - sinPhi * (ry * sinN) + cx
            let endY = sinPhi * (rx * cosN) + cosPhi * (ry * sinN) + cy

            path.addCurve(
                to: CGPoint(x: endX, y: endY),
                control1: CGPoint(x: c1x, y: c1y),
                control2: CGPoint(x: c2x, y: c2y)
            )
        }
    }
}
