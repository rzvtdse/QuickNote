#!/usr/bin/env swift
import CoreGraphics
import CoreText
import Foundation
import ImageIO

func makeIconPNG(size: Int) -> Data? {
    let s = CGFloat(size)
    let space = CGColorSpaceCreateDeviceRGB()
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

    guard let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: info.rawValue
    ) else { return nil }

    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // Circle
    let m = s * 0.04
    ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.88))
    ctx.fillEllipse(in: CGRect(x: m, y: m, width: s - m * 2, height: s - m * 2))

    // Copperplate N
    let fontSize = s * 0.50
    let font = CTFontCreateWithName("Copperplate" as CFString, fontSize, nil)
    let white = CGColor(red: 1, green: 1, blue: 1, alpha: 0.95)
    let attrs = [kCTFontAttributeName: font,
                 kCTForegroundColorAttributeName: white] as [CFString: Any] as CFDictionary
    let line = CTLineCreateWithAttributedString(
        CFAttributedStringCreate(nil, "N" as CFString, attrs)!
    )

    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
    let w = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
    let h = ascent + descent

    ctx.textPosition = CGPoint(x: (s - CGFloat(w)) / 2, y: (s - h) / 2 + descent)
    CTLineDraw(line, ctx)

    guard let img = ctx.makeImage() else { return nil }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}

let iconset = "Resources/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let configs: [(Int, String)] = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (size, name) in configs {
    if let data = makeIconPNG(size: size) {
        try! data.write(to: URL(fileURLWithPath: "\(iconset)/\(name)"))
        print("  ✓ \(name)")
    } else {
        print("  ✗ failed: \(name)")
    }
}
