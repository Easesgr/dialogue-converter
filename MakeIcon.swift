import AppKit

let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(calibratedRed: 0.94, green: 0.935, blue: 0.90, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 190, yRadius: 190).fill()
func arrow(_ points: [NSPoint], _ color: NSColor) {
    color.setStroke()
    let path = NSBezierPath(); path.lineWidth = 54; path.lineCapStyle = .round; path.lineJoinStyle = .round
    path.move(to: points[0]); for point in points.dropFirst() { path.line(to: point) }; path.stroke()
}
let green = NSColor(calibratedRed: 0.19, green: 0.40, blue: 0.33, alpha: 1)
let clay = NSColor(calibratedRed: 0.66, green: 0.36, blue: 0.24, alpha: 1)
arrow([NSPoint(x: 262, y: 638),NSPoint(x: 768, y: 638)], green)
arrow([NSPoint(x: 652, y: 745),NSPoint(x: 770, y: 638),NSPoint(x: 652, y: 531)], green)
arrow([NSPoint(x: 766, y: 386),NSPoint(x: 256, y: 386)], clay)
arrow([NSPoint(x: 370, y: 493),NSPoint(x: 252, y: 386),NSPoint(x: 370, y: 279)], clay)
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = bitmap.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
