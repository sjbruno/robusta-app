// Gera o ícone do Robusta (grão de café) em vetor.
// Uso, na raiz do repositório: swift Tools/make-icon.swift
//
// Saídas:
// - App/Assets.xcassets/AppIcon.appiconset: ícone do app em PNG, nos tamanhos do macOS.
// - App/Assets.xcassets/MenuBarIcon.imageset: PDF vetorial em modo template (barra de menus).
// - docs/icone/grao.svg: o desenho do grão em SVG, para reuso.
//
// O grão é uma elipse menos um sulco em S (CGPath.subtracting, macOS 13+).

import AppKit
import CoreGraphics

// MARK: Geometria

/// Grão em coordenadas unitárias (0…1, y para baixo), dentro de `rect`.
/// `groove` é a largura do sulco em fração da largura de `rect`.
func beanPath(in rect: CGRect, groove: CGFloat) -> CGPath {
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
    }
    // Proporção da referência: largura ≈ 85% da altura.
    let body = CGPath(ellipseIn: CGRect(
        x: rect.minX + 0.16 * rect.width, y: rect.minY + 0.10 * rect.height,
        width: 0.68 * rect.width, height: 0.80 * rect.height), transform: nil)

    // Sulco: entra um pouco à esquerda do centro no topo, curva para a esquerda,
    // cruza o meio e sai à direita embaixo. Passa das bordas para separar as metades.
    let s = CGMutablePath()
    s.move(to: p(0.49, 0.02))
    s.addCurve(to: p(0.555, 0.98), control1: p(0.35, 0.40), control2: p(0.68, 0.58))
    let grooveShape = s.copy(strokingWithWidth: groove * rect.width, lineCap: .butt, lineJoin: .round, miterLimit: 10)
    return body.subtracting(grooveShape)
}

// MARK: Cores do ícone do app

// Fundo marrom café com leve degradê; grão creme (decidido em 25/11/2026).
let background1 = CGColor(srgbRed: 0.40, green: 0.25, blue: 0.16, alpha: 1)   // topo
let background2 = CGColor(srgbRed: 0.25, green: 0.15, blue: 0.09, alpha: 1)   // base
let bean1 = CGColor(srgbRed: 0.98, green: 0.94, blue: 0.87, alpha: 1)
let bean2 = CGColor(srgbRed: 0.90, green: 0.81, blue: 0.67, alpha: 1)

/// Desenha o ícone do app num contexto de `size` × `size` (y para cima).
func drawAppIcon(_ ctx: CGContext, size: CGFloat) {
    // Grade de ícones do macOS: corpo de 824/1024 com cantos de ~185/1024.
    let inset = size * 100 / 1024
    let bodyRect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = size * 185 / 1024
    let squircle = CGPath(roundedRect: bodyRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Sombra suave do corpo.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.01), blur: size * 0.025,
                  color: CGColor(gray: 0, alpha: 0.25))
    ctx.addPath(squircle)
    ctx.setFillColor(background2)
    ctx.fillPath()
    ctx.restoreGState()

    // Fundo creme em degradê vertical.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [background1, background2] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: bodyRect.maxY), end: CGPoint(x: 0, y: bodyRect.minY), options: [])
    ctx.restoreGState()

    // Grão levemente inclinado, com degradê e sombra.
    let beanRect = bodyRect.insetBy(dx: bodyRect.width * 0.17, dy: bodyRect.height * 0.12)
    var flip = CGAffineTransform(translationX: 0, y: size).scaledBy(x: 1, y: -1)
    let upright = beanPath(in: beanRect, groove: 0.055).copy(using: &flip)!
    var tilt = CGAffineTransform(translationX: size / 2, y: size / 2)
        .rotated(by: -.pi / 9)
        .translatedBy(x: -size / 2, y: -size / 2)
    let bean = upright.copy(using: &tilt)!

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03,
                  color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(bean)
    ctx.setFillColor(bean2)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bean)
    ctx.clip()
    let fill = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [bean1, bean2] as CFArray, locations: [0, 1])!
    let box = bean.boundingBox
    ctx.drawLinearGradient(fill, start: CGPoint(x: box.minX, y: box.maxY), end: CGPoint(x: box.maxX, y: box.minY), options: [])
    ctx.restoreGState()
}

// MARK: Saídas

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appending(path: "App/Assets.xcassets")
let appIconDir = assets.appending(path: "AppIcon.appiconset")
let menuIconDir = assets.appending(path: "MenuBarIcon.imageset")
let docsDir = root.appending(path: "docs/icone")
for dir in [appIconDir, menuIconDir, docsDir] {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
}

func writeJSON(_ object: Any, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
}

try writeJSON(["info": ["author": "xcode", "version": 1]], to: assets.appending(path: "Contents.json"))

