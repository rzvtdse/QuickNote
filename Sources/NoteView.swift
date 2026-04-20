import AppKit

// MARK: - Custom Text View

class SectionTextView: NSTextView, NSLayoutManagerDelegate {
    var onFocus: (() -> Void)?
    var onBlur: (() -> Void)?
    var onProgrammaticChange: (() -> Void)?
    /// Called after a direct storage modification (e.g. strikethrough toggle) so
    /// the cell view can persist the updated rich-text data.
    var onTextStorageChanged: (() -> Void)?

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

    // MARK: - Plain-text paste (no rich formatting imported)

    override func paste(_ sender: Any?) {
        guard let str = NSPasteboard.general.string(forType: .string) else { return }
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: str) else { return }
        textStorage?.replaceCharacters(in: range, with: str)
        setSelectedRange(NSRange(location: range.location + (str as NSString).length, length: 0))
        didChangeText()
    }

    // Strip everything except strikethrough (and internal link markers) from
    // the full storage, then re-apply the base font and colour.
    func stripFormattingExceptStrikethrough() {
        guard let storage = textStorage, storage.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        let keep: Set<NSAttributedString.Key> = [
            .strikethroughStyle,
            SectionTextView.linkKey, SectionTextView.toggleKey, SectionTextView.hiddenKey,
            .underlineStyle, .foregroundColor,   // re-set below; retained for links
        ]
        storage.beginEditing()
        storage.enumerateAttributes(in: fullRange, options: []) { attrs, subRange, _ in
            for key in attrs.keys where !keep.contains(key) {
                storage.removeAttribute(key, range: subRange)
            }
        }
        // Enforce base font and colour everywhere
        storage.addAttribute(.font,
                             value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                             range: fullRange)
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)
        storage.endEditing()
    }

    // MARK: - Strikethrough

    func toggleStrikethrough() {
        guard let storage = textStorage else { return }
        let range = selectedRange()
        guard range.length > 0 else { return }

        // Determine whether the entire selection already has strikethrough
        var allStruck = true
        storage.enumerateAttribute(.strikethroughStyle, in: range, options: []) { val, _, stop in
            let v = val as? Int ?? 0
            if v == 0 { allStruck = false; stop.pointee = true }
        }

        storage.beginEditing()
        if allStruck {
            storage.removeAttribute(.strikethroughStyle, range: range)
        } else {
            storage.addAttribute(.strikethroughStyle,
                                 value: NSUnderlineStyle.single.rawValue,
                                 range: range)
        }
        storage.endEditing()

        // Mirror the change in typing attributes so new characters follow suit
        var ta = typingAttributes
        if allStruck {
            ta.removeValue(forKey: .strikethroughStyle)
        } else {
            ta[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        typingAttributes = ta

        onTextStorageChanged?()
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

        // Single click on a checkbox character → toggle it
        if event.clickCount == 1, !event.modifierFlags.contains(.option) {
            for idx in candidates {
                guard idx < storage.length else { continue }
                let charRange = NSRange(location: idx, length: 1)
                let ch = (storage.string as NSString).substring(with: charRange)
                if ch == "☐" || ch == "☑" {
                    let replacement = ch == "☐" ? "☑" : "☐"
                    if shouldChangeText(in: charRange, replacementString: replacement) {
                        textStorage?.replaceCharacters(in: charRange, with: replacement)
                        didChangeText()
                    }
                    return
                }
            }
        }

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
    var rtfData: Data?          // rich-text blob; nil for plain-text-only sections
    init(content: String = "", bucketId: String? = nil) {
        self.id = UUID().uuidString
        self.content = content
        self.bucketId = bucketId
        self.rtfData = nil
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
    private var bucketHistory: [String] = []   // most-recent-last
    private var searchQuery: String = ""
    private var tableView: NSTableView!
    private var mergeButton: NSButton!
    private var undoSectionButton: NSButton!
    private var undoSectionTimer: Timer?
    private var searchField: NSSearchField!
    private var searchHeightConstraint: NSLayoutConstraint!
    private var bucketBar: BucketBarView!
    private var selectedIds: Set<String> = []
    private var deletedBucketStack: [(bucket: NoteBucket, sections: [NoteSection])] = []
    private var deletedSectionStack: [(section: NoteSection, index: Int)] = []
    private var eventMonitor: Any?
    private var keyMonitor: Any?
    private var lastKnownTableWidth: CGFloat = 0
    private weak var focusedTextView: SectionTextView?

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

        // Bucket tab bar — custom view does manual frame layout so tabs shrink to fit
        bucketBar = BucketBarView()
        bucketBar.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(bucketBar)

        // + button sits to the right of the tab bar, fixed size
        let addTabBtn = NSButton(title: "+", target: self, action: #selector(addBucket))
        addTabBtn.translatesAutoresizingMaskIntoConstraints = false
        addTabBtn.isBordered = false
        addTabBtn.bezelStyle = .inline
        addTabBtn.font = NSFont.systemFont(ofSize: 16, weight: .light)
        addTabBtn.contentTintColor = NSColor.white.withAlphaComponent(0.45)
        parent.addSubview(addTabBtn)

        // Search field (hidden until Cmd+F)
        searchField = NSSearchField()
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search…"
        searchField.controlSize = .regular
        searchField.delegate = self
        searchField.isHidden = true
        if let cell = searchField.cell as? NSSearchFieldCell {
            cell.searchButtonCell?.image = NSImage(systemSymbolName: "magnifyingglass",
                                                   accessibilityDescription: nil)
        }
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

        let addBtn = NSButton(title: "New Section", target: self, action: #selector(addSection))
        addBtn.translatesAutoresizingMaskIntoConstraints = false
        addBtn.isBordered = false
        addBtn.bezelStyle = .inline
        addBtn.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addBtn.imagePosition = .imageLeading
        addBtn.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        addBtn.contentTintColor = NSColor.secondaryLabelColor

        mergeButton = NSButton(title: "Merge", target: self, action: #selector(mergeSections))
        mergeButton.translatesAutoresizingMaskIntoConstraints = false
        mergeButton.isBordered = false
        mergeButton.bezelStyle = .inline
        mergeButton.image = NSImage(systemSymbolName: "arrow.triangle.merge", accessibilityDescription: nil)
        mergeButton.imagePosition = .imageLeading
        mergeButton.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        mergeButton.contentTintColor = NSColor.controlAccentColor
        mergeButton.isHidden = true

        undoSectionButton = NSButton(title: "Undo", target: self, action: #selector(undoDeleteSection))
        undoSectionButton.translatesAutoresizingMaskIntoConstraints = false
        undoSectionButton.isBordered = false
        undoSectionButton.bezelStyle = .inline
        undoSectionButton.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
        undoSectionButton.imagePosition = .imageLeading
        undoSectionButton.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        undoSectionButton.contentTintColor = NSColor.controlAccentColor
        undoSectionButton.isHidden = true

        let bottomStack = NSStackView(views: [addBtn, mergeButton, undoSectionButton])
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        bottomStack.orientation = .horizontal
        bottomStack.spacing = 16
        bottomStack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        parent.addSubview(bottomStack)

        searchHeightConstraint = searchField.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            addTabBtn.centerYAnchor.constraint(equalTo: bucketBar.centerYAnchor),
            addTabBtn.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -8),
            addTabBtn.widthAnchor.constraint(equalToConstant: 24),
            addTabBtn.heightAnchor.constraint(equalToConstant: 24),

            bucketBar.topAnchor.constraint(equalTo: parent.topAnchor, constant: 18),
            bucketBar.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 8),
            bucketBar.trailingAnchor.constraint(equalTo: addTabBtn.leadingAnchor, constant: -4),
            bucketBar.heightAnchor.constraint(equalToConstant: 28),

            searchField.topAnchor.constraint(equalTo: bucketBar.bottomAnchor, constant: 0),
            searchField.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -8),
            searchHeightConstraint,

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -8),

            bottomStack.centerXAnchor.constraint(equalTo: parent.centerXAnchor),
            bottomStack.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -10),
            bottomStack.heightAnchor.constraint(equalToConstant: 28),
        ])

        rebuildBucketBar()

        // Cmd+F to reveal search, Esc to dismiss it, Cmd+Shift+T to restore deleted bucket
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let ch = event.charactersIgnoringModifiers?.lowercased()
            // Cmd+N — new tab
            if flags == .command, ch == "n" {
                self.addBucket()
                return nil
            }
            // Cmd+F
            if flags == .command, ch == "f" {
                self.showSearch()
                return nil
            }
            // Cmd+Shift+T — restore last deleted bucket
            if flags == [.command, .shift], ch == "t" {
                self.restoreLastDeletedBucket()
                return nil
            }
            // Cmd+Shift+X — toggle strikethrough on selected text
            if flags == [.command, .shift], ch == "x" {
                self.focusedTextView?.toggleStrikethrough()
                return nil
            }
            // Option+Shift+T — restore last deleted section
            if flags == [.option, .shift], ch == "t" {
                self.restoreLastDeletedSection()
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

    func update(id: String, content: String, rtfData: Data? = nil) {
        guard let idx = sections.firstIndex(where: { $0.id == id }) else { return }
        sections[idx].content = content
        sections[idx].rtfData = rtfData
        rememberLastSection(id)
        save()
    }

    func trackFocus(_ tv: SectionTextView?) { focusedTextView = tv }

    /// Record focus so that this bucket resumes on this section next time it's activated.
    func rememberLastSection(_ id: String) {
        UserDefaults.standard.set(id, forKey: "qn_last_section")
        if let section = sections.first(where: { $0.id == id }), let bid = section.bucketId {
            UserDefaults.standard.set(id, forKey: "qn_last_section_\(bid)")
        }
    }

    func delete(id: String) {
        if let idx = sections.firstIndex(where: { $0.id == id }) {
            deletedSectionStack.append((section: sections[idx], index: idx))
            sections.remove(at: idx)
        }
        if !sections.contains(where: { $0.bucketId == activeBucketId }) {
            sections.append(NoteSection(bucketId: activeBucketId))
        }
        selectedIds.removeAll()
        tableView.reloadData()
        save()
        DispatchQueue.main.async { self.focusLastSection() }
        showUndoSectionButton()
    }

    func duplicate(id: String) {
        guard let idx = sections.firstIndex(where: { $0.id == id }) else { return }
        let original = sections[idx]
        var copy = NoteSection(content: original.content, bucketId: original.bucketId)
        copy.rtfData = original.rtfData
        sections.insert(copy, at: idx + 1)
        save()
        tableView.reloadData()
        // Focus the new duplicate
        DispatchQueue.main.async {
            let filtered = self.filteredSections
            if let row = filtered.firstIndex(where: { $0.id == copy.id }) {
                self.tableView.scrollRowToVisible(row)
                if let cell = self.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SectionCellView {
                    cell.focus()
                }
            }
        }
    }

    private func showUndoSectionButton() {
        undoSectionButton.isHidden = false
        undoSectionTimer?.invalidate()
        undoSectionTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            self?.undoSectionButton.isHidden = true
        }
    }

    @objc private func undoDeleteSection() {
        undoSectionTimer?.invalidate()
        undoSectionButton.isHidden = true
        restoreLastDeletedSection()
    }

    private func restoreLastDeletedSection() {
        guard let entry = deletedSectionStack.popLast() else { return }
        // If the section belonged to a bucket that still exists, restore there
        let targetBucket = entry.section.bucketId ?? activeBucketId
        guard buckets.contains(where: { $0.id == targetBucket }) else { return }
        let insertIdx = min(entry.index, sections.count)
        sections.insert(entry.section, at: insertIdx)
        save()
        // Switch to the bucket if needed
        if targetBucket != activeBucketId {
            bucketHistory.append(activeBucketId)
            activeBucketId = targetBucket
            UserDefaults.standard.set(activeBucketId, forKey: "qn_active_bucket")
            rebuildBucketBar()
        }
        tableView.reloadData()
        // Focus the restored section
        DispatchQueue.main.async {
            let filtered = self.filteredSections
            if let row = filtered.firstIndex(where: { $0.id == entry.section.id }) {
                self.tableView.scrollRowToVisible(row)
                if let cell = self.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SectionCellView {
                    cell.focus()
                }
            }
        }
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
        var tabs: [BucketTabView] = []
        for b in buckets {
            let tab = BucketTabView(bucketId: b.id, name: b.name)
            tab.isActive = (b.id == activeBucketId)
            tab.onClick = { [weak self] in self?.switchToBucket(b.id) }
            tab.onRename = { [weak self] newName in self?.renameBucket(id: b.id, to: newName) }
            tab.onRequestDelete = { [weak self] in self?.deleteBucket(id: b.id) }
            tab.onDidEndEditing = { [weak self] in self?.focusLastSection() }
            tabs.append(tab)
        }
        bucketBar.setTabs(tabs)
    }

    private func renameBucket(id: String, to newName: String) {
        guard let idx = buckets.firstIndex(where: { $0.id == id }) else { return }
        buckets[idx].name = newName
        save()
        rebuildBucketBar()
    }

    private func deleteBucket(id: String) {
        guard let idx = buckets.firstIndex(where: { $0.id == id }) else { return }
        // Don't allow deleting the last bucket
        guard buckets.count > 1 else { return }
        // Save to undo stack before removing
        let savedSections = sections.filter { $0.bucketId == id }
        deletedBucketStack.append((bucket: buckets[idx], sections: savedSections))
        let wasActive = (id == activeBucketId)
        sections.removeAll { $0.bucketId == id }
        buckets.remove(at: idx)
        bucketHistory.removeAll { $0 == id }
        if wasActive {
            // Switch to most recently used bucket that still exists
            let newActive = bucketHistory.last(where: { bid in buckets.contains { $0.id == bid } })
                ?? buckets[max(0, idx - 1)].id
            activeBucketId = newActive
            UserDefaults.standard.set(newActive, forKey: "qn_active_bucket")
        }
        save()
        // Rebuild the bar (deleted tab must disappear) then reload table
        rebuildBucketBar()
        selectedIds.removeAll()
        tableView.reloadData()
        updateSelectionUI()
        DispatchQueue.main.async { self.focusLastSection() }
    }

    private func restoreLastDeletedBucket() {
        guard let entry = deletedBucketStack.popLast() else { return }
        buckets.append(entry.bucket)
        // Restore sections; give them back the bucket id in case it was altered
        let restored = entry.sections.isEmpty
            ? [NoteSection(bucketId: entry.bucket.id)]
            : entry.sections
        sections.append(contentsOf: restored)
        save()
        // Set active id before rebuilding so the bar renders with the right tab highlighted
        activeBucketId = entry.bucket.id
        UserDefaults.standard.set(activeBucketId, forKey: "qn_active_bucket")
        rebuildBucketBar()
        selectedIds.removeAll()
        tableView.reloadData()
        updateSelectionUI()
        DispatchQueue.main.async { self.focusLastSection() }
    }

    private func switchToBucket(_ id: String) {
        if id == activeBucketId { return }
        bucketHistory.append(activeBucketId)
        activeBucketId = id
        UserDefaults.standard.set(id, forKey: "qn_active_bucket")
        selectedIds.removeAll()
        // Ensure bucket has at least one section
        if !sections.contains(where: { $0.bucketId == id }) {
            sections.append(NoteSection(bucketId: id))
            save()
        }
        // Update active state on existing tabs in place (don't destroy them
        // mid-click, otherwise double-click-to-rename never sees clickCount == 2)
        for tab in bucketBar.tabs {
            tab.isActive = (tab.bucketId == id)
        }
        tableView.reloadData()
        updateSelectionUI()
        DispatchQueue.main.async { self.focusLastSection() }
    }

    @objc private func addBucket() {
        let existingNames = Set(buckets.map { $0.name })
        var n = buckets.count + 1
        while existingNames.contains("Note \(n)") { n += 1 }
        let b = NoteBucket(name: "Note \(n)")
        buckets.append(b)
        bucketHistory.append(activeBucketId)
        activeBucketId = b.id
        UserDefaults.standard.set(b.id, forKey: "qn_active_bucket")
        if !sections.contains(where: { $0.bucketId == b.id }) {
            sections.append(NoteSection(bucketId: b.id))
        }
        save()
        rebuildBucketBar()
        tableView.reloadData()
        updateSelectionUI()
        DispatchQueue.main.async { self.focusLastSection() }
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
        let perBucketKey = "qn_last_section_\(activeBucketId)"
        let lastId = UserDefaults.standard.string(forKey: perBucketKey)
            ?? UserDefaults.standard.string(forKey: "qn_last_section")
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
    private var isInListMode = false

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
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor

        // Header bar — drag handle centred, buttons on the right
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        // Drag handle — three dots using SF Symbol
        let handleImg = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Drag")
        let handle = NSImageView(image: handleImg ?? NSImage())
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.contentTintColor = NSColor.tertiaryLabelColor
        handle.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        header.addSubview(handle)

        // Copy button
        let copy = NSButton(title: "", target: self, action: #selector(copySelf))
        copy.translatesAutoresizingMaskIntoConstraints = false
        copy.isBordered = false
        copy.bezelStyle = .inline
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        copy.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .light)
        copy.contentTintColor = NSColor.tertiaryLabelColor
        copy.toolTip = "Copy section"
        header.addSubview(copy)

        // Duplicate button
        let dup = NSButton(title: "", target: self, action: #selector(duplicateSelf))
        dup.translatesAutoresizingMaskIntoConstraints = false
        dup.isBordered = false
        dup.bezelStyle = .inline
        dup.image = NSImage(systemSymbolName: "plus.square.on.square", accessibilityDescription: "Duplicate")
        dup.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .light)
        dup.contentTintColor = NSColor.tertiaryLabelColor
        dup.toolTip = "Duplicate section"
        header.addSubview(dup)

        // Delete button
        let del = NSButton(title: "", target: self, action: #selector(deleteSelf))
        del.translatesAutoresizingMaskIntoConstraints = false
        del.isBordered = false
        del.bezelStyle = .inline
        del.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Delete")
        del.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
        del.contentTintColor = NSColor.tertiaryLabelColor
        header.addSubview(del)

        // Text view
        textView = SectionTextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isRichText = true            // required for strikethrough support
        textView.backgroundColor = .clear
        textView.textColor = NSColor.labelColor
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.insertionPointColor = NSColor.controlAccentColor
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                        height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.allowsUndo = true
        textView.installLayoutManagerDelegate()
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.25),
            .foregroundColor: NSColor.labelColor,
        ]
        // Load rich text if available, otherwise fall back to plain content
        if let rtf = section.rtfData,
           let attrStr = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            textView.textStorage?.setAttributedString(attrStr)
        } else {
            textView.string = section.content
        }
        // Ensure new typing uses the correct base font & colour
        textView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        // Restore list mode if the content already contains checklist items
        isInListMode = section.content
            .components(separatedBy: "\n")
            .contains { $0.hasPrefix("☐") || $0.hasPrefix("☑") }
        textView.delegate = self
        textView.onFocus = { [weak self] in
            guard let self = self else { return }
            self.ctrl?.rememberLastSection(self.sectionId)
            self.ctrl?.trackFocus(self.textView)
            self.setActive(true)
        }
        textView.onBlur = { [weak self] in
            self?.ctrl?.trackFocus(nil)
            self?.setActive(false)
        }
        textView.onProgrammaticChange = { [weak self] in
            guard let self = self else { return }
            self.ctrl?.update(id: self.sectionId, content: self.textView.string)
            self.ctrl?.refreshRowHeight(for: self)
        }
        // Persist after a direct storage change (e.g. strikethrough toggle)
        textView.onTextStorageChanged = { [weak self] in
            guard let self = self else { return }
            let len = self.textView.textStorage?.length ?? 0
            let rtf = len > 0
                ? self.textView.textStorage?.rtf(
                    from: NSRange(location: 0, length: len), documentAttributes: [:])
                : nil
            self.ctrl?.update(id: self.sectionId, content: self.textView.string, rtfData: rtf)
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
                storage.addAttribute(.backgroundColor,
                                     value: NSColor.systemYellow.withAlphaComponent(0.45), range: found)
                range = NSRange(location: found.upperBound, length: str.length - found.upperBound)
            }
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: SectionCellView.headerH),

            handle.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            handle.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            del.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            del.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            del.widthAnchor.constraint(equalToConstant: 14),
            del.heightAnchor.constraint(equalToConstant: 14),

            dup.trailingAnchor.constraint(equalTo: del.leadingAnchor, constant: -4),
            dup.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            dup.widthAnchor.constraint(equalToConstant: 14),
            dup.heightAnchor.constraint(equalToConstant: 14),

            copy.trailingAnchor.constraint(equalTo: dup.leadingAnchor, constant: -4),
            copy.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            copy.widthAnchor.constraint(equalToConstant: 14),
            copy.heightAnchor.constraint(equalToConstant: 14),

            textView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 0),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    func focus() { textView?.window?.makeFirstResponder(textView) }

    func setActive(_ active: Bool) {
        layer?.backgroundColor = NSColor.white
            .withAlphaComponent(active ? 0.18 : 0.06).cgColor
        layer?.borderColor = active
            ? NSColor.white.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor
        layer?.borderWidth = active ? 1 : 0
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
        guard layer?.borderWidth == 0 else { return }
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        guard layer?.borderWidth == 0 else { return }
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
    }

    func setSelected(_ selected: Bool) {
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
        layer?.borderWidth = selected ? 1.5 : 0
    }

    @objc func copySelf() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
    }

    @objc func duplicateSelf() { ctrl?.duplicate(id: sectionId) }
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

        // List mode: Enter → new unchecked item
        if selector == #selector(NSResponder.insertNewline(_:)), isInListMode {
            textView.insertText("\n☐ ", replacementRange: textView.selectedRange())
            return true
        }

        // List mode: Backspace on an empty list item → remove the checkbox prefix
        if selector == #selector(NSResponder.deleteBackward(_:)), isInListMode {
            let sel = textView.selectedRange()
            if sel.length == 0, sel.location >= 2 {
                let str = textView.string as NSString
                let preceding = str.substring(with: NSRange(location: sel.location - 2, length: 2))
                if preceding == "☐ " || preceding == "☑ " {
                    // Only remove if this checkbox is alone on its line
                    let atLineStart = sel.location == 2
                        || str.character(at: sel.location - 3) == 10  // '\n'
                    let atLineEnd   = sel.location == str.length
                        || str.character(at: sel.location) == 10
                    if atLineStart && atLineEnd {
                        let delRange = NSRange(location: sel.location - 2, length: 2)
                        if textView.shouldChangeText(in: delRange, replacementString: "") {
                            textView.textStorage?.replaceCharacters(in: delRange, with: "")
                            textView.didChangeText()
                        }
                        return true
                    }
                }
            }
        }

        return false
    }

    func textDidChange(_ notification: Notification) {
        textView.breakUndoCoalescing()
        // Strip any stray rich-text attributes (bold, different fonts, colours from
        // paste, etc.) while preserving strikethrough and link markers.
        textView.stripFormattingExceptStrikethrough()
        // Keep typing attributes clean so the next character is also formatless
        // (except for any active strikethrough the user has toggled).
        var ta = textView.typingAttributes
        ta[.font] = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        ta[.foregroundColor] = NSColor.labelColor
        textView.typingAttributes = ta
        textView.processLinks()
        let len = textView.textStorage?.length ?? 0
        let rtf = len > 0
            ? textView.textStorage?.rtf(
                from: NSRange(location: 0, length: len), documentAttributes: [:])
            : nil
        ctrl?.update(id: sectionId, content: textView.string, rtfData: rtf)
        ctrl?.refreshRowHeight(for: self)
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange,
                  replacementString string: String?) -> Bool {
        guard let s = string else { return true }
        let proposed = (textView.string as NSString).replacingCharacters(in: range, with: s)
        let cursorPos = range.location + s.count
        let nsProposed = proposed as NSString

        // ``` → split into a new section
        if cursorPos >= 3 {
            let tr = NSRange(location: cursorPos - 3, length: 3)
            if nsProposed.substring(with: tr) == "```" {
                let before = nsProposed.substring(to: tr.location)
                let after  = nsProposed.substring(from: cursorPos)
                DispatchQueue.main.async {
                    textView.string = before
                    self.ctrl?.update(id: self.sectionId, content: before)
                    self.ctrl?.split(id: self.sectionId, before: before, after: after)
                }
                return false
            }
        }

        // /list → start checklist
        if cursorPos >= 5 {
            let tr = NSRange(location: cursorPos - 5, length: 5)
            if nsProposed.substring(with: tr) == "/list" {
                let before = nsProposed.substring(to: tr.location)
                DispatchQueue.main.async {
                    let newText = before + "☐ "
                    textView.string = newText
                    textView.typingAttributes = [
                        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                        .foregroundColor: NSColor.labelColor,
                    ]
                    textView.setSelectedRange(NSRange(location: (newText as NSString).length, length: 0))
                    self.isInListMode = true
                    self.ctrl?.update(id: self.sectionId, content: newText)
                    self.ctrl?.refreshRowHeight(for: self)
                }
                return false
            }
        }

        // \list → end checklist
        if cursorPos >= 5 {
            let tr = NSRange(location: cursorPos - 5, length: 5)
            if nsProposed.substring(with: tr) == "\\list" {
                let before = nsProposed.substring(to: tr.location)
                DispatchQueue.main.async {
                    textView.string = before
                    textView.typingAttributes = [
                        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                        .foregroundColor: NSColor.labelColor,
                    ]
                    textView.setSelectedRange(NSRange(location: (before as NSString).length, length: 0))
                    self.isInListMode = false
                    self.ctrl?.update(id: self.sectionId, content: before)
                    self.ctrl?.refreshRowHeight(for: self)
                }
                return false
            }
        }

        return true
    }
}

