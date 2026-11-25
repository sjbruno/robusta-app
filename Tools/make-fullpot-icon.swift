// Desenha o ícone do Bule cheio (o SF Symbols não tem bule) em vetor, no traço dos SF Symbols.
// Uso, na raiz do repositório: swift Tools/make-fullpot-icon.swift
// Saída: App/Assets.xcassets/FullPotIcon.imageset (PDF em modo template) e uma prévia em PNG
// no caminho passado como argumento, se houver.

import AppKit
import CoreGraphics

/// Bule em contorno, num quadro de 20 × 20 pt (y para baixo).
func potPath() -> CGPath {
    let path = CGMutablePath()
    // Corpo: mais largo embaixo, base arredondada.
    path.move(to: CGPoint(x: 6.2, y: 8.2))
    path.addLine(to: CGPoint(x: 13.8, y: 8.2))
    path.addCurve(to: CGPoint(x: 15.2, y: 15.6), control1: CGPoint(x: 15.0, y: 10.0), control2: CGPoint(x: 15.6, y: 13.2))
    path.addQuadCurve(to: CGPoint(x: 13.4, y: 17.2), control: CGPoint(x: 15.0, y: 17.2))
    path.addLine(to: CGPoint(x: 6.6, y: 17.2))
    path.addQuadCurve(to: CGPoint(x: 4.8, y: 15.6), control: CGPoint(x: 5.0, y: 17.2))
    path.addCurve(to: CGPoint(x: 6.2, y: 8.2), control1: CGPoint(x: 4.4, y: 13.2), control2: CGPoint(x: 5.0, y: 10.0))
    path.closeSubpath()
    // Tampa em cúpula.
    path.move(to: CGPoint(x: 6.6, y: 8.2))
    path.addQuadCurve(to: CGPoint(x: 13.4, y: 8.2), control: CGPoint(x: 10.0, y: 4.6))
    // Pegador da tampa.
    path.addEllipse(in: CGRect(x: 9.1, y: 3.6, width: 1.8, height: 1.8))
    // Bico, à esquerda.
    path.move(to: CGPoint(x: 5.3, y: 11.6))
    path.addCurve(to: CGPoint(x: 1.6, y: 8.0), control1: CGPoint(x: 3.4, y: 11.2), control2: CGPoint(x: 2.2, y: 9.8))
    // Alça, à direita.
    path.move(to: CGPoint(x: 14.5, y: 10.0))
    path.addCurve(to: CGPoint(x: 14.9, y: 15.0), control1: CGPoint(x: 18.6, y: 9.6), control2: CGPoint(x: 18.8, y: 14.6))
    return path
}

let lineWidth: CGFloat = 1.55 // peso "regular" dos SF Symbols a ~16 pt

func draw(_ ctx: CGContext, scale: CGFloat, flip: Bool, height: CGFloat) {
    ctx.saveGState()
    if flip {
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)
    }
    ctx.scaleBy(x: scale, y: scale)
    ctx.addPath(potPath())
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
    ctx.strokePath()
    ctx.restoreGState()
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let dir = root.appending(path: "App/Assets.xcassets/FullPotIcon.imageset")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

var box = CGRect(x: 0, y: 0, width: 20, height: 20)
let pdfURL = dir.appending(path: "bule.pdf")
let pdf = CGContext(pdfURL as CFURL, mediaBox: &box, nil)!
pdf.beginPDFPage(nil)
draw(pdf, scale: 1, flip: true, height: 20)
pdf.endPDFPage()
pdf.closePDF()

let contents: [String: Any] = [
    "images": [["idiom": "universal", "filename": "bule.pdf"]],
    "info": ["author": "xcode", "version": 1],
    "properties": ["template-rendering-intent": "template", "preserves-vector-representation": true],
]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: dir.appending(path: "Contents.json"))

// Prévia ampliada (10×) para conferir o desenho.
if CommandLine.arguments.count > 1 {
    let size = 200
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    draw(ctx, scale: 10, flip: true, height: CGFloat(size))
    try NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
print("Ícone do bule gerado em App/Assets.xcassets/FullPotIcon.imageset.")
