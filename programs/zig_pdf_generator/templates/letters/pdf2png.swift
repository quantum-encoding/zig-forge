// Rasterise every page of a PDF with macOS PDFKit (Quartz), which draws the
// standard 14 fonts (Helvetica, Helvetica-Bold, ...) with the system faces.
// poppler's pdftoppm substitutes a mismatched face for non-embedded
// Helvetica-Bold, so the proofs use this on macOS.
//
//   swift pdf2png.swift <in.pdf> <out-prefix> [dpi]   -> <out-prefix>-<page>.png
import AppKit
import PDFKit

let args = CommandLine.arguments
guard args.count >= 3, let doc = PDFDocument(url: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write("usage: pdf2png.swift <in.pdf> <out-prefix> [dpi]\n".data(using: .utf8)!)
    exit(2)
}
let scale = (args.count > 3 ? Double(args[3]) ?? 120 : 120) / 72.0

for i in 0..<doc.pageCount {
    guard let page = doc.page(at: i) else { continue }
    let box = page.bounds(for: .mediaBox)
    let w = Int((box.width * scale).rounded()), h = Int((box.height * scale).rounded())
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { exit(1) }
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: ctx)
    let out = URL(fileURLWithPath: "\(args[2])-\(i + 1).png")
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try png.write(to: out)
}
