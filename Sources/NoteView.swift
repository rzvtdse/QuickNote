import AppKit

// MARK: - Custom Text View

class SectionTextView: NSTextView {
    var onFocus: (() -> Void)?
    var onBlur: (() -> Void)?

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
}

// MARK: - Model

struct NoteSection: Codable {
    var id: String
    var content: String
    init(content: String = "") { self.id = UUID().uuidString; self.content = content }
}

// MARK: - Controller

class SectionsController: NSObject {

    private var sections: [NoteSection] = []
    private var searchQuery: String = ""
    private var tableView: NSTableView!
    private var mergeButton: NSButton!
    private var selectedIds: Set<String> = []
    private var eventMonitor: Any?

    private static let pbType = NSPasteboard.PasteboardType("com.quicknote.section")

    private var filteredSections: [NoteSection] {
        guard !searchQuery.isEmpty else { return sections }
        return sections.filter { $0.content.localizedCaseInsensitiveContains(searchQuery) }
    }

    // MARK: Build UI

    func build(in parent: NSView) {
        load()
        if sections.isEmpty { sections = [NoteSection()] }

        // Search field
        let search = NSSearchField()
        search.translatesAutoresizingMaskIntoConstraints = false
        search.placeholderString = "Search..."
        search.controlSize = .small
        search.delegate = self
        parent.addSubview(search)

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

        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: parent.topAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -10),

            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -4),

            bottomStack.centerXAnchor.constraint(equalTo: parent.centerXAnchor),
            bottomStack.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -10),
        ])

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
        sections.append(NoteSection())
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
        sections.insert(NoteSection(content: after), at: idx + 1)
        save()
        tableView.reloadData()
        DispatchQueue.main.async {
            let newRow = idx + 1
            guard newRow < self.tableView.numberOfRows else { return }
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
        if sections.isEmpty { sections = [NoteSection()] }
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
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: "qn_sections_v1"),
              let saved = try? JSONDecoder().decode([NoteSection].self, from: data)
        else { return }
        sections = saved
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
              let fromIdx = sections.firstIndex(where: { $0.id == fromId }) else { return false }
        let moved = sections.remove(at: fromIdx)
        let toIdx = min(row > fromIdx ? row - 1 : row, sections.count)
        sections.insert(moved, at: toIdx)
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
        addSubview(textView)

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
