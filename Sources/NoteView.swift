import AppKit

// MARK: - Custom Text View

class SectionTextView: NSTextView, NSLayoutManagerDelegate {
    var onFocus: (() -> Void)?
    var onBlur: (() -> Void)?
    var onProgrammaticChange: (() -> Void)?

    private var isProcessingLinks = false
    fileprivate static let linkKey    = NSAttributedString.Key("QNLink")
    fileprivate static let toggleKey  = NSAttributedString.Key("QNToggle")
    fileprivate static let hiddenKey  = NSAttributedString.Key("QNHidden")

    func installLayoutManagerDelegate() {
        layoutManager?.delegate = self
    }

    // MARK: - Layout Manager Delegate: truly hide chars tagged QNHidden

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>,
                       font aFont: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = textStorage else { return 0 }
        let count = glyphRange.length
        var newProps = Array(UnsafeBufferPointer(start: props, count: count))
        var modified = false
        for i in 0..<count {
            let charIdx = charIndexes[i]
            if charIdx < storage.length,
               storage.attribute(SectionTextView.hiddenKey, at: charIdx, effectiveRange: nil) != nil {
                newProps[i] = .null
                modified = true
            }
        }
        if modified {
            layoutManager.setGlyphs(glyphs, properties: newProps,
                                    characterIndexes: charIndexes, font: aFont,
                                    forGlyphRange: glyphRange)
            return count
        }
        return 0
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocus?() }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { onBlur?() }
        return result
    }

    // MARK: - Link Processing

    func processLinks() {
        guard !isProcessingLinks, let storage = textStorage else { return }
        isProcessingLinks = true
        defer { isProcessingLinks = false }

        let text = string
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return }

        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        detector.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
            guard let match = match, let url = match.url,
                  url.scheme == "http" || url.scheme == "https" else { return }

            let fullURLStr = url.absoluteString
            let domain = url.host ?? fullURLStr
            let range = match.range
            let attrs = storage.attributes(at: range.location, effectiveRange: nil)
            let existingToggle = attrs[SectionTextView.toggleKey] as? String
            // Preserve user's toggle choice if already set, otherwise start collapsed
            let toggleState = existingToggle ?? "expand"

            self.styleLink(in: storage, fullURL: fullURLStr, domain: domain,
                          linkRange: range, toggle: toggleState)
        }
    }

    /// Applies link styling based on toggle state ("expand" = currently collapsed,
    /// "collapse" = currently expanded).
    private func styleLink(in storage: NSTextStorage, fullURL: String, domain: String,
                          linkRange: NSRange, toggle: String) {
        let nsText = storage.string as NSString
        let domainRange = nsText.range(of: domain, options: [], range: linkRange)

        storage.beginEditing()

        // Reset prior styling on the whole link range
        storage.removeAttribute(SectionTextView.hiddenKey, range: linkRange)
        storage.removeAttribute(.foregroundColor,          range: linkRange)
        storage.removeAttribute(.underlineStyle,           range: linkRange)

        // Apply fresh link styling
        storage.addAttributes([
            SectionTextView.linkKey:   fullURL,
            SectionTextView.toggleKey: toggle,
            .foregroundColor:          NSColor.systemCyan.withAlphaComponent(0.85),
            .underlineStyle:           NSUnderlineStyle.single.rawValue,
        ], range: linkRange)

        // If collapsed, truly hide the path via a glyph-null marker attribute
        if toggle == "expand",
           domainRange.location != NSNotFound,
           domainRange.upperBound < linkRange.upperBound {
            let pathRange = NSRange(location: domainRange.upperBound,
                                    length: linkRange.upperBound - domainRange.upperBound)
            storage.addAttribute(SectionTextView.hiddenKey, value: true, range: pathRange)
        }

        storage.endEditing()

        // Force layout manager to regenerate glyphs (for glyph-null changes to take effect)
        layoutManager?.invalidateGlyphs(forCharacterRange: linkRange,
                                        changeInLength: 0,
                                        actualCharacterRange: nil)
        layoutManager?.invalidateLayout(forCharacterRange: linkRange,
                                        actualCharacterRange: nil)
        layoutManager?.invalidateDisplay(forCharacterRange: linkRange)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard let storage = textStorage, storage.length > 0 else {
            super.mouseDown(with: event)
            return
        }

        let pt = convert(event.locationInWindow, from: nil)
        let raw = characterIndexForInsertion(at: pt)
        let candidates = [raw, raw > 0 ? raw - 1 : raw].map { min($0, storage.length - 1) }

        // Option+click → open URL
        if event.modifierFlags.contains(.option) {
            for idx in candidates {
                let attrs = storage.attributes(at: idx, effectiveRange: nil)
                if let urlStr = attrs[SectionTextView.linkKey] as? String,
                   let url = URL(string: urlStr) {
                    NSWorkspace.shared.open(url)
                    return
                }
            }
        }

        // Double-click → toggle expand / collapse
        if event.clickCount == 2 {
            for idx in candidates {
                let attrs = storage.attributes(at: idx, effectiveRange: nil)
                if let toggle = attrs[SectionTextView.toggleKey] as? String,
                   let fullURL = attrs[SectionTextView.linkKey] as? String {
                    handleToggle(state: toggle, fullURL: fullURL, at: idx)
                    return
                }
            }
        }

        super.mouseDown(with: event)
    }

    private func handleToggle(state: String, fullURL: String, at idx: Int) {
        guard let storage = textStorage else { return }

        // Find the full range of this link
        var linkRange = NSRange(location: 0, length: 0)
        _ = storage.attribute(SectionTextView.linkKey, at: idx,
                              longestEffectiveRange: &linkRange,
                              in: NSRange(location: 0, length: storage.length))
        guard linkRange.length > 0 else { return }

        let domain = URL(string: fullURL)?.host ?? fullURL
        // Flip state: "expand" means currently collapsed → expand it (new state "collapse"),
        // "collapse" means currently expanded → collapse it (new state "expand")
        let newToggle = state == "expand" ? "collapse" : "expand"

        isProcessingLinks = true
        defer { isProcessingLinks = false }

        styleLink(in: storage, fullURL: fullURL, domain: domain,
                  linkRange: linkRange, toggle: newToggle)

        // Force redraw
        needsDisplay = true
    }
}

