import AppKit
import CoreGraphics

// Usage: swift scripts/make_icon.swift design/icon-source.png design/icon-1024.png
// Finds the dark rounded square in the generated art, crops to it, and redraws it as a
// macOS icon: 824 pt body centred on a 1024 canvas, continuous-corner mask, soft shadow.
let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("bad input") }

let w = cg.width, h = cg.height
let rep = NSBitmapImageRep(cgImage: cg)
func dark(_ x: Int, _ y: Int) -> Bool {
    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
    return c.redComponent + c.greenComponent + c.blueComponent < 0.6  // navy/near-black
}
// Bounding box of the dark square: scan rows and columns through the middle.
var minX = w, maxX = 0, minY = h, maxY = 0
for y in stride(from: 0, to: h, by: 2) where dark(w / 2, y) { minY = min(minY, y); maxY = max(maxY, y) }
for x in stride(from: 0, to: w, by: 2) where dark(x, h / 2) { minX = min(minX, x); maxX = max(maxX, x) }
// The middle row/column cross the orange body too; the square's edges are what we want.
var minX2 = w, maxX2 = 0
let probeY = minY + (maxY - minY) / 8  // near the top edge, above the character
for x in 0..<w where dark(x, probeY) { minX2 = min(minX2, x); maxX2 = max(maxX2, x) }
let side = max(maxX2 - minX2, maxY - minY)
let cx = (minX2 + maxX2) / 2, cy = (minY + maxY) / 2
let crop = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
FileHandle.standardError.write("image \(w)x\(h), square \(Int(crop.minX)),\(Int(crop.minY)) size \(side)\n".data(using: .utf8)!)
guard let square = cg.cropping(to: crop) else { fatalError("crop failed") }

let canvas = 1024, body: CGFloat = 824
let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let rect = CGRect(x: (CGFloat(canvas) - body) / 2, y: (CGFloat(canvas) - body) / 2 + 10, width: body, height: body)
let shape = NSBezierPath(roundedRect: rect, xRadius: body * 0.225, yRadius: body * 0.225).cgPath
// Soft shadow under the body, as Apple's icon grid has.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(shape); ctx.setFillColor(CGColor(gray: 0.08, alpha: 1)); ctx.fillPath()
ctx.restoreGState()
// The art, clipped to the icon shape (inset a little so the source's own edge never shows).
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
ctx.interpolationQuality = .high
ctx.draw(square, in: rect.insetBy(dx: -body * 0.012, dy: -body * 0.012))
ctx.restoreGState()

let out = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