// MARK: - Tab Bar (manual layout so tabs shrink to fit without fighting AutoLayout)

class BucketBarView: NSView {
    private(set) var tabs: [BucketTabView] = []
    var spacing: CGFloat = 4
    var maxTabWidth: CGFloat = 160

    func setTabs(_ newTabs: [BucketTabView]) {
        tabs.forEach { $0.removeFromSuperview() }
        tabs = newTabs
        tabs.forEach { addSubview($0) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard !tabs.isEmpty else { return }
        let n = CGFloat(tabs.count)
        let totalSpacing = spacing * (n - 1)
        let tabWidth = min(maxTabWidth, max(40, (bounds.width - totalSpacing) / n))
        var x: CGFloat = 0
        for tab in tabs {
            tab.frame = CGRect(x: x, y: 0, width: tabWidth, height: bounds.height)
            x += tabWidth + spacing
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - Chrome-style Bucket Tab

class BucketTabView: NSView, NSTextViewDelegate {
    let bucketId: String
    var name: String {
        didSet {
            label.stringValue = name
            if editView.string != name { editView.string = name }
            invalidateIntrinsicContentSize()
        }
    }
    var isActive: Bool = false { didSet { updateStyling() } }

    var onClick: (() -> Void)?
    var onRename: ((String) -> Void)?
    var onRequestDelete: (() -> Void)?
    var onDidEndEditing: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let editView = NSTextView()            // NSTextView handles its own key events
    private var editContainer: NSScrollView!
    private let closeButton = NSButton()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    init(bucketId: String, name: String) {
        self.bucketId = bucketId
        self.name = name
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.masksToBounds = true

        // Label (shown when not editing)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = name
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.55)
        label.lineBreakMode = .byTruncatingTail
        label.isSelectable = false
        addSubview(label)

        // Edit view — NSTextView so it handles its own key events (no shared field editor)
        editView.string = name
        editView.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        editView.textColor = .white
        editView.backgroundColor = .clear
        editView.drawsBackground = false
        editView.isEditable = true
        editView.isSelectable = true
        editView.isRichText = false
        editView.allowsUndo = false
        editView.focusRingType = .none
        editView.textContainerInset = NSSize(width: 2, height: 2)
        editView.textContainer?.lineFragmentPadding = 0
        editView.delegate = self

        // Wrap in a scroll view so Auto Layout can constrain it
        editContainer = NSScrollView()
        editContainer.translatesAutoresizingMaskIntoConstraints = false
        editContainer.documentView = editView
        editContainer.hasVerticalScroller = false
        editContainer.hasHorizontalScroller = false
        editContainer.borderType = .noBorder
        editContainer.backgroundColor = .clear
        editContainer.drawsBackground = false
        editContainer.isHidden = true
        addSubview(editContainer)

        // Close button — small circle with × , visible on hover/active
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.title = ""
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 7, weight: .semibold)
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.8)
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 7
        closeButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        closeButton.target = self
        closeButton.action = #selector(requestDelete)
        closeButton.alphaValue = 0
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),

            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            closeButton.heightAnchor.constraint(equalToConstant: 14),

            editContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            editContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            editContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            editContainer.heightAnchor.constraint(equalToConstant: 20),
        ])

        updateStyling()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: label.intrinsicContentSize.width + 42, height: 28)
    }

    // Prevent the window-background-drag from swallowing clicks on the tab
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Tracking / hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateStyling()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateStyling()
    }

    // MARK: Click / double-click

    override func mouseDown(with event: NSEvent) {
        // If we're already editing, pass through so NSTextView handles the click
        if !editContainer.isHidden { super.mouseDown(with: event); return }
        if event.clickCount >= 2 {
            beginEditing()
        } else {
            onClick?()
        }
    }

    // MARK: Styling — layer-based, no custom drawing

    private func updateStyling() {
        let alpha: CGFloat
        if isActive {
            alpha = 0.18
            label.textColor = .white
            label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        } else if isHovered {
            alpha = 0.09
            label.textColor = NSColor.white.withAlphaComponent(0.75)
            label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        } else {
            alpha = 0
            label.textColor = NSColor.white.withAlphaComponent(0.55)
            label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        }
        layer?.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
        closeButton.alphaValue = (isHovered || isActive) ? 1.0 : 0.0
    }

    // MARK: Inline rename

    func beginEditing() {
        guard editContainer.isHidden else { return }
        editView.string = name
        editContainer.isHidden = false
        label.isHidden = true
        // Defer focus so it wins any pending focusLastSection scheduled by the click
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.editContainer.isHidden else { return }
            self.window?.makeFirstResponder(self.editView)
            self.editView.selectAll(nil)
        }
    }

    private func commitEditing(cancel: Bool) {
        guard !editContainer.isHidden else { return }
        let newName = editView.string.trimmingCharacters(in: .whitespaces)
        editContainer.isHidden = true
        label.isHidden = false
        if cancel || newName.isEmpty {
            editView.string = name
        } else if newName != name {
            onRename?(newName)
        }
        updateStyling()
        DispatchQueue.main.async { self.onDidEndEditing?() }
    }

    // NSTextViewDelegate — handle Enter and Escape
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            commitEditing(cancel: false)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            commitEditing(cancel: true)
            return true
        }
        return false
    }

    func textDidEndEditing(_ notification: Notification) {
        commitEditing(cancel: false)
    }

    @objc private func requestDelete() { onRequestDelete?() }
}
