// Рисует иконку приложения: ретро-телевизор, на экране — шоу (сцена, кулисы, прожектор, звезда).
// Использование: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
    )
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Заливка контура вертикальным градиентом (сверху вниз).
func fill(_ ctx: CGContext, _ path: CGPath, top: CGColor, bottom: CGColor) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let box = path.boundingBox
    ctx.drawLinearGradient(gradient([top, bottom]), start: CGPoint(x: box.midX, y: box.maxY),
                           end: CGPoint(x: box.midX, y: box.minY), options: [])
    ctx.restoreGState()
}

func star(center: CGPoint, outer: CGFloat, inner: CGFloat) -> CGPath {
    let path = CGMutablePath()
    for i in 0..<10 {
        let r = i % 2 == 0 ? outer : inner
        let angle = CGFloat.pi / 2 + CGFloat(i) * .pi / 5
        let p = CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

func draw(_ ctx: CGContext) {
    // Плашка в стиле macOS с тенью.
    let plate = roundedRect(CGRect(x: 100, y: 100, width: 824, height: 824), 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.35))
    ctx.addPath(plate)
    ctx.setFillColor(color(0x241C5C))
    ctx.fillPath()
    ctx.restoreGState()
    fill(ctx, plate, top: color(0x5B3FD1), bottom: color(0x15173F))

    // Мягкий свет за телевизором.
    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    ctx.drawRadialGradient(gradient([color(0xFFC86B, 0.28), color(0xFFC86B, 0)]),
                           startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 470), endRadius: 420, options: [])
    ctx.restoreGState()

    // Антенны.
    ctx.setLineCap(.round)
    ctx.setLineWidth(16)
    ctx.setStrokeColor(color(0xF6E9DA))
    for tip in [CGPoint(x: 380, y: 850), CGPoint(x: 650, y: 870)] {
        ctx.move(to: CGPoint(x: 512, y: 700))
        ctx.addLine(to: tip)
        ctx.strokePath()
        ctx.setFillColor(color(0xFFD25E))
        ctx.fillEllipse(in: CGRect(x: tip.x - 22, y: tip.y - 22, width: 44, height: 44))
    }
    ctx.setFillColor(color(0xB23A48))
    ctx.fillEllipse(in: CGRect(x: 462, y: 670, width: 100, height: 70))

    // Ножки.
    ctx.setFillColor(color(0xB8384A))
    for x in [CGFloat(300), 684] {
        let leg = CGMutablePath()
        leg.move(to: CGPoint(x: x, y: 250))
        leg.addLine(to: CGPoint(x: x + 40, y: 250))
        leg.addLine(to: CGPoint(x: x + 30 + (x < 512 ? -30 : 30), y: 188))
        leg.addLine(to: CGPoint(x: x + 10 + (x < 512 ? -30 : 30), y: 188))
        leg.closeSubpath()
        ctx.addPath(leg)
        ctx.fillPath()
    }

    // Корпус.
    let body = roundedRect(CGRect(x: 190, y: 228, width: 644, height: 470), 78)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.4))
    ctx.addPath(body)
    ctx.setFillColor(color(0xE8505B))
    ctx.fillPath()
    ctx.restoreGState()
    fill(ctx, body, top: color(0xFF9466), bottom: color(0xD9404F))
    ctx.addPath(roundedRect(CGRect(x: 196, y: 234, width: 632, height: 458), 72))
    ctx.setStrokeColor(color(0xFFFFFF, 0.25))
    ctx.setLineWidth(4)
    ctx.strokePath()

    // Рамка экрана.
    let bezel = roundedRect(CGRect(x: 222, y: 262, width: 488, height: 404), 58)
    ctx.addPath(bezel)
    ctx.setFillColor(color(0x2B1D33))
    ctx.fillPath()

    // Экран: сцена.
    let screenRect = CGRect(x: 240, y: 280, width: 452, height: 368)
    let screen = roundedRect(screenRect, 46)
    ctx.saveGState()
    ctx.addPath(screen)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0x2A1450), color(0x4A2160)]),
                           start: CGPoint(x: 0, y: screenRect.maxY), end: CGPoint(x: 0, y: screenRect.minY), options: [])

    // Пол сцены.
    ctx.setFillColor(color(0x5E2A4F))
    ctx.fill(CGRect(x: screenRect.minX, y: screenRect.minY, width: screenRect.width, height: 78))

    // Луч прожектора и пятно света.
    let cone = CGMutablePath()
    cone.move(to: CGPoint(x: 440, y: screenRect.maxY))
    cone.addLine(to: CGPoint(x: 492, y: screenRect.maxY))
    cone.addLine(to: CGPoint(x: 590, y: 330))
    cone.addLine(to: CGPoint(x: 342, y: 330))
    cone.closeSubpath()
    ctx.saveGState()
    ctx.addPath(cone)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0xFFF1B8, 0.55), color(0xFFF1B8, 0.12)]),
                           start: CGPoint(x: 0, y: screenRect.maxY), end: CGPoint(x: 0, y: 330), options: [])
    ctx.restoreGState()
    ctx.setFillColor(color(0xFFE9A0, 0.55))
    ctx.fillEllipse(in: CGRect(x: 336, y: 306, width: 260, height: 56))

    // Звезда шоу с сиянием.
    let starPath = star(center: CGPoint(x: 466, y: 468), outer: 82, inner: 34)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 36, color: color(0xFFD25E, 0.9))
    ctx.addPath(starPath)
    ctx.setFillColor(color(0xFFC93C))
    ctx.fillPath()
    ctx.restoreGState()
    fill(ctx, starPath, top: color(0xFFF0A0), bottom: color(0xFFA81F))

    // Искорки.
    ctx.setFillColor(color(0xFFFFFF, 0.85))
    for (x, y, r) in [(560.0, 560.0, 7.0), (372.0, 540.0, 5.0), (590.0, 430.0, 5.0), (350.0, 420.0, 4.0)] {
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    // Кулисы слева и справа с волнистым краем.
    for side in [CGFloat(-1), 1] {
        let edgeX: CGFloat = side < 0 ? screenRect.minX : screenRect.maxX
        let inner: CGFloat = side < 0 ? screenRect.minX + 92 : screenRect.maxX - 92
        let curtain = CGMutablePath()
        curtain.move(to: CGPoint(x: edgeX, y: screenRect.minY))
        curtain.addLine(to: CGPoint(x: edgeX, y: screenRect.maxY))
        curtain.addLine(to: CGPoint(x: inner, y: screenRect.maxY))
        curtain.addCurve(to: CGPoint(x: inner - side * 26, y: 470),
                         control1: CGPoint(x: inner + side * 20, y: 590), control2: CGPoint(x: inner - side * 30, y: 540))
        curtain.addCurve(to: CGPoint(x: inner - side * 46, y: screenRect.minY),
                         control1: CGPoint(x: inner - side * 20, y: 400), control2: CGPoint(x: inner - side * 64, y: 340))
        curtain.closeSubpath()
        fill(ctx, curtain, top: color(0xE8344E), bottom: color(0x8E1430))
        // Складки.
        ctx.setStrokeColor(color(0x6E0F25, 0.55))
        ctx.setLineWidth(5)
        for k in 1...2 {
            let x = edgeX - side * CGFloat(k) * 26
            ctx.move(to: CGPoint(x: x, y: screenRect.maxY))
            ctx.addCurve(to: CGPoint(x: x - side * 8, y: screenRect.minY),
                         control1: CGPoint(x: x + side * 10, y: 520), control2: CGPoint(x: x - side * 14, y: 400))
            ctx.strokePath()
        }
    }

    // Ламбрекен сверху с фестонами.
    let valance = CGMutablePath()
    let top = screenRect.maxY
    valance.move(to: CGPoint(x: screenRect.minX, y: top))
    valance.addLine(to: CGPoint(x: screenRect.maxX, y: top))
    valance.addLine(to: CGPoint(x: screenRect.maxX, y: top - 34))
    let scallops = 6
    let w = screenRect.width / CGFloat(scallops)
    for i in (0..<scallops).reversed() {
        let x0 = screenRect.minX + CGFloat(i + 1) * w
        let x1 = screenRect.minX + CGFloat(i) * w
        valance.addQuadCurve(to: CGPoint(x: x1, y: top - 34), control: CGPoint(x: (x0 + x1) / 2, y: top - 74))
    }
    valance.closeSubpath()
    fill(ctx, valance, top: color(0xF04A5E), bottom: color(0xA3172F))
    ctx.restoreGState()

    // Блик на стекле экрана.
    ctx.saveGState()
    ctx.addPath(screen)
    ctx.clip()
    let glare = CGMutablePath()
    glare.move(to: CGPoint(x: screenRect.minX, y: screenRect.maxY))
    glare.addLine(to: CGPoint(x: screenRect.minX + 200, y: screenRect.maxY))
    glare.addLine(to: CGPoint(x: screenRect.minX, y: screenRect.maxY - 170))
    glare.closeSubpath()
    ctx.addPath(glare)
    ctx.setFillColor(color(0xFFFFFF, 0.10))
    ctx.fillPath()
    ctx.restoreGState()

    // Ручки и динамик справа.
    for (y, r) in [(CGFloat(586), CGFloat(32)), (494, 26)] {
        ctx.setFillColor(color(0x2B1D33))
        ctx.fillEllipse(in: CGRect(x: 772 - r, y: y - r, width: r * 2, height: r * 2))
        ctx.setFillColor(color(0xF6E9DA))
        ctx.fillEllipse(in: CGRect(x: 772 - r + 8, y: y - r + 8, width: (r - 8) * 2, height: (r - 8) * 2))
        ctx.setStrokeColor(color(0x2B1D33))
        ctx.setLineWidth(6)
        ctx.move(to: CGPoint(x: 772, y: y))
        ctx.addLine(to: CGPoint(x: 772 + (r - 10) * 0.7, y: y + (r - 10) * 0.7))
        ctx.strokePath()
    }
    ctx.setStrokeColor(color(0x2B1D33, 0.8))
    ctx.setLineWidth(8)
    for i in 0..<4 {
        let y = CGFloat(300 + i * 26)
        ctx.move(to: CGPoint(x: 744, y: y))
        ctx.addLine(to: CGPoint(x: 800, y: y))
        ctx.strokePath()
    }
}

func render(_ pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(pixels) / CGFloat(size), y: CGFloat(pixels) / CGFloat(size))
    draw(ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(render(base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(render(base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
// Превью рядом с .icns — чтобы посмотреть результат.
writePNG(render(1024), to: output.deletingPathExtension().appendingPathExtension("png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Иконка: \(output.path)" : "iconutil завершился с ошибкой")
