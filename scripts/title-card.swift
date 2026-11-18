// TKL-460: a review-demo chapter's title card, as a PNG the size of the iPhone 17 Pro's screen.
//   swift scripts/title-card.swift "Invited client" "Joins their coach, follows the week, logs it" build/review/card-client.png
// ffmpeg here has no drawtext filter, so the card is drawn with AppKit and held for a few seconds by scripts/demo-video.mjs.
import AppKit

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write(Data("usage: title-card.swift <title> <detail> <out.png>\n".utf8))
    exit(2)
}
let (title, detail, out) = (args[1], args[2], args[3])
let width = 1206, height = 2622

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

// The app's ink on its paper (App/Theme.swift's light scheme).
NSColor(red: 0.98, green: 0.98, blue: 0.97, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

let left: CGFloat = 96
let textWidth = CGFloat(width) - 2 * left
func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, top: CGFloat) -> CGFloat {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byWordWrapping
    let string = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style,
    ])
    let box = string.boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
    string.draw(with: NSRect(x: left, y: CGFloat(height) - top - box.height, width: textWidth, height: box.height), options: [.usesLineFragmentOrigin])
    return box.height
}
let ink = NSColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)
let muted = NSColor(red: 0.42, green: 0.42, blue: 0.44, alpha: 1)
var top: CGFloat = 1020
top += draw("barbrabell", size: 52, weight: .heavy, color: muted, top: top) + 36
top += draw(title, size: 128, weight: .bold, color: ink, top: top) + 40
_ = draw(detail, size: 56, weight: .regular, color: muted, top: top)

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: out))
