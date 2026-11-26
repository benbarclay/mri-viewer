import AppKit
import MRICore
import SwiftUI

/// One anatomical slice pane. AppKit view for precise mouse / scroll handling:
/// click or drag = move crosshair, scroll = change slice, right-drag (or ⌥-drag) = window/level.
final class SliceNSView: NSView {
    var plane: ViewPlane = .axial
    weak var store: ViewerStore?
    private var image: CGImage?
    private var slice: Slice2D?
    private var lastDrag: NSPoint?
    private var scrollAccumulator: CGFloat = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func refresh() {
        guard let store, let (img, sl) = store.image(for: plane) else {
            image = nil; slice = nil; needsDisplay = true; return
        }
        image = img
        slice = sl
        needsDisplay = true
    }

    /// Rectangle the slice occupies, preserving physical aspect ratio.
    private var imageRect: CGRect {
        guard let s = slice else { return .zero }
        let physW = Double(s.width) * s.pixelWidthMM, physH = Double(s.height) * s.pixelHeightMM
        let b = bounds.insetBy(dx: 4, dy: 4)
        let k = min(b.width / physW, b.height / physH)
        let w = physW * k, h = physH * k
        return CGRect(x: b.midX - w / 2, y: b.midY - h / 2, width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext, let img = image, let s = slice, let store, let r = store.reslicer else { return }
        let rect = imageRect
        ctx.saveGState()
        // Flipped view: draw the CGImage upright.
        ctx.translateBy(x: 0, y: rect.maxY + rect.minY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: rect)
        ctx.restoreGState()

        // Crosshair
        let p = r.screen(for: plane, cursor: store.cursor)
        let cx = rect.minX + (CGFloat(p.x) + 0.5) / CGFloat(s.width) * rect.width
        let cy = rect.minY + (CGFloat(p.y) + 0.5) / CGFloat(s.height) * rect.height
        ctx.setStrokeColor(NSColor.systemGreen.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 4])
        ctx.move(to: CGPoint(x: rect.minX, y: cy)); ctx.addLine(to: CGPoint(x: rect.maxX, y: cy))
        ctx.move(to: CGPoint(x: cx, y: rect.minY)); ctx.addLine(to: CGPoint(x: cx, y: rect.maxY))
        ctx.strokePath()

        // Orientation letters + slice index
        let labels = plane.edgeLabels
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
                                                    .foregroundColor: NSColor.systemYellow.withAlphaComponent(0.9)]
        func put(_ t: String, _ pt: CGPoint) {
            let a = NSAttributedString(string: t, attributes: attrs)
            let sz = a.size()
            a.draw(at: CGPoint(x: pt.x - sz.width / 2, y: pt.y - sz.height / 2))
        }
        put(labels.left, CGPoint(x: rect.minX + 10, y: rect.midY))
        put(labels.right, CGPoint(x: rect.maxX - 10, y: rect.midY))
        put(labels.top, CGPoint(x: rect.midX, y: rect.minY + 10))
        put(labels.bottom, CGPoint(x: rect.midX, y: rect.maxY - 10))
        let info = NSAttributedString(string: "\(plane.label)  \(p.slice + 1)/\(r.sliceCount(plane))",
                                      attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                   .foregroundColor: NSColor.white.withAlphaComponent(0.8)])
        info.draw(at: CGPoint(x: 8, y: 6))
    }

    private func moveCursor(to event: NSEvent) {
        guard let store, let r = store.reslicer, let s = slice else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let rect = imageRect
        guard rect.width > 0 else { return }
        let x = Int((pt.x - rect.minX) / rect.width * CGFloat(s.width))
        let y = Int((pt.y - rect.minY) / rect.height * CGFloat(s.height))
        store.setCursor(r.voxel(for: plane, x: min(max(0, x), s.width - 1), y: min(max(0, y), s.height - 1), cursor: store.cursor))
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        lastDrag = e.locationInWindow
        if !e.modifierFlags.contains(.option) { moveCursor(to: e) }
    }

    override func mouseDragged(with e: NSEvent) {
        if e.modifierFlags.contains(.option) { windowLevel(e) } else { moveCursor(to: e) }
    }

    override func rightMouseDown(with e: NSEvent) { lastDrag = e.locationInWindow }
    override func rightMouseDragged(with e: NSEvent) { windowLevel(e) }

    private func windowLevel(_ e: NSEvent) {
        guard let last = lastDrag else { lastDrag = e.locationInWindow; return }
        let p = e.locationInWindow
        store?.adjustWindow(dx: p.x - last.x, dy: p.y - last.y)
        lastDrag = p
    }

    override func scrollWheel(with e: NSEvent) {
        scrollAccumulator += e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / 8 : e.scrollingDeltaY
        let steps = Int(scrollAccumulator)
        if steps != 0 {
            scrollAccumulator -= CGFloat(steps)
            store?.step(plane, by: -steps)
        }
    }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 126, 116: store?.step(plane, by: 1)   // up / page up
        case 125, 121: store?.step(plane, by: -1)  // down / page down
        default: super.keyDown(with: e)
        }
    }
}

struct SliceView: NSViewRepresentable {
    let plane: ViewPlane
    @ObservedObject var store: ViewerStore

    func makeNSView(context: Context) -> SliceNSView {
        let v = SliceNSView()
        v.plane = plane
        v.store = store
        v.refresh()
        return v
    }

    func updateNSView(_ v: SliceNSView, context: Context) {
        _ = store.renderToken // re-render whenever the store invalidates
        v.plane = plane
        v.store = store
        v.refresh()
    }
}
