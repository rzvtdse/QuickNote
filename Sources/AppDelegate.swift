import AppKit
import Carbon.HIToolbox

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem!
    var panel: NSPanel!
    var sectionsController: SectionsController!
    var eventHandlerRef: EventHandlerRef?
    var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMenu()
        setupStatusItem()
        setupPanel()
        registerHotKey()
    }

    func setupMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Cut",         action: #selector(NSText.cut(_:)),       keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy",        action: #selector(NSText.copy(_:)),      keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste",       action: #selector(NSText.paste(_:)),     keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Undo",        action: Selector("undo:"),               keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo",        action: Selector("redo:"),               keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem(title: "Select All",  action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "New Section", action: #selector(newSection),           keyEquivalent: "N"))
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    // MARK: - Status Bar

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        if let img = Bundle.main.image(forResource: "menubar_icon") {
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = true   // lets macOS tint it for light/dark menu bar
            button.image = img
        }
        button.action = #selector(togglePanel)
        button.target = self
    }

    // MARK: - Panel

    func setupPanel() {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let w: CGFloat = 500, h: CGFloat = 580
        let rect = CGRect(x: screen.midX - w / 2, y: screen.midY - h / 2, width: w, height: h)

        panel = NSPanel(
            contentRect: rect,
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self
        panel.minSize = CGSize(width: 300, height: 220)
        [NSWindow.ButtonType.miniaturizeButton, .zoomButton, .closeButton].forEach {
            panel.standardWindowButton($0)?.isHidden = true
        }

        // Remember window size & position across launches
        panel.setFrameAutosaveName("QuickNotePanel")

        guard let contentView = panel.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 10
        contentView.layer?.masksToBounds = true

        let fx = NSVisualEffectView(frame: contentView.bounds)
        fx.autoresizingMask = [.width, .height]
        fx.material = .sidebar
        fx.blendingMode = .behindWindow
        fx.state = .active
        contentView.addSubview(fx)

        // Dark overlay to reduce transparency
        let overlay = NSView(frame: contentView.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor(red: 0.90, green: 0.60, blue: 0.10, alpha: 0.03).cgColor
        fx.addSubview(overlay)

        sectionsController = SectionsController()
        sectionsController.build(in: fx)
    }

    // MARK: - Global Hotkey (Cmd+Shift+Space)

    func registerHotKey() {
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: OSType(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, _, userData -> OSStatus in
            guard let ptr = userData else { return OSStatus(eventNotHandledErr) }
            let d = Unmanaged<AppDelegate>.fromOpaque(ptr).takeUnretainedValue()
            DispatchQueue.main.async { d.togglePanel() }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventSpec,
                            Unmanaged.passUnretained(self).toOpaque(), &eventHandlerRef)
        let hotKeyID = EventHotKeyID(signature: 0x514E4F54, id: 1)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey | shiftKey), hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    // MARK: - Actions

    @objc func newSection() { sectionsController.addSection() }

    @objc func togglePanel() {
        panel.isVisible ? panel.orderOut(nil) : showPanel()
    }

    @objc func hidePanel() { panel.orderOut(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        if let ref = eventHandlerRef { RemoveEventHandler(ref) }
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
    }

    func windowDidResignKey(_ notification: Notification) { hidePanel() }

    func showPanel() {
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            self.sectionsController.focusLastSection()
        }
    }
}