// MARK: - Model

struct NoteSection: Codable {
    var id: String
    var content: String
    var bucketId: String?
    init(content: String = "", bucketId: String? = nil) {
        self.id = UUID().uuidString
        self.content = content
        self.bucketId = bucketId
    }
}

struct NoteBucket: Codable {
    var id: String
    var name: String
    init(name: String) { self.id = UUID().uuidString; self.name = name }
}

// MARK: - Controller

class SectionsController: NSObject {

    private var sections: [NoteSection] = []
    private var buckets: [NoteBucket] = []
    private var activeBucketId: String = ""
    private var searchQuery: String = ""
    private var tableView: NSTableView!
    private var mergeButton: NSButton!
    private var searchField: NSSearchField!
    private var searchHeightConstraint: NSLayoutConstraint!
    private var bucketBar: NSStackView!
    private var selectedIds: Set<String> = []
    private var eventMonitor: Any?
    private var keyMonitor: Any?
    private var lastKnownTableWidth: CGFloat = 0

    private static let pbType = NSPasteboard.PasteboardType("com.quicknote.section")

    /// Sections in the active bucket, further filtered by search query.
    private var filteredSections: [NoteSection] {
        let inBucket = sections.filter { ($0.bucketId ?? "") == activeBucketId }
        guard !searchQuery.isEmpty else { return inBucket }
        return inBucket.filter { $0.content.localizedCaseInsensitiveContains(searchQuery) }
    }

    // MARK: Build UI

