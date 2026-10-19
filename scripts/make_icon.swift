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
// The dark square: its left and right edges from a row near the top (above the art), and its
// top edge from the first dark rows down the middle. The art may fill the square to the
// bottom, so the bottom edge is taken from the width (it is a square).
var top = h
for y in stride(from: 0, to: h / 2, by: 1) where dark(w / 2, y) { top = y; break }
let probeY = top + h / 16
var left = w, right = 0
for x in 0..<w where dark(x, probeY) { left = min(left, x); right = max(right, x) }
let side = right - left
let crop = CGRect(x: left, y: top, width: side, height: side)
FileHandle.standardError.write("image \(w)x\(h), square \(left),\(top) size \(side)\n".data(using: .utf8)!)
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
