import AppKit
import SwiftUI

/// The floating widget window: borderless, transparent, always on top, joins every Space, draggable from its background.
final class WidgetPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 172),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        minSize = NSSize(width: 224, height: 148)
        maxSize = NSSize(width: 900, height: 640)
    }

    // A key window receives mouse-moved events, which the graph's hover readout needs.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private static let cornerRadius: CGFloat = 16

    /// A blur that follows the card's rounded shape.
    ///
    /// A blur behind the window is drawn by the window server, so a layer corner radius does not clip it: the
    /// square blur and the square shadow would show around the rounded card. A stretchable mask image is the
    /// supported way to round it, and the shadow is recomputed whenever the layout changes so it follows the mask.
    private final class RoundedBlurView: NSVisualEffectView {
        override func layout() {
            super.layout()
            window?.invalidateShadow()
        }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// Native blur behind the SwiftUI content, rounded to match the card shape.
    static func makeContent(rootView: some View) -> NSView {
        let effect = RoundedBlurView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = roundedMask(radius: cornerRadius)

        let hosting = NSHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }
}