    func build(in parent: NSView) {
        load()
        ensureDefaultBucket()

        // Bucket tab bar
        bucketBar = NSStackView()
        bucketBar.translatesAutoresizingMaskIntoConstraints = false
        bucketBar.orientation = .horizontal
        bucketBar.spacing = 4
        bucketBar.alignment = .centerY
        parent.addSubview(bucketBar)

        // Search field (hidden until Cmd+F)
        searchField = NSSearchField()
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search..."
        searchField.controlSize = .small
        searchField.delegate = self
        searchField.isHidden = true
        parent.addSubview(searchField)

        // Table
        tableView = NSTableView()
        tableView.backgroundColor = .clear
        tableView.headerView = nil
        tableView.intercellSpacing = NSSize(width: 0, height: 8)
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        if #available(macOS 11, *) { tableView.style = .plain }

        let col = NSTableColumn(identifier: .init("col"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([SectionsController.pbType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(tableFrameChanged),
                                               name: NSView.frameDidChangeNotification,
                                               object: tableView)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = tableView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        parent.addSubview(scroll)

        // Bottom buttons
        let addBtn = NSButton(title: "+ New Section", target: self, action: #selector(addSection))
        addBtn.translatesAutoresizingMaskIntoConstraints = false
        addBtn.isBordered = false
        addBtn.bezelStyle = .inline
        addBtn.font = NSFont.systemFont(ofSize: 11)
        addBtn.contentTintColor = NSColor.white.withAlphaComponent(0.4)

        mergeButton = NSButton(title: "⊕ Merge", target: self, action: #selector(mergeSections))
        mergeButton.translatesAutoresizingMaskIntoConstraints = false
        mergeButton.isBordered = false
        mergeButton.bezelStyle = .inline
        mergeButton.font = NSFont.systemFont(ofSize: 11)
        mergeButton.contentTintColor = NSColor.systemBlue.withAlphaComponent(0.85)
        mergeButton.isHidden = true

        let bottomStack = NSStackView(views: [addBtn, mergeButton])
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        bottomStack.orientation = .horizontal
        bottomStack.spacing = 16
        parent.addSubview(bottomStack)

        searchHeightConstraint = searchField.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            bucketBar.topAnchor.constraint(equalTo: parent.topAnchor, constant: 6),
            bucketBar.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 10),
            bucketBar.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor, constant: -10),

            searchField.topAnchor.constraint(equalTo: bucketBar.bottomAnchor, constant: 6),
            searchField.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -10),
            searchHeightConstraint,

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -10),

            bottomStack.centerXAnchor.constraint(equalTo: parent.centerXAnchor),
            bottomStack.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -10),
        ])

        rebuildBucketBar()

        // Cmd+F to reveal search, Esc to dismiss it
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            // Cmd+F
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "f" {
                self.showSearch()
                return nil
            }
            // Escape while search is focused
            if event.keyCode == 53, self.searchField.currentEditor() != nil {
                self.hideSearch()
                return nil
            }
            return event
        }

        // Cmd+click monitor for multi-select
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self else { return event }
            let pt = self.tableView.convert(event.locationInWindow, from: nil)
            let row = self.tableView.row(at: pt)
            if event.modifierFlags.contains(.command), row >= 0, row < self.filteredSections.count {
                let id = self.filteredSections[row].id
                if self.selectedIds.contains(id) { self.selectedIds.remove(id) }
                else { self.selectedIds.insert(id) }
                self.updateSelectionUI()
                return nil // consume — don't focus text view
            } else if !event.modifierFlags.contains(.command), !self.selectedIds.isEmpty {
                // Don't clear selection when clicking the merge button itself
                let ptInMerge = self.mergeButton.convert(event.locationInWindow, from: nil)
                if !self.mergeButton.bounds.contains(ptInMerge) {
                    self.selectedIds.removeAll()
                    self.updateSelectionUI()
                }
            }
            return event
        }
    }

    deinit {
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
        if let m = keyMonitor   { NSEvent.removeMonitor(m) }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Search visibility

    private func showSearch() {
        searchField.isHidden = false
        searchHeightConstraint.isActive = false
        searchField.window?.makeFirstResponder(searchField)
    }

    private func hideSearch() {
        searchField.stringValue = ""
        searchQuery = ""
        tableView.reloadData()
        searchField.isHidden = true
        searchHeightConstraint.isActive = true
        focusLastSection()
    }

    @objc private func tableFrameChanged() {
        let w = tableView.bounds.width
        guard abs(w - lastKnownTableWidth) > 0.5, w > 0 else { return }
        lastKnownTableWidth = w
        tableView.noteHeightOfRows(withIndexesChanged:
            IndexSet(integersIn: 0..<tableView.numberOfRows))
    }

    // MARK: Selection

    func updateSelectionUI() {
        for row in 0..<tableView.numberOfRows {
            guard row < filteredSections.count else { continue }
            (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SectionCellView)?
                .setSelected(selectedIds.contains(filteredSections[row].id))
        }
        mergeButton.isHidden = selectedIds.count < 2
    }

    @objc func mergeSections() {
        let ordered = filteredSections.filter { selectedIds.contains($0.id) }
        guard ordered.count >= 2 else { return }
        let merged = ordered.map { $0.content }.joined(separator: "\n\n")
        let firstId = ordered[0].id
        let removeIds = Set(ordered.dropFirst().map { $0.id })
        if let idx = sections.firstIndex(where: { $0.id == firstId }) {
            sections[idx].content = merged
        }
        sections.removeAll { removeIds.contains($0.id) }
        selectedIds.removeAll()
        tableView.reloadData()
        updateSelectionUI()
        save()
    }

    // MARK: Section Operations

    @objc func addSection() {
        selectedIds.removeAll()
        sections.append(NoteSection(bucketId: activeBucketId))
        tableView.reloadData()
        save()
        DispatchQueue.main.async {
            let row = self.tableView.numberOfRows - 1
            guard row >= 0 else { return }
            self.tableView.scrollRowToVisible(row)
            (self.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SectionCellView)?.focus()
        }
    }

    func split(id: String, before: String, after: String) {
        guard let idx = sections.firstIndex(where: { $0.id == id }) else { return }
        sections[idx].content = before
        let newSection = NoteSection(content: after, bucketId: sections[idx].bucketId)
        sections.insert(newSection, at: idx + 1)
        save()
        tableView.reloadData()
        let newSectionId = newSection.id
        DispatchQueue.main.async {
            guard let newRow = self.filteredSections.firstIndex(where: { $0.id == newSectionId }) else { return }
            self.tableView.scrollRowToVisible(newRow)
            (self.tableView.view(atColumn: 0, row: newRow, makeIfNecessary: false) as? SectionCellView)?.focus()
        }
    }

    func update(id: String, content: String) {
        guard let idx = sections.firstIndex(where: { $0.id == id }) else { return }
        sections[idx].content = content
        UserDefaults.standard.set(id, forKey: "qn_last_section")
        save()
    }

    func delete(id: String) {
        sections.removeAll { $0.id == id }
        if !sections.contains(where: { $0.bucketId == activeBucketId }) {
            sections.append(NoteSection(bucketId: activeBucketId))
        }
        selectedIds.removeAll()
        tableView.reloadData()
        save()
    }

    func refreshRowHeight(for view: NSView) {
        let row = tableView.row(for: view)
        guard row >= 0 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            self.tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        }
    }

    // MARK: Buckets

    private func ensureDefaultBucket() {
        if buckets.isEmpty {
            let b = NoteBucket(name: "Notes")
            buckets = [b]
            activeBucketId = b.id
        }
        if !buckets.contains(where: { $0.id == activeBucketId }) {
            activeBucketId = buckets[0].id
        }
        // Migrate any legacy sections with no bucket → active bucket
        var changed = false
        for i in sections.indices where sections[i].bucketId == nil {
            sections[i].bucketId = activeBucketId
            changed = true
        }
        if sections.isEmpty {
            sections = [NoteSection(bucketId: activeBucketId)]
            changed = true
        } else if !sections.contains(where: { $0.bucketId == activeBucketId }) {
            sections.append(NoteSection(bucketId: activeBucketId))
            changed = true
        }
        if changed { save() }
    }

    private func rebuildBucketBar() {
        bucketBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for b in buckets {
            let btn = NSButton(title: b.name, target: self, action: #selector(bucketTabClicked(_:)))
            btn.identifier = NSUserInterfaceItemIdentifier(b.id)
            btn.isBordered = false
            btn.bezelStyle = .inline
            btn.font = NSFont.systemFont(ofSize: 12, weight: b.id == activeBucketId ? .semibold : .regular)
            btn.contentTintColor = b.id == activeBucketId
                ? NSColor.white.withAlphaComponent(0.95)
                : NSColor.white.withAlphaComponent(0.4)
            // Right-click menu for rename / delete
            let menu = NSMenu()
            let rename = NSMenuItem(title: "Rename…", action: #selector(bucketRenameMenu(_:)), keyEquivalent: "")
            rename.target = self
            rename.representedObject = b.id
            let del = NSMenuItem(title: "Delete", action: #selector(bucketDeleteMenu(_:)), keyEquivalent: "")
            del.target = self
            del.representedObject = b.id
            menu.addItem(rename)
            menu.addItem(del)
            btn.menu = menu
            bucketBar.addArrangedSubview(btn)
        }
        let plus = NSButton(title: "+", target: self, action: #selector(addBucket))
        plus.isBordered = false
        plus.bezelStyle = .inline
        plus.font = NSFont.systemFont(ofSize: 13, weight: .light)
        plus.contentTintColor = NSColor.white.withAlphaComponent(0.4)
        bucketBar.addArrangedSubview(plus)
    }

    @objc private func bucketTabClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, id != activeBucketId else { return }
        switchToBucket(id)
    }

    private func switchToBucket(_ id: String) {
        activeBucketId = id
        UserDefaults.standard.set(id, forKey: "qn_active_bucket")
        selectedIds.removeAll()
        // Ensure bucket has at least one section
        if !sections.contains(where: { $0.bucketId == id }) {
            sections.append(NoteSection(bucketId: id))
            save()
        }
        rebuildBucketBar()
        tableView.reloadData()
        updateSelectionUI()
    }

    @objc private func addBucket() {
        let alert = NSAlert()
        alert.messageText = "New bucket"
        alert.informativeText = "Name your bucket:"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        input.stringValue = "Bucket \(buckets.count + 1)"
        alert.accessoryView = input
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            let b = NoteBucket(name: name)
            buckets.append(b)
            save()
            switchToBucket(b.id)
        }
    }

    @objc private func bucketRenameMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let idx = buckets.firstIndex(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename bucket"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        input.stringValue = buckets[idx].name
        alert.accessoryView = input
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            buckets[idx].name = name
            save()
            rebuildBucketBar()
        }
    }

    @objc private func bucketDeleteMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let idx = buckets.firstIndex(where: { $0.id == id }) else { return }
        if buckets.count <= 1 {
            let a = NSAlert()
            a.messageText = "Can't delete the last bucket."
            a.runModal()
            return
        }
        let confirm = NSAlert()
        confirm.messageText = "Delete bucket \"\(buckets[idx].name)\"?"
        confirm.informativeText = "All sections in this bucket will be permanently deleted."
        confirm.addButton(withTitle: "Delete")
        confirm.addButton(withTitle: "Cancel")
        confirm.alertStyle = .warning
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        sections.removeAll { $0.bucketId == id }
        buckets.remove(at: idx)
        if activeBucketId == id {
            activeBucketId = buckets[0].id
        }
        save()
        switchToBucket(activeBucketId)
    }

    // MARK: Persistence

    func focusSection(offset: Int, from id: String) {
        let list = filteredSections
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
        let next = (idx + offset + list.count) % list.count
        tableView.scrollRowToVisible(next)
        DispatchQueue.main.async {
            (self.tableView.view(atColumn: 0, row: next, makeIfNecessary: true) as? SectionCellView)?.focus()
        }
    }

    func focusLastSection() {
        let lastId = UserDefaults.standard.string(forKey: "qn_last_section")
        let target = lastId.flatMap { id in filteredSections.firstIndex(where: { $0.id == id }) }
        let row = target ?? filteredSections.count - 1
        guard row >= 0 else { return }
        tableView.scrollRowToVisible(row)
        (tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? SectionCellView)?.focus()
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(sections), forKey: "qn_sections_v1")
        UserDefaults.standard.set(try? JSONEncoder().encode(buckets), forKey: "qn_buckets_v1")
        UserDefaults.standard.set(activeBucketId, forKey: "qn_active_bucket")
    }

    func load() {
        if let data = UserDefaults.standard.data(forKey: "qn_sections_v1"),
           let saved = try? JSONDecoder().decode([NoteSection].self, from: data) {
            sections = saved
        }
        if let data = UserDefaults.standard.data(forKey: "qn_buckets_v1"),
           let saved = try? JSONDecoder().decode([NoteBucket].self, from: data) {
            buckets = saved
        }
        if let id = UserDefaults.standard.string(forKey: "qn_active_bucket") {
            activeBucketId = id
        }
    }
}

