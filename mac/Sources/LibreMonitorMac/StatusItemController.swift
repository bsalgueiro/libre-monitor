import AppKit

/// The menu bar item (the counterpart of TrayController.cs). Its image is the current glucose value on a tile
/// coloured by range, so the reading can be seen even when the widget is hidden.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let toggleItem = NSMenuItem()
    private let isWidgetVisible: () -> Bool
    private let toggleWidget: () -> Void

    init(isWidgetVisible: @escaping () -> Bool, toggleWidget: @escaping () -> Void, quit: @escaping () -> Void) {
        self.isWidgetVisible = isWidgetVisible
        self.toggleWidget = toggleWidget
        self.quitAction = quit
        super.init()

        let menu = NSMenu()
        menu.delegate = self

        toggleItem.title = "Hide widget"
        toggleItem.target = self
        toggleItem.action = #selector(toggleClicked)
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Libre Monitor", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        update(text: "--", tile: TileColors.muted, tooltip: "Libre Monitor")
    }

    private let quitAction: () -> Void

    var isVisible: Bool {
        get { item.isVisible }
        set { item.isVisible = newValue }
    }

    func update(text: String, tile: NSColor, tooltip: String) {
        item.button?.image = Self.tileImage(text: text, color: tile)
        item.button?.toolTip = tooltip
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        toggleItem.title = isWidgetVisible() ? "Hide widget" : "Show widget"
    }

    @objc private func toggleClicked() { toggleWidget() }

    @objc private func quitClicked() { quitAction() }

    /// White digits on a rounded coloured tile. The font shrinks until the text fits.
    static func tileImage(text: String, color: NSColor) -> NSImage {
        let size = NSSize(width: 30, height: 18)

        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()

            func attributes(_ pointSize: CGFloat) -> [NSAttributedString.Key: Any] {
                [.font: NSFont.systemFont(ofSize: pointSize, weight: .bold), .foregroundColor: NSColor.white]
            }

            let label = text as NSString
            var pointSize: CGFloat = 13
            while pointSize > 7, label.size(withAttributes: attributes(pointSize)).width > rect.width - 4 {
                pointSize -= 1
            }

            let attrs = attributes(pointSize)
            let textSize = label.size(withAttributes: attrs)
            label.draw(
                at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
                withAttributes: attrs)
            return true
        }

        image.isTemplate = false // keep the colours; a template image would be tinted to the menu bar
        return image
    }
}