// Ícone do app: 16 a 512 pt, @1x e @2x.
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        drawAppIcon(ctx, size: CGFloat(pixels))
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try rep.representation(using: .png, properties: [:])!.write(to: appIconDir.appending(path: name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
try writeJSON(["images": images, "info": ["author": "xcode", "version": 1]], to: appIconDir.appending(path: "Contents.json"))

// Barra de menus: 18 × 18 pt, preto sobre transparente, sulco mais largo para aparecer pequeno.
let menuSize: CGFloat = 18
var mediaBox = CGRect(x: 0, y: 0, width: menuSize, height: menuSize)
let pdfURL = menuIconDir.appending(path: "grao.pdf")
let pdf = CGContext(pdfURL as CFURL, mediaBox: &mediaBox, nil)!
pdf.beginPDFPage(nil)
var flipMenu = CGAffineTransform(translationX: 0, y: menuSize).scaledBy(x: 1, y: -1)
// Mesma inclinação do ícone do app (20° no sentido horário). Inclinado, o grão ocupa mais
// espaço: depois de girar, ele é reduzido para caber no quadro com 0,5 pt de margem.
var menuTilt = CGAffineTransform(translationX: menuSize / 2, y: menuSize / 2)
    .rotated(by: -.pi / 9)
    .translatedBy(x: -menuSize / 2, y: -menuSize / 2)
// Quadro com a proporção do grão do ícone do app (corpo menos 17% dos lados e 12% em cima e embaixo).
let tiltedMenuBean = beanPath(in: CGRect(x: 0, y: 0, width: 20 * 0.66 / 0.76, height: 20), groove: 0.08)
    .copy(using: &flipMenu)!.copy(using: &menuTilt)!
let menuBounds = tiltedMenuBean.boundingBoxOfPath
let menuFit = (menuSize - 1) / max(menuBounds.width, menuBounds.height)
var menuPlace = CGAffineTransform(translationX: menuSize / 2, y: menuSize / 2)
    .scaledBy(x: menuFit, y: menuFit)
    .translatedBy(x: -menuBounds.midX, y: -menuBounds.midY)
pdf.addPath(tiltedMenuBean.copy(using: &menuPlace)!)
pdf.setFillColor(CGColor(gray: 0, alpha: 1))
pdf.fillPath()
pdf.endPDFPage()
pdf.closePDF()
try writeJSON([
    "images": [["idiom": "universal", "filename": "grao.pdf"]],
    "info": ["author": "xcode", "version": 1],
    "properties": ["template-rendering-intent": "template", "preserves-vector-representation": true],
], to: menuIconDir.appending(path: "Contents.json"))

// SVG do grão (viewBox 0 0 100 100), para reuso fora do app.
func svgPathData(_ path: CGPath) -> String {
    var d = ""
    func f(_ v: CGFloat) -> String { String(format: "%.2f", v) }
    path.applyWithBlock { element in
        let e = element.pointee
        switch e.type {
        case .moveToPoint: d += "M\(f(e.points[0].x)) \(f(e.points[0].y)) "
        case .addLineToPoint: d += "L\(f(e.points[0].x)) \(f(e.points[0].y)) "
        case .addQuadCurveToPoint:
            d += "Q\(f(e.points[0].x)) \(f(e.points[0].y)) \(f(e.points[1].x)) \(f(e.points[1].y)) "
        case .addCurveToPoint:
            d += "C\(f(e.points[0].x)) \(f(e.points[0].y)) \(f(e.points[1].x)) \(f(e.points[1].y)) \(f(e.points[2].x)) \(f(e.points[2].y)) "
        case .closeSubpath: d += "Z "
        @unknown default: break
        }
    }
    return d.trimmingCharacters(in: .whitespaces)
}
let svgBean = beanPath(in: CGRect(x: 0, y: 0, width: 100, height: 100), groove: 0.06)
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <path fill="#3d2112" fill-rule="nonzero" d="\(svgPathData(svgBean))"/>
</svg>

"""
try svg.write(to: docsDir.appending(path: "grao.svg"), atomically: true, encoding: .utf8)

print("Ícones gerados em App/Assets.xcassets e docs/icone.")

// Camada para o Icon Composer (macOS 26+): o grão inclinado numa tela de 1024 × 1024, sem
// fundo (o fundo e o efeito de vidro são definidos no próprio Icon Composer).
let composerDir = docsDir.appending(path: "icon-composer")
try FileManager.default.createDirectory(at: composerDir, withIntermediateDirectories: true)
let canvas: CGFloat = 1024
let bodyInset = canvas * 100 / 1024
let body = CGRect(x: bodyInset, y: bodyInset, width: canvas - 2 * bodyInset, height: canvas - 2 * bodyInset)
let layerRect = body.insetBy(dx: body.width * 0.17, dy: body.height * 0.12)
// y para baixo no SVG: ângulo positivo gira no sentido horário, como o ícone atual.
var layerTilt = CGAffineTransform(translationX: canvas / 2, y: canvas / 2)
    .rotated(by: .pi / 9)
    .translatedBy(x: -canvas / 2, y: -canvas / 2)
let layerBean = beanPath(in: layerRect, groove: 0.055).copy(using: &layerTilt)!
let layerSVG = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <path fill="#F2E3CB" d="\(svgPathData(layerBean))"/>
</svg>

"""
try layerSVG.write(to: composerDir.appending(path: "grao-1024.svg"), atomically: true, encoding: .utf8)
print("Camada do Icon Composer em docs/icone/icon-composer/grao-1024.svg.")
