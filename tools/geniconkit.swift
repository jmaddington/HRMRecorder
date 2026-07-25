// Generates the HRM Recorder app icon: red gradient, white heart,
// full-width ECG trace (red over the heart, white over the background).
// Usage: geniconkit <out.png> [size]
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let S = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 1024
let f = CGFloat(S) / 1024.0

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// design in y-down coordinates
ctx.translateBy(x: 0, y: CGFloat(S))
ctx.scaleBy(x: f, y: -f)

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// --- background gradient (lighter top, deep crimson bottom)
let grad = CGGradient(colorsSpace: cs,
                      colors: [rgb(0xFF5A66), rgb(0xE8203A), rgb(0x9E0F24)] as CFArray,
                      locations: [0, 0.55, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 200, y: 0),
                       end: CGPoint(x: 824, y: 1024),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// --- heart path (classic two-lobe bezier, 100-unit space scaled/centered)
let s: CGFloat = 12.7, tx: CGFloat = 512 - 50 * s, ty: CGFloat = 512 - 41 * s
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s + tx, y: y * s + ty) }
let heart = CGMutablePath()
heart.move(to: P(50, 62))
heart.addCurve(to: P(24, 33), control1: P(37, 52), control2: P(24, 44))
heart.addCurve(to: P(37.5, 20), control1: P(24, 30.5), control2: P(27, 20))
heart.addCurve(to: P(50, 30), control1: P(46, 20), control2: P(50, 27))
heart.addCurve(to: P(62.5, 20), control1: P(50, 27), control2: P(54, 20))
heart.addCurve(to: P(76, 33), control1: P(73, 20), control2: P(76, 30.5))
heart.addCurve(to: P(50, 62), control1: P(76, 44), control2: P(63, 52))
heart.closeSubpath()

// soft shadow under the heart for depth
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40,
              color: CGColor(srgbRed: 0.35, green: 0, blue: 0.05, alpha: 0.35))
ctx.addPath(heart)
ctx.setFillColor(rgb(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()

// --- ECG trace, full canvas width
let yb: CGFloat = 530
let ecg = CGMutablePath()
ecg.move(to: CGPoint(x: -40, y: yb))
ecg.addLine(to: CGPoint(x: 265, y: yb))          // lead-in
ecg.addLine(to: CGPoint(x: 300, y: 497))         // P bump up
ecg.addLine(to: CGPoint(x: 335, y: yb))
ecg.addLine(to: CGPoint(x: 388, y: yb))
ecg.addLine(to: CGPoint(x: 412, y: 566))         // Q dip
ecg.addLine(to: CGPoint(x: 465, y: 318))         // R spike
ecg.addLine(to: CGPoint(x: 512, y: 660))         // S drop
ecg.addLine(to: CGPoint(x: 548, y: yb))
ecg.addLine(to: CGPoint(x: 620, y: yb))
ecg.addLine(to: CGPoint(x: 662, y: 488))         // T bump
ecg.addLine(to: CGPoint(x: 704, y: yb))
ecg.addLine(to: CGPoint(x: 1064, y: yb))         // lead-out

func strokeECG(_ color: CGColor) {
    ctx.addPath(ecg)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(30)
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    ctx.strokePath()
}

// red segment where the trace crosses the heart
ctx.saveGState()
ctx.addPath(heart)
ctx.clip()
strokeECG(rgb(0xD8172F))
ctx.restoreGState()

// white segments outside the heart
ctx.saveGState()
ctx.addRect(CGRect(x: 0, y: 0, width: 1024, height: 1024))
ctx.addPath(heart)
ctx.clip(using: .evenOdd)
strokeECG(rgb(0xFFFFFF))
ctx.restoreGState()

let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL,
                                           UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out) \(S)x\(S)")
