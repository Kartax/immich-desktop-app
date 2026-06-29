#!/usr/bin/env swift
//
// Renders the DMG installer-window background used by scripts/release.sh.
//
// Geometry is defined once in points (660x400 — the DMG window content size) and
// rendered at 1x and 2x so the window stays crisp on Retina displays. The two
// PNGs are later combined into a HiDPI .tiff with `tiffutil -cathidpicheck`.
//
// Usage: swift scripts/dmg/make-background.swift <output-dir>
//
// The arrow band (x ~250...410) sits between the two icon slots that
// release.sh positions via `create-dmg` (app icon at x=165, Applications drop
// at x=495). Keep these in sync if you move things.

import CoreGraphics
import Foundation
import ImageIO
import CoreText
import UniformTypeIdentifiers

// --- canvas (points) -------------------------------------------------------
let width: CGFloat = 660
let height: CGFloat = 400
// Icons are vertically centered by create-dmg at y=205 (measured from the top in
// Finder's coordinate space). Our CG context is bottom-up, so the icon row sits
// at height-205 here. Center the arrow on that row.
let iconCenterY = height - 205

// --- colors ----------------------------------------------------------------
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r/255, green: g/255, blue: b/255, alpha: a)
}
let bgTop = rgb(248, 248, 250)     // #F8F8FA
let bgBottom = rgb(238, 239, 242)  // #EEEFF2
let accent = rgb(110, 116, 128)    // muted slate for the arrow
let textColor = rgb(90, 94, 102)

// --- render one scale ------------------------------------------------------
func render(scale: CGFloat, to url: URL) {
    let pxW = Int(width * scale)
    let pxH = Int(height * scale)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        FileHandle.standardError.write("failed to create context\n".data(using: .utf8)!)
        exit(1)
    }
    ctx.scaleBy(x: scale, y: scale)   // draw in points
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)

    // background gradient
    let grad = CGGradient(colorsSpace: cs, colors: [bgTop, bgBottom] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: height),
                           end: CGPoint(x: 0, y: 0), options: [])

    // --- arrow (rounded shaft + filled head) -------------------------------
    let arrowStartX: CGFloat = 258
    let arrowEndX: CGFloat = 402
    let headLen: CGFloat = 30
    let headHalf: CGFloat = 20
    let shaftEndX = arrowEndX - headLen + 4   // overlap so shaft meets head

    ctx.setStrokeColor(accent)
    ctx.setLineCap(.round)
    ctx.setLineWidth(12)
    ctx.move(to: CGPoint(x: arrowStartX, y: iconCenterY))
    ctx.addLine(to: CGPoint(x: shaftEndX, y: iconCenterY))
    ctx.strokePath()

    ctx.setFillColor(accent)
    ctx.move(to: CGPoint(x: arrowEndX, y: iconCenterY))
    ctx.addLine(to: CGPoint(x: arrowEndX - headLen, y: iconCenterY + headHalf))
    ctx.addLine(to: CGPoint(x: arrowEndX - headLen, y: iconCenterY - headHalf))
    ctx.closePath()
    ctx.fillPath()

    // --- instruction text (centered above the arrow row) ------------------
    let text = "Drag ImmichDesktop to the Applications folder"
    let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, 15, nil)
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): textColor,
    ]
    let attr = NSAttributedString(string: text, attributes: attrs)
    let line = CTLineCreateWithAttributedString(attr)
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    let textX = (width - bounds.width) / 2
    // Above the icon/arrow row (which sits at iconCenterY ~195 from the bottom),
    // clear of the icon tops, so Finder's window never clips it at the edge.
    let textY: CGFloat = height - 88   // ~88 from the top
    ctx.textPosition = CGPoint(x: textX, y: textY)
    CTLineDraw(line, ctx)

    // --- write PNG ---------------------------------------------------------
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write("failed to encode \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        FileHandle.standardError.write("failed to write \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
    print("wrote \(url.path) (\(pxW)x\(pxH))")
}

// --- main ------------------------------------------------------------------
let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: make-background.swift <output-dir>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

render(scale: 1, to: outDir.appendingPathComponent("background.png"))
render(scale: 2, to: outDir.appendingPathComponent("background@2x.png"))
