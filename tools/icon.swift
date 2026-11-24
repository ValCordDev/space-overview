// Draws the app icon: swift tools/icon.swift OUTPUT.iconset, then iconutil -c icns.
import AppKit
let out = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
func color(_ h: Int) -> CGColor { CGColor(srgbRed: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: 1) }
func draw(_ px: Int, _ name: String) throws {
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // macOS icon grid: an 824 tile inside 1024. The drawing uses a 100-unit, top-left grid.
    let k = CGFloat(px) / 1024
    c.translateBy(x: 100 * k, y: CGFloat(px) - 100 * k)
    c.scaleBy(x: 8.24 * k, y: -8.24 * k)
    func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ f: Int) {
        c.setFillColor(color(f))
        c.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil))
        c.fillPath()
    }
    box(0, 0, 100, 100, 22, 0x1B1511)
    box(41, 15, 18, 14, 5, 0xF3ECE2)
    box(20, 23, 60, 10, 5, 0xF3ECE2)
    box(25, 39, 50, 12, 4, 0xF5A524)
    box(28, 55, 44, 12, 4, 0x5A4530); box(28, 55, 30, 12, 4, 0xF5A524)
    box(31, 71, 38, 12, 4, 0x5A4530); box(31, 71, 14, 12, 4, 0xF5A524)
    try NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out + "/" + name))
}
for s in [16, 32, 128, 256, 512] {
    try draw(s, "icon_\(s)x\(s).png")
    try draw(s * 2, "icon_\(s)x\(s)@2x.png")
}
