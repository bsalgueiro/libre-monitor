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

    /// Called with the vertical scroll amount when the wheel or trackpad scrolls over the widget.
    var onScroll: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY)
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
        let container = NSView()
        let effect = RoundedBlurView()
        effect.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(effect)
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = roundedMask(radius: cornerRadius)

        let hosting = NSHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            effect.topAnchor.constraint(equalTo: container.topAnchor),
            effect.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    /// Shows or hides the blurred card behind the content. Hidden, the window has no shadow either: it would outline the text.
    func setCardVisible(_ visible: Bool) {
        contentView?.subviews.compactMap { $0 as? NSVisualEffectView }.forEach { $0.isHidden = !visible }
        hasShadow = visible
        invalidateShadow()
    }
}
