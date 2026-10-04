import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])

func savePNG(_ image: NSImage, to url: URL) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        fputs("could not write \(url.path)\n", stderr)
        exit(1)
    }
    try! data.write(to: url)
}

func appIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let colors = [
        CGColor(colorSpace: space, components: [0.18, 0.55, 0.62, 1])!,
        CGColor(colorSpace: space, components: [0.06, 0.28, 0.38, 1])!,
    ] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: size * 0.5, y: size),
        end: CGPoint(x: size * 0.5, y: 0),
        options: []
    )

    func speaker(at center: CGPoint) {
        let width = size * 0.30
        let height = size * 0.46
        let body = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        let path = CGPath(roundedRect: body, cornerWidth: size * 0.07, cornerHeight: size * 0.07, transform: nil)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.addPath(path)
        ctx.fillPath()

        let cone = size * 0.15
        let coneRect = CGRect(x: center.x - cone / 2, y: center.y - cone / 2 - size * 0.01, width: cone, height: cone)
        ctx.setFillColor(CGColor(srgbRed: 0.07, green: 0.33, blue: 0.42, alpha: 1))
        ctx.fillEllipse(in: coneRect)
        let pupil = cone * 0.42
        let pupilRect = CGRect(x: coneRect.midX - pupil / 2, y: coneRect.midY - pupil / 2, width: pupil, height: pupil)
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.95))
        ctx.fillEllipse(in: pupilRect)
    }

    speaker(at: CGPoint(x: size * 0.31, y: size * 0.46))
    speaker(at: CGPoint(x: size * 0.69, y: size * 0.46))
    image.unlockFocus()
    return image
}

func menuIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    func speaker(at center: CGPoint) {
        let width = size * 0.34
        let height = size * 0.62
        let body = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        let path = CGPath(roundedRect: body, cornerWidth: size * 0.08, cornerHeight: size * 0.08, transform: nil)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.addPath(path)
        ctx.fillPath()
        let cone = size * 0.12
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: center.x - cone / 2, y: center.y - cone / 2, width: cone, height: cone))
    }
    speaker(at: CGPoint(x: size * 0.28, y: size * 0.5))
    speaker(at: CGPoint(x: size * 0.72, y: size * 0.5))
    image.unlockFocus()
    return image
}

let iconset = root.appendingPathComponent("SoundSync.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let sizes = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]
for (name, pixels) in sizes {
    savePNG(appIcon(size: CGFloat(pixels)), to: iconset.appendingPathComponent(name))
}
savePNG(menuIcon(size: 36), to: root.appendingPathComponent("MenuBarIcon.png"))
print(iconset.path)