// MARK: Table Data Source + Delegate

extension SectionsController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { filteredSections.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = SectionCellView()
        cell.configure(filteredSections[row], query: searchQuery, ctrl: self)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let w = max(100, tableView.bounds.width - 8)
        return SectionCellView.rowHeight(content: filteredSections[row].content, width: w)
    }

    // Drag source
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard searchQuery.isEmpty else { return nil }
        let item = NSPasteboardItem()
        item.setString(filteredSections[row].id, forType: SectionsController.pbType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        op == .above ? .move : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let fromId = info.draggingPasteboard.string(forType: SectionsController.pbType),
              let fromGlobal = sections.firstIndex(where: { $0.id == fromId }) else { return false }
        // `row` is an index into filteredSections; map it to a global insertion index.
        let filtered = filteredSections
        let targetGlobal: Int
        if row >= filtered.count {
            // Dropped after last filtered row; insert after last section in this bucket
            targetGlobal = (sections.lastIndex(where: { $0.bucketId == activeBucketId }) ?? sections.count - 1) + 1
        } else {
            let anchorId = filtered[row].id
            targetGlobal = sections.firstIndex(where: { $0.id == anchorId }) ?? sections.count
        }
        let moved = sections.remove(at: fromGlobal)
        let adjusted = targetGlobal > fromGlobal ? targetGlobal - 1 : targetGlobal
        sections.insert(moved, at: min(adjusted, sections.count))
        tableView.reloadData()
        save()
        return true
    }
}

