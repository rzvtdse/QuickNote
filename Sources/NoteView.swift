import AppKit

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

        // Add section button
        let addBtn = NSButton(title: "+ New Section", target: self, action: #selector(addSection))
        addBtn.translatesAutoresizingMaskIntoConstraints = false
        addBtn.isBordered = false
        addBtn.bezelStyle = .inline
        addBtn.font = NSFont.systemFont(ofSize: 11)
        addBtn.contentTintColor = NSColor.white.withAlphaComponent(0.4)
        parent.addSubview(addBtn)

        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: parent.topAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -10),

            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: addBtn.topAnchor, constant: -4),

            addBtn.centerXAnchor.constraint(equalTo: parent.centerXAnchor),
            addBtn.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -10),
        ])
    }

    // MARK: Section Operations

    @objc func addSection() {
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
        save()
    }

    func delete(id: String) {
        sections.removeAll { $0.id == id }
        if sections.isEmpty { sections = [NoteSection()] }
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

    private var textView: NSTextView!
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

        let del = NSButton(title: "×", target: self, action: #selector(deleteSelf))
        del.translatesAutoresizingMaskIntoConstraints = false
        del.isBordered = false
        del.bezelStyle = .inline
        del.font = NSFont.systemFont(ofSize: 15, weight: .light)
        del.contentTintColor = NSColor.white.withAlphaComponent(0.3)
        header.addSubview(del)

        // Text view
        textView = NSTextView()
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
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor.white.withAlphaComponent(0.2),
            .foregroundColor: NSColor.white,
        ]
        textView.string = section.content
        textView.delegate = self
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

            textView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    func focus() { textView?.window?.makeFirstResponder(textView) }

    @objc func deleteSelf() { ctrl?.delete(id: sectionId) }
}

// MARK: Text View Delegate

extension SectionCellView: NSTextViewDelegate {

    func textDidChange(_ notification: Notification) {
        ctrl?.update(id: sectionId, content: textView.string)
        ctrl?.refreshRowHeight(for: self)
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange,
                  replacementString string: String?) -> Bool {
        guard let s = string else { return true }
        let proposed = (textView.string as NSString).replacingCharacters(in: range, with: s)
        guard proposed.hasSuffix("```") else { return true }
        let before = String(proposed.dropLast(3))
        DispatchQueue.main.async {
            textView.string = before
            self.ctrl?.update(id: self.sectionId, content: before)
            self.ctrl?.split(id: self.sectionId, before: before, after: "")
        }
        return false
    }
}