// MARK: Search

extension SectionsController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        searchQuery = (obj.object as? NSSearchField)?.stringValue ?? ""
        tableView.reloadData()
    }
}

// MARK: - Section Cell View

class SectionCellView: NSTableCellView {

    private var textView: SectionTextView!
    private var sectionId = ""
    private weak var ctrl: SectionsController?

    static let headerH: CGFloat = 22
    static let minH: CGFloat = 72

    static func rowHeight(content: String, width: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let text = content.isEmpty ? " " : content
        let r = (text as NSString).boundingRect(
            with: CGSize(width: width - 28, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return max(minH, ceil(r.height) + headerH + 20)
    }

    func configure(_ section: NoteSection, query: String, ctrl: SectionsController) {
        self.sectionId = section.id
        self.ctrl = ctrl

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor

        // Header bar
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        let handle = NSTextField(labelWithString: "· · ·")
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.textColor = NSColor.white.withAlphaComponent(0.2)
        handle.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        header.addSubview(handle)

        let copy = NSButton(title: "⎘", target: self, action: #selector(copySelf))
        copy.translatesAutoresizingMaskIntoConstraints = false
        copy.isBordered = false
        copy.bezelStyle = .inline
        copy.font = NSFont.systemFont(ofSize: 13, weight: .light)
        copy.contentTintColor = NSColor.white.withAlphaComponent(0.3)
        copy.toolTip = "Copy"
        header.addSubview(copy)

        let del = NSButton(title: "×", target: self, action: #selector(deleteSelf))
        del.translatesAutoresizingMaskIntoConstraints = false
        del.isBordered = false
        del.bezelStyle = .inline
        del.font = NSFont.systemFont(ofSize: 15, weight: .light)
        del.contentTintColor = NSColor.white.withAlphaComponent(0.3)
        header.addSubview(del)

        // Text view
        textView = SectionTextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isRichText = false
        textView.backgroundColor = .clear
        textView.textColor = NSColor.white.withAlphaComponent(0.9)
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.insertionPointColor = .white
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                        height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 2, height: 2)
        textView.allowsUndo = true
        textView.installLayoutManagerDelegate()
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor.white.withAlphaComponent(0.2),
            .foregroundColor: NSColor.white,
        ]
        textView.string = section.content
        textView.delegate = self
        textView.onFocus = { [weak self] in
            guard let self = self else { return }
            UserDefaults.standard.set(self.sectionId, forKey: "qn_last_section")
            self.setActive(true)
        }
        textView.onBlur = { [weak self] in self?.setActive(false) }
        textView.onProgrammaticChange = { [weak self] in
            guard let self = self else { return }
            self.ctrl?.update(id: self.sectionId, content: self.textView.string)
            self.ctrl?.refreshRowHeight(for: self)
        }
        addSubview(textView)

        // Process any URLs already in the saved content
        DispatchQueue.main.async { self.textView.processLinks() }

        // Highlight search matches
        if !query.isEmpty, let storage = textView.textStorage {
            let str = section.content as NSString
            var range = NSRange(location: 0, length: str.length)
            while range.location < str.length {
                let found = str.range(of: query, options: .caseInsensitive, range: range)
                guard found.location != NSNotFound else { break }
                storage.addAttribute(.backgroundColor, value: NSColor.yellow.withAlphaComponent(0.4), range: found)
                range = NSRange(location: found.upperBound, length: str.length - found.upperBound)
            }
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            header.heightAnchor.constraint(equalToConstant: SectionCellView.headerH),

            handle.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            handle.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            del.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            del.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            copy.trailingAnchor.constraint(equalTo: del.leadingAnchor, constant: -6),
            copy.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            textView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    func focus() { textView?.window?.makeFirstResponder(textView) }

    func setActive(_ active: Bool) {
        layer?.backgroundColor = NSColor.white
            .withAlphaComponent(active ? 0.14 : 0.07).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        guard layer?.borderWidth == 0 else { return } // skip if selected
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.11).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        guard layer?.borderWidth == 0 else { return }
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
    }

    func setSelected(_ selected: Bool) {
        layer?.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
        layer?.borderWidth = selected ? 1.5 : 0
    }

    @objc func copySelf() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
    }

    @objc func deleteSelf() { ctrl?.delete(id: sectionId) }
}

// MARK: Text View Delegate

extension SectionCellView: NSTextViewDelegate {

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertTab(_:)) {
            ctrl?.focusSection(offset: +1, from: sectionId)
            return true
        }
        if selector == #selector(NSResponder.insertBacktab(_:)) {
            ctrl?.focusSection(offset: -1, from: sectionId)
            return true
        }
        return false
    }

    func textDidChange(_ notification: Notification) {
        textView.breakUndoCoalescing()
        textView.processLinks()
        ctrl?.update(id: sectionId, content: textView.string)
        ctrl?.refreshRowHeight(for: self)
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange,
                  replacementString string: String?) -> Bool {
        guard let s = string else { return true }
        let proposed = (textView.string as NSString).replacingCharacters(in: range, with: s)

        // Cursor position after insertion
        let cursorPos = range.location + s.count
        guard cursorPos >= 3 else { return true }

        let nsProposed = proposed as NSString
        let triggerRange = NSRange(location: cursorPos - 3, length: 3)
        guard nsProposed.substring(with: triggerRange) == "```" else { return true }

        let before = nsProposed.substring(to: triggerRange.location)
        let after  = nsProposed.substring(from: cursorPos)

        DispatchQueue.main.async {
            textView.string = before
            self.ctrl?.update(id: self.sectionId, content: before)
            self.ctrl?.split(id: self.sectionId, before: before, after: after)
        }
        return false
    }
}
