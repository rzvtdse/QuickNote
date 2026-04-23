import AppKit

// MARK: - Custom Text View

class SectionTextView: NSTextView, NSLayoutManagerDelegate {
    var onFocus: (() -> Void)?
    var onBlur: (() -> Void)?
    var onProgrammaticChange: (() -> Void)?
    /// Called after a direct storage modification (e.g. strikethrough toggle) so
    /// the cell view can persist the updated rich-text data.
    var onTextStorageChanged: (() -> Void)?
    /// Tracks whether this text view is currently in checklist mode.
    var isInListMode = false
    /// Set to true during batch programmatic insertions to prevent breakUndoCoalescing
    /// from fragmenting the undo stack across multiple insertText calls.
    var suppressBreakUndoCoalescing = false

    private var isProcessingLinks = false
    fileprivate static let linkKey     = NSAttributedString.Key("QNLink")
    private static let linkDetector: NSDataDetector? = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    fileprivate static let toggleKey   = NSAttributedString.Key("QNToggle")
    fileprivate static let hiddenKey   = NSAttributedString.Key("QNHidden")
    fileprivate static let checkboxKey = NSAttributedString.Key("QNCheckbox")

    private static let uncheckedImage: NSImage? = {
        let base = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let color = NSImage.SymbolConfiguration(hierarchicalColor: NSColor.white.withAlphaComponent(0.4))
        return NSImage(systemSymbolName: "circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(base.applying(color))
    }()

    private static let checkedImage: NSImage? = {
        let base = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let color = NSImage.SymbolConfiguration(hierarchicalColor: NSColor.white)
        return NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(base.applying(color))
    }()

    /// Builds an NSAttributedString containing a single SF-Symbol checkbox attachment.
    static func checkboxAttrStr(checked: Bool) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = checked ? checkedImage : uncheckedImage
        // y offset nudges the icon to sit on the text baseline nicely
        attachment.bounds = CGRect(x: 0, y: -2.5, width: 14, height: 14)
        let str = NSMutableAttributedString(attachment: attachment)
        str.addAttribute(checkboxKey, value: checked ? "checked" : "unchecked",
                         range: NSRange(location: 0, length: 1))
        return str
    }

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

    // Strip everything except strikethrough, link markers, and checkbox attachments
    // from the full storage, then re-apply the base font and colour to non-attachment runs.
    func stripFormattingExceptStrikethrough() {
        guard let storage = textStorage, storage.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        let keep: Set<NSAttributedString.Key> = [
            .strikethroughStyle,
            .attachment, SectionTextView.checkboxKey,          // checkbox SF-Symbol icons
            SectionTextView.linkKey, SectionTextView.toggleKey, SectionTextView.hiddenKey,
            .underlineStyle, .foregroundColor,                 // re-set below; retained for links
        ]
        storage.beginEditing()
        storage.enumerateAttributes(in: fullRange, options: []) { attrs, subRange, _ in
            for key in attrs.keys where !keep.contains(key) {
                storage.removeAttribute(key, range: subRange)
            }
        }
        // Enforce base font and colour on plain-text runs only (skip attachment characters)
        storage.enumerateAttribute(.attachment, in: fullRange, options: []) { val, range, _ in
            guard val == nil else { return }    // skip attachment chars
            storage.addAttribute(.font,
                                 value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                                 range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
        }
        storage.endEditing()
    }

    // MARK: - Checkbox serialization helpers

    /// Returns the text content with checkbox SF Symbol attachments replaced by ☐/☑ plain chars.
    /// Use this instead of `string` when saving the `content` field so it can be searched
    /// and round-tripped on load.
    func plainTextForStorage() -> String {
        guard let storage = textStorage, storage.length > 0 else { return string }
        let nsStr = storage.string as NSString
        var result = ""
        var lastEnd = 0
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(SectionTextView.checkboxKey, in: fullRange, options: []) { val, range, _ in
            if range.location > lastEnd {
                result += nsStr.substring(with: NSRange(location: lastEnd,
                                                         length: range.location - lastEnd))
            }
            result += (val as? String) == "checked" ? "☑" : "☐"
            lastEnd = range.upperBound
        }
        if lastEnd < storage.length {
            result += nsStr.substring(with: NSRange(location: lastEnd,
                                                     length: storage.length - lastEnd))
        }
        return result
    }

    /// Returns RTF data with checkbox attachments replaced by ☐/☑ text chars (preserves
    /// strikethrough). On load, ☐/☑ chars are converted back to SF Symbol attachments via
    /// `convertTextCheckboxesToAttachments()`.
    func rtfDataForStorage() -> Data? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let copy = NSMutableAttributedString(attributedString: storage)
        // Walk backwards so index replacements don't shift pending positions
        var i = copy.length - 1
        while i >= 0 {
            if let state = copy.attribute(SectionTextView.checkboxKey,
                                           at: i, effectiveRange: nil) as? String {
                let char = state == "checked" ? "☑" : "☐"
                copy.replaceCharacters(in: NSRange(location: i, length: 1),
                                       with: NSAttributedString(string: char, attributes: [
                                           .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                                           .foregroundColor: NSColor.labelColor,
                                       ]))
            }
            i -= 1
        }
        return copy.rtf(from: NSRange(location: 0, length: copy.length), documentAttributes: [:])
    }

    /// Converts ☐ (U+2610) and ☑ (U+2611) plain chars in the text storage to SF Symbol
    /// checkbox attachments. Call after loading RTF that was saved with `rtfDataForStorage()`.
    func convertTextCheckboxesToAttachments() {
        guard let storage = textStorage, storage.length > 0 else { return }
        var i = storage.length - 1
        while i >= 0 {
            let ch = (storage.string as NSString).character(at: i)
            if ch == 0x2610 || ch == 0x2611 { // ☐ or ☑
                let attrStr = SectionTextView.checkboxAttrStr(checked: ch == 0x2611)
                storage.beginEditing()
                storage.replaceCharacters(in: NSRange(location: i, length: 1), with: attrStr)
                storage.endEditing()
            }
            i -= 1
        }
    }

    /// For old-format RTF data: any NSTextAttachment that lacks the QNCheckbox attribute is
    /// treated as an (unchecked) checkbox and replaced with our SF Symbol attachment.
    /// Called when loading old saves where attachments were stored as raw TIFF images.
    func reMarkCheckboxAttachments() {
        guard let storage = textStorage, storage.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        var positions: [Int] = []
        storage.enumerateAttribute(.attachment, in: fullRange, options: []) { val, range, _ in
            guard val != nil else { return }
            if storage.attribute(SectionTextView.checkboxKey,
                                 at: range.location, effectiveRange: nil) == nil {
                positions.append(range.location)
            }
        }
        for i in positions.reversed() {
            let attrStr = SectionTextView.checkboxAttrStr(checked: false)
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: i, length: 1), with: attrStr)
            storage.endEditing()
        }
    }

    // MARK: - List mode

    func activateListMode() {
        guard let storage = textStorage else { return }
        let range = selectedRange()
        let insertion = NSMutableAttributedString(
            attributedString: SectionTextView.checkboxAttrStr(checked: false))
        insertion.append(NSAttributedString(string: " ", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]))
        if shouldChangeText(in: range, replacementString: insertion.string) {
            storage.replaceCharacters(in: range, with: insertion)
            setSelectedRange(NSRange(location: range.location + (insertion.string as NSString).length,
                                     length: 0))
            didChangeText()
        }
        isInListMode = true
    }

    /// Converts every non-empty line covered by the current selection into a checklist item.
    func convertSelectionToList() {
        guard let storage = textStorage else { return }
        let sel = selectedRange()
        let nsStr = storage.string as NSString

        // Expand to full lines
        let fullLineRange = nsStr.lineRange(for: sel)

        // Collect individual line ranges (walk forward)
        var lineRanges: [NSRange] = []
        var pos = fullLineRange.location
        while pos < NSMaxRange(fullLineRange) {
            let lr = nsStr.lineRange(for: NSRange(location: pos, length: 0))
            lineRanges.append(lr)
            if lr.length == 0 { break }
            pos = NSMaxRange(lr)
        }

        let spacer = NSAttributedString(string: " ", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])

        // Suppress per-keystroke undo coalescing breaks so all insertions
        // land in one undo group and Cmd+Z reverts the whole conversion at once.
        breakUndoCoalescing()
        suppressBreakUndoCoalescing = true
        undoManager?.beginUndoGrouping()
        // defer guarantees cleanup even if something goes wrong mid-loop
        defer {
            undoManager?.endUndoGrouping()
            suppressBreakUndoCoalescing = false
        }
        // Insert checkboxes backwards so earlier indices stay valid
        for lineRange in lineRanges.reversed() {
            // Skip blank lines
            let content = nsStr.substring(with: lineRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            // Skip lines that already start with a checkbox
            if storage.attribute(SectionTextView.checkboxKey,
                                 at: lineRange.location, effectiveRange: nil) != nil { continue }
            let insertion = NSMutableAttributedString(
                attributedString: SectionTextView.checkboxAttrStr(checked: false))
            insertion.append(spacer)
            // insertText goes through the proper undo registration path
            insertText(insertion, replacementRange: NSRange(location: lineRange.location, length: 0))
        }
        isInListMode = true
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
              let detector = SectionTextView.linkDetector
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

    // MARK: - Rich Content Check

    func hasRichContent() -> Bool {
        guard let storage = textStorage, storage.length > 0 else { return false }
        var found = false
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length), options: .longestEffectiveRangeNotRequired) { attrs, _, stop in
            if attrs[SectionTextView.checkboxKey] != nil || attrs[.strikethroughStyle] != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
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

        // Single click on a checkbox attachment → toggle checked state
        if event.clickCount == 1, !event.modifierFlags.contains(.option) {
            for idx in candidates {
                guard idx < storage.length else { continue }
                if let state = storage.attribute(SectionTextView.checkboxKey,
                                                  at: idx, effectiveRange: nil) as? String {
                    let nowChecked = (state != "checked")
                    let newAttachment = SectionTextView.checkboxAttrStr(checked: nowChecked)
                    storage.beginEditing()
                    storage.replaceCharacters(in: NSRange(location: idx, length: 1),
                                              with: newAttachment)
                    storage.endEditing()
                    onTextStorageChanged?()
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

// MARK: - Backup

struct QuickNoteBackup: Codable {
    let version: Int
    let buckets: [NoteBucket]
    let sections: [NoteSection]
}

// MARK: - Model

struct NoteSection: Codable {
    var id: String
    var content: String
    var bucketId: String?
    var rtfData: Data?          // rich-text blob; nil for plain-text-only sections
    var isCollapsed: Bool = false
    var lastModified: Date = Date()
    var isPinned: Bool = false

    init(content: String = "", bucketId: String? = nil) {
        self.id = UUID().uuidString
        self.content = content
        self.bucketId = bucketId
        self.rtfData = nil
    }

    // Custom decoder so old saved data without new fields still loads
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id           = try c.decode(String.self, forKey: .id)
        content      = try c.decode(String.self, forKey: .content)
        bucketId     = try c.decodeIfPresent(String.self, forKey: .bucketId)
        rtfData      = try c.decodeIfPresent(Data.self, forKey: .rtfData)
        isCollapsed  = (try? c.decodeIfPresent(Bool.self, forKey: .isCollapsed)) ?? false
        lastModified = (try? c.decodeIfPresent(Date.self, forKey: .lastModified)) ?? Date()
        isPinned     = (try? c.decodeIfPresent(Bool.self, forKey: .isPinned)) ?? false
    }
}

struct NoteBucket: Codable {
    var id: String
    var name: String
    init(name: String) { self.id = UUID().uuidString; self.name = name }
    init(id: String, name: String) { self.id = id; self.name = name }
}

extension NoteSection {
    init(id: String, content: String, bucketId: String?, rtfData: Data?) {
        self.id = id; self.content = content; self.bucketId = bucketId; self.rtfData = rtfData
    }
}

// MARK: - Controller

class SectionsController: NSObject {

    private var sections: [NoteSection] = []
    private var buckets: [NoteBucket] = []
    private var activeBucketId: String = ""
    private var bucketHistory: [String] = []   // most-recent-last
    private var searchQuery: String = ""
    private var tableView: NSTableView!
    private var pinnedTableView: NSTableView!
    private var pinnedScrollView: NSScrollView!
    private var pinnedHeightConstraint: NSLayoutConstraint!
    private var mergeButton: HoverButton!
    private var undoSectionButton: HoverButton!
    private var undoSectionTimer: Timer?
    private var frameChangeDebounce: Timer?
    private var searchField: NSSearchField!
    private var searchHeightConstraint: NSLayoutConstraint!
    private var bucketBar: BucketBarView!
    private var selectedIds: Set<String> = []
    private var deletedBucketStack: [(bucket: NoteBucket, sections: [NoteSection])] = []
    private var deletedSectionStack: [(section: NoteSection, index: Int)] = []
    private var eventMonitor: Any?
    private var keyMonitor: Any?
    private var lastKnownTableWidth: CGFloat = 0
    private var searchDebounce: Timer?
    private weak var focusedTextView: SectionTextView?

    static let pbType = NSPasteboard.PasteboardType("com.quicknote.section")

    /// Pinned sections in the active bucket, filtered by search query.
    private var filteredPinnedSections: [NoteSection] {
        let inBucket = sections.filter { ($0.bucketId ?? "") == activeBucketId && $0.isPinned }
        guard !searchQuery.isEmpty else { return inBucket }
        return inBucket.filter { $0.content.localizedCaseInsensitiveContains(searchQuery) }
    }

    /// Unpinned sections in the active bucket, filtered by search query.
    private var filteredUnpinnedSections: [NoteSection] {
        let inBucket = sections.filter { ($0.bucketId ?? "") == activeBucketId && !$0.isPinned }
        guard !searchQuery.isEmpty else { return inBucket }
        return inBucket.filter { $0.content.localizedCaseInsensitiveContains(searchQuery) }
    }

    /// Alias for filteredUnpinnedSections — keeps existing call sites working.
    private var filteredSections: [NoteSection] { filteredUnpinnedSections }

    // MARK: Build UI

    func build(in parent: NSView) {
        load()
        ensureDefaultBucket()

        // Bucket tab bar — custom view does manual frame layout so tabs shrink to fit
        bucketBar = BucketBarView()
        bucketBar.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(bucketBar)

        // Export / Import icon buttons — top-right corner, icon-only
        let exportBtn = HoverButton(title: "", target: self, action: #selector(exportNotes))
        exportBtn.translatesAutoresizingMaskIntoConstraints = false
        exportBtn.isBordered = false
        exportBtn.bezelStyle = .inline
        exportBtn.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export")
        exportBtn.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        exportBtn.dimColor = NSColor.white.withAlphaComponent(0.40)
        exportBtn.hoverColor = NSColor.white.withAlphaComponent(0.90)
        exportBtn.toolTip = "Export notes"
        parent.addSubview(exportBtn)

        let importBtn = HoverButton(title: "", target: self, action: #selector(importNotes))
        importBtn.translatesAutoresizingMaskIntoConstraints = false
        importBtn.isBordered = false
        importBtn.bezelStyle = .inline
        importBtn.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Import")
        importBtn.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        importBtn.dimColor = NSColor.white.withAlphaComponent(0.40)
        importBtn.hoverColor = NSColor.white.withAlphaComponent(0.90)
        importBtn.toolTip = "Import notes"
        parent.addSubview(importBtn)

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
        // Also observe the pinned table so pinned height updates when width changes

        // Pinned table — sits above the scroll view, shows full height (no scroll)
        pinnedTableView = NSTableView()
        pinnedTableView.backgroundColor = .clear
        pinnedTableView.headerView = nil
        pinnedTableView.intercellSpacing = NSSize(width: 0, height: 8)
        pinnedTableView.selectionHighlightStyle = .none
        pinnedTableView.allowsEmptySelection = true
        pinnedTableView.gridStyleMask = []
        if #available(macOS 11, *) { pinnedTableView.style = .plain }

        let pinnedCol = NSTableColumn(identifier: .init("pinnedCol"))
        pinnedCol.resizingMask = .autoresizingMask
        pinnedTableView.addTableColumn(pinnedCol)
        pinnedTableView.dataSource = self
        pinnedTableView.delegate = self
        pinnedTableView.registerForDraggedTypes([SectionsController.pbType])
        pinnedTableView.setDraggingSourceOperationMask(.move, forLocal: true)
        pinnedScrollView = NSScrollView()
        pinnedScrollView.translatesAutoresizingMaskIntoConstraints = false
        pinnedScrollView.documentView = pinnedTableView
        pinnedScrollView.drawsBackground = false
        pinnedScrollView.hasVerticalScroller = false
        pinnedScrollView.hasHorizontalScroller = false
        pinnedScrollView.borderType = .noBorder
        pinnedScrollView.contentView.wantsLayer = true
        pinnedScrollView.contentView.layer?.masksToBounds = false
        parent.addSubview(pinnedScrollView)


        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = tableView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        parent.addSubview(scroll)

        let addBtn = HoverButton(title: "New Section", target: self, action: #selector(addSection))
        addBtn.translatesAutoresizingMaskIntoConstraints = false
        addBtn.isBordered = false
        addBtn.bezelStyle = .inline
        addBtn.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addBtn.imagePosition = .imageLeading
        addBtn.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        addBtn.dimColor = NSColor.secondaryLabelColor
        addBtn.hoverColor = NSColor.labelColor.withAlphaComponent(0.85)

        mergeButton = HoverButton(title: "Merge", target: self, action: #selector(mergeSections))
        mergeButton.translatesAutoresizingMaskIntoConstraints = false
        mergeButton.isBordered = false
        mergeButton.bezelStyle = .inline
        mergeButton.image = NSImage(systemSymbolName: "arrow.triangle.merge", accessibilityDescription: nil)
        mergeButton.imagePosition = .imageLeading
        mergeButton.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        mergeButton.dimColor = NSColor.controlAccentColor
        mergeButton.hoverColor = NSColor.controlAccentColor.withAlphaComponent(0.7)
        mergeButton.isHidden = true

        undoSectionButton = HoverButton(title: "Undo", target: self, action: #selector(undoDeleteSection))
        undoSectionButton.translatesAutoresizingMaskIntoConstraints = false
        undoSectionButton.isBordered = false
        undoSectionButton.bezelStyle = .inline
        undoSectionButton.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
        undoSectionButton.imagePosition = .imageLeading
        undoSectionButton.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        undoSectionButton.dimColor = NSColor.controlAccentColor
        undoSectionButton.hoverColor = NSColor.controlAccentColor.withAlphaComponent(0.7)
        undoSectionButton.isHidden = true

        let bottomStack = NSStackView(views: [addBtn, mergeButton, undoSectionButton])
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        bottomStack.orientation = .horizontal
        bottomStack.spacing = 16
        bottomStack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        parent.addSubview(bottomStack)

        searchHeightConstraint = searchField.heightAnchor.constraint(equalToConstant: 0)
        pinnedHeightConstraint = pinnedScrollView.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            importBtn.centerYAnchor.constraint(equalTo: bucketBar.centerYAnchor),
            importBtn.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -8),
            importBtn.widthAnchor.constraint(equalToConstant: 20),
            importBtn.heightAnchor.constraint(equalToConstant: 20),

            exportBtn.centerYAnchor.constraint(equalTo: bucketBar.centerYAnchor),
            exportBtn.trailingAnchor.constraint(equalTo: importBtn.leadingAnchor, constant: -6),
            exportBtn.widthAnchor.constraint(equalToConstant: 20),
            exportBtn.heightAnchor.constraint(equalToConstant: 20),

            bucketBar.topAnchor.constraint(equalTo: parent.topAnchor, constant: 18),
            bucketBar.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 8),
            bucketBar.trailingAnchor.constraint(equalTo: exportBtn.leadingAnchor, constant: -6),
            bucketBar.heightAnchor.constraint(equalToConstant: 28),

            searchField.topAnchor.constraint(equalTo: bucketBar.bottomAnchor, constant: 0),
            searchField.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -8),
            searchHeightConstraint,

            pinnedScrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            pinnedScrollView.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 8),
            pinnedScrollView.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -8),
            pinnedHeightConstraint,

            scroll.topAnchor.constraint(equalTo: pinnedScrollView.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -8),

            bottomStack.centerXAnchor.constraint(equalTo: parent.centerXAnchor),
            bottomStack.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -10),
            bottomStack.heightAnchor.constraint(equalToConstant: 28),
        ])

        bucketBar.onReorder = { [weak self] from, to in
            self?.reorderBucket(from: from, to: to)
        }
        bucketBar.onAddTab = { [weak self] in self?.addBucket() }

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
            // Cmd+Option+L — start a checklist, or convert selected lines to checklist items
            if flags == [.command, .option], ch == "l" {
                if let tv = self.focusedTextView {
                    if tv.selectedRange().length > 0 {
                        tv.convertSelectionToList()
                    } else {
                        tv.activateListMode()
                    }
                }
                return nil
            }
            // Option+Shift+T — restore last deleted section
            if flags == [.option, .shift], ch == "t" {
                self.restoreLastDeletedSection()
                return nil
            }
            // Cmd+1…9 — switch to nth tab
            if flags == .command, let ch, let digit = Int(ch), digit >= 1 && digit <= 9 {
                let idx = digit - 1
                if idx < self.buckets.count {
                    self.switchToBucket(self.buckets[idx].id)
                }
                return nil
            }
            // Escape while search is focused
            if event.keyCode == 53, self.searchField.currentEditor() != nil {
                self.hideSearch()
                return nil
            }
            return event
        }

        // Cmd+click monitor for multi-select (handles both main and pinned tables)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self else { return event }
            // Check main table
            let pt = self.tableView.convert(event.locationInWindow, from: nil)
            let row = self.tableView.row(at: pt)
            // Check pinned table
            let pinnedPt = self.pinnedTableView.convert(event.locationInWindow, from: nil)
            let pinnedRow = self.pinnedTableView.row(at: pinnedPt)

            if event.modifierFlags.contains(.command) {
                if row >= 0, row < self.filteredSections.count {
                    let id = self.filteredSections[row].id
                    if self.selectedIds.contains(id) { self.selectedIds.remove(id) }
                    else { self.selectedIds.insert(id) }
                    self.updateSelectionUI()
                    return nil
                } else if pinnedRow >= 0, pinnedRow < self.filteredPinnedSections.count {
                    let id = self.filteredPinnedSections[pinnedRow].id
                    if self.selectedIds.contains(id) { self.selectedIds.remove(id) }
                    else { self.selectedIds.insert(id) }
                    self.updateSelectionUI()
                    return nil
                }
            } else if !self.selectedIds.isEmpty {
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
        reloadAllSections()
        searchField.isHidden = true
        searchHeightConstraint.isActive = true
        focusLastSection()
    }

    @objc func tableFrameChanged() {
        frameChangeDebounce?.invalidate()
        frameChangeDebounce = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                self.tableView.noteHeightOfRows(withIndexesChanged:
                    IndexSet(integersIn: 0..<self.tableView.numberOfRows))
                self.pinnedTableView.noteHeightOfRows(withIndexesChanged:
                    IndexSet(integersIn: 0..<self.pinnedTableView.numberOfRows))
            }
            self.updatePinnedHeight()
        }
    }

    // MARK: Selection

    func updateSelectionUI() {
        for row in 0..<tableView.numberOfRows {
            guard row < filteredSections.count else { continue }
            (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SectionCellView)?
                .setSelected(selectedIds.contains(filteredSections[row].id))
        }
        for row in 0..<pinnedTableView.numberOfRows {
            guard row < filteredPinnedSections.count else { continue }
            (pinnedTableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SectionCellView)?
                .setSelected(selectedIds.contains(filteredPinnedSections[row].id))
        }
        mergeButton.isHidden = selectedIds.count < 2
    }

    @objc func mergeSections() {
        // Merge from both pinned and unpinned selections
        let allFiltered = filteredPinnedSections + filteredSections
        let ordered = allFiltered.filter { selectedIds.contains($0.id) }
        guard ordered.count >= 2 else { return }
        let merged = ordered.map { $0.content }.joined(separator: "\n\n")
        let firstId = ordered[0].id
        let removeIds = Set(ordered.dropFirst().map { $0.id })
        if let idx = sections.firstIndex(where: { $0.id == firstId }) {
            sections[idx].content = merged
        }
        sections.removeAll { removeIds.contains($0.id) }
        selectedIds.removeAll()
        reloadAllSections()
        updateSelectionUI()
        save()
    }

    // MARK: Section Operations

    @objc func addSection() {
        selectedIds.removeAll()
        sections.append(NoteSection(bucketId: activeBucketId))
        reloadAllSections()
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
        reloadAllSections()
        let newSectionId = newSection.id
        DispatchQueue.main.async {
            guard let newRow = self.filteredSections.firstIndex(where: { $0.id == newSectionId }) else { return }
            self.tableView.scrollRowToVisible(newRow)
            (self.tableView.view(atColumn: 0, row: newRow, makeIfNecessary: false) as? SectionCellView)?.focus()
        }
    }

    func toggleCollapse(id: String) {
        guard let idx = sections.firstIndex(where: { $0.id == id }) else { return }
        sections[idx].isCollapsed.toggle()
        save()
        let collapsed = sections[idx].isCollapsed
        // Update cell immediately in whichever table it's in, then animate row height
        if let row = filteredPinnedSections.firstIndex(where: { $0.id == id }),
           let cell = pinnedTableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SectionCellView {
            cell.applyCollapsed(collapsed)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.allowsImplicitAnimation = true
                self.pinnedTableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<self.pinnedTableView.numberOfRows))
            }
            updatePinnedHeight()
        } else if let row = filteredSections.firstIndex(where: { $0.id == id }),
                  let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SectionCellView {
            cell.applyCollapsed(collapsed)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.allowsImplicitAnimation = true
                self.tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<self.tableView.numberOfRows))
            }
        }
    }

    func update(id: String, content: String, rtfData: Data? = nil) {
        guard let idx = sections.firstIndex(where: { $0.id == id }) else { return }
        sections[idx].content = content
        sections[idx].rtfData = rtfData
        sections[idx].lastModified = Date()
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
        reloadAllSections()
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
        reloadAllSections()
        // Focus the new duplicate (duplicates are unpinned so look in main table)
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
        reloadAllSections()
        // Focus the restored section — check both tables
        DispatchQueue.main.async {
            if let row = self.filteredPinnedSections.firstIndex(where: { $0.id == entry.section.id }) {
                if let cell = self.pinnedTableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SectionCellView {
                    cell.focus()
                }
            } else {
                let filtered = self.filteredSections
                if let row = filtered.firstIndex(where: { $0.id == entry.section.id }) {
                    self.tableView.scrollRowToVisible(row)
                    if let cell = self.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SectionCellView {
                        cell.focus()
                    }
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

    func refreshRowHeightForSection(id: String) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            self.tableView.noteHeightOfRows(withIndexesChanged:
                IndexSet(integersIn: 0..<self.tableView.numberOfRows))
            self.pinnedTableView.noteHeightOfRows(withIndexesChanged:
                IndexSet(integersIn: 0..<self.pinnedTableView.numberOfRows))
        }
        updatePinnedHeight()
    }

    // MARK: Pin

    func togglePin(id: String) {
        guard let idx = sections.firstIndex(where: { $0.id == id }) else { return }
        sections[idx].isPinned.toggle()
        save()
        reloadAllSections()
    }

    func reloadAllSections() {
        tableView.reloadData()
        pinnedTableView.reloadData()
        updatePinnedHeight()
    }

    private func updatePinnedHeight() {
        let w = max(100, tableView.bounds.width - 8)
        let spacing: CGFloat = 8
        let bottomPadding: CGFloat = 6   // room for rounded corners of last cell
        let total = filteredPinnedSections.reduce(CGFloat(0)) { sum, s in
            sum + SectionCellView.rowHeight(content: s.content, width: w) + spacing
        }
        pinnedHeightConstraint.constant = total > 0 ? total - spacing + bottomPadding : 0
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
            tab.onRequestDuplicate = { [weak self] in self?.duplicateBucket(id: b.id) }
            tab.onDidEndEditing = { [weak self] in self?.focusLastSection() }
            tab.onReceiveDrop = { [weak self] sectionId in
                guard let self,
                      let idx = self.sections.firstIndex(where: { $0.id == sectionId }),
                      self.sections[idx].bucketId != b.id else { return false }
                self.sections[idx].bucketId = b.id
                self.save()
                self.switchToBucket(b.id)
                return true
            }
            tabs.append(tab)
        }
        bucketBar.setTabs(tabs)
    }

    private func reorderBucket(from fromIndex: Int, to toIndex: Int) {
        guard fromIndex != toIndex,
              fromIndex < buckets.count,
              toIndex < buckets.count else { return }
        let moved = buckets.remove(at: fromIndex)
        buckets.insert(moved, at: toIndex)
        save()
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
        reloadAllSections()
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
        reloadAllSections()
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
        reloadAllSections()
        updateSelectionUI()
        DispatchQueue.main.async { self.focusLastSection() }
    }

    private func duplicateBucket(id: String) {
        guard let idx = buckets.firstIndex(where: { $0.id == id }) else { return }
        let source = buckets[idx]
        let newBucket = NoteBucket(name: source.name + " copy")
        // Insert right after the source tab
        buckets.insert(newBucket, at: idx + 1)
        // Deep-copy all sections belonging to the source tab
        let sourceSections = sections.filter { $0.bucketId == source.id }
        let copies = sourceSections.map { s -> NoteSection in
            var copy = NoteSection(content: s.content, bucketId: newBucket.id)
            copy.rtfData = s.rtfData
            return copy
        }
        // Insert copies after the last section of the source tab
        if let lastIdx = sections.lastIndex(where: { $0.bucketId == source.id }) {
            sections.insert(contentsOf: copies, at: lastIdx + 1)
        } else {
            sections.append(contentsOf: copies)
        }
        // If no sections were copied, add a blank one
        if copies.isEmpty { sections.append(NoteSection(bucketId: newBucket.id)) }
        bucketHistory.append(activeBucketId)
        activeBucketId = newBucket.id
        UserDefaults.standard.set(newBucket.id, forKey: "qn_active_bucket")
        save()
        rebuildBucketBar()
        reloadAllSections()
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
        reloadAllSections()
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
        let row = target ?? (filteredSections.isEmpty ? 0 : filteredSections.count - 1)
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

    // MARK: - Export / Import

    @objc func exportNotes() {
        let panel = NSSavePanel()
        panel.title = "Export QuickNote Backup"
        panel.nameFieldStringValue = "QuickNote Backup.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let backup = QuickNoteBackup(version: 1, buckets: buckets, sections: sections)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(backup)
            try data.write(to: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Export failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc func importNotes() {
        let panel = NSOpenPanel()
        panel.title = "Import QuickNote Backup"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let backup = try JSONDecoder().decode(QuickNoteBackup.self, from: data)

            let alert = NSAlert()
            alert.messageText = "Import \(backup.buckets.count) tab(s) and \(backup.sections.count) section(s)?"
            alert.informativeText = "Choose Replace to overwrite all current notes, or Merge to add them alongside existing ones."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Merge")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            if response == .alertThirdButtonReturn { return }

            if response == .alertFirstButtonReturn {
                // Replace
                buckets = backup.buckets
                sections = backup.sections
                activeBucketId = buckets.first?.id ?? ""
            } else {
                // Merge — remap IDs to avoid collisions with existing data
                var idMap: [String: String] = [:]
                var newBuckets = backup.buckets.map { b -> NoteBucket in
                    let newId = UUID().uuidString
                    idMap[b.id] = newId
                    return NoteBucket(id: newId, name: b.name)
                }
                // Avoid duplicate tab names
                let existingNames = Set(buckets.map { $0.name })
                for i in newBuckets.indices where existingNames.contains(newBuckets[i].name) {
                    newBuckets[i].name += " (imported)"
                }
                let newSections = backup.sections.map { s -> NoteSection in
                    NoteSection(id: UUID().uuidString,
                                content: s.content,
                                bucketId: s.bucketId.flatMap { idMap[$0] },
                                rtfData: s.rtfData)
                }
                buckets += newBuckets
                sections += newSections
            }

            save()
            rebuildBucketBar()
            reloadAllSections()
            DispatchQueue.main.async { self.focusLastSection() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Import failed"
            alert.informativeText = "The file doesn't appear to be a valid QuickNote backup.\n\(error.localizedDescription)"
            alert.runModal()
        }
    }
}

// MARK: Table Data Source + Delegate

extension SectionsController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === pinnedTableView ? filteredPinnedSections.count : filteredSections.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = SectionCellView()
        let section = tableView === pinnedTableView ? filteredPinnedSections[row] : filteredSections[row]
        cell.configure(section, query: searchQuery, ctrl: self)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let section = tableView === pinnedTableView ? filteredPinnedSections[row] : filteredSections[row]
        if section.isCollapsed { return SectionCellView.collapsedH }
        let w = max(100, tableView.bounds.width - 8)
        return SectionCellView.rowHeight(content: section.content, width: w)
    }

    // Drag source
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard searchQuery.isEmpty else { return nil }
        let sections = tableView === pinnedTableView ? filteredPinnedSections : filteredSections
        let item = NSPasteboardItem()
        item.setString(sections[row].id, forType: SectionsController.pbType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard op == .above else { return [] }
        // Prevent cross-table drops: check if the dragged item is pinned or not
        guard let fromId = info.draggingPasteboard.string(forType: SectionsController.pbType),
              let fromSection = sections.first(where: { $0.id == fromId }) else { return [] }
        let isPinnedDrag = fromSection.isPinned
        let isInPinnedTable = tableView === pinnedTableView
        // Only allow drop within the same table type
        guard isPinnedDrag == isInPinnedTable else { return [] }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let fromId = info.draggingPasteboard.string(forType: SectionsController.pbType),
              let fromGlobal = self.sections.firstIndex(where: { $0.id == fromId }) else { return false }
        let isPinnedTable = tableView === pinnedTableView
        let filtered = isPinnedTable ? filteredPinnedSections : filteredSections
        let targetGlobal: Int
        if row >= filtered.count {
            // Dropped after last filtered row; insert after last section with the same pin status in this bucket
            targetGlobal = (self.sections.lastIndex(where: { ($0.bucketId ?? "") == activeBucketId && $0.isPinned == isPinnedTable }) ?? (self.sections.isEmpty ? 0 : self.sections.count - 1)) + 1
        } else {
            let anchorId = filtered[row].id
            targetGlobal = self.sections.firstIndex(where: { $0.id == anchorId }) ?? self.sections.count
        }
        let moved = self.sections.remove(at: fromGlobal)
        let adjusted = targetGlobal > fromGlobal ? targetGlobal - 1 : targetGlobal
        self.sections.insert(moved, at: min(adjusted, self.sections.count))
        reloadAllSections()
        save()
        return true
    }
}

// MARK: Search

extension SectionsController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        searchQuery = field.stringValue
        searchDebounce?.invalidate()
        searchDebounce = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { [weak self] _ in
            self?.reloadAllSections()
        }
    }
}

// MARK: - Hover Button

class HoverButton: NSButton {
    /// The color used when the mouse is NOT over the button.
    var dimColor: NSColor = NSColor.tertiaryLabelColor {
        didSet { contentTintColor = dimColor }
    }
    /// The color used when the mouse IS over the button.
    var hoverColor: NSColor = NSColor.labelColor.withAlphaComponent(0.85)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }
    override func mouseEntered(with event: NSEvent) { contentTintColor = hoverColor }
    override func mouseExited(with event: NSEvent)  { contentTintColor = dimColor }
}

// MARK: - Section Header View

private class SectionHeaderView: NSView {}

// MARK: - Section Cell View

class SectionCellView: NSTableCellView {

    private var textView: SectionTextView!
    private var headerView: NSView?
    private var previewLabel: NSTextField?
    private var collapseButton: HoverButton?
    private var copyButton: HoverButton?
    private var dupButton: HoverButton?
    private var delButton: HoverButton?
    private var timestampLabel: NSTextField?
    private var sectionId = ""
    private weak var ctrl: SectionsController?
    private var countLabel: NSTextField?
    private var isHovered = false
    private var pinButton: HoverButton?
    private var isPinned = false

    static let headerH: CGFloat = 22
    static let minH: CGFloat = 72
    static let collapsedH: CGFloat = 26

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
        layer?.backgroundColor = NSColor(red: 1.0, green: 0.88, blue: 0.60, alpha: 0.04).cgColor

        // Header bar
        let header = SectionHeaderView()
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        headerView = header

        // Drag handle — three horizontal dots
        let handleImg = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Drag")
        let handle = NSImageView(image: handleImg ?? NSImage())
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.contentTintColor = NSColor.tertiaryLabelColor
        handle.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
        header.addSubview(handle)

        // Collapse/expand chevron button — always visible, far right
        let chevron = HoverButton(title: "", target: self, action: #selector(collapseToggled))
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Collapse")
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .medium)
        chevron.isBordered = false
        chevron.bezelStyle = .inline
        chevron.dimColor = NSColor.tertiaryLabelColor
        chevron.hoverColor = NSColor.labelColor.withAlphaComponent(0.85)
        chevron.toolTip = "Collapse section"
        header.addSubview(chevron)
        collapseButton = chevron

        // Timestamp label — shown on hover, next to chevron
        let ts = NSTextField(labelWithString: "")
        ts.translatesAutoresizingMaskIntoConstraints = false
        ts.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        ts.textColor = NSColor.tertiaryLabelColor
        ts.alphaValue = 0
        header.addSubview(ts)
        timestampLabel = ts
        ts.stringValue = Self.relativeTime(section.lastModified)

        // Preview — first line shown when collapsed
        let preview = NSTextField(labelWithString: "")
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        preview.textColor = NSColor.secondaryLabelColor
        preview.lineBreakMode = .byTruncatingTail
        preview.isHidden = true
        header.addSubview(preview)
        previewLabel = preview

        // Word / character count — shown on hover
        let count = NSTextField(labelWithString: "")
        count.translatesAutoresizingMaskIntoConstraints = false
        count.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        count.textColor = NSColor.tertiaryLabelColor
        count.alignment = .right
        count.alphaValue = 0
        header.addSubview(count)
        countLabel = count

        // Copy button
        let copy = HoverButton(title: "", target: self, action: #selector(copySelf))
        copy.translatesAutoresizingMaskIntoConstraints = false
        copy.isBordered = false
        copy.bezelStyle = .inline
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        copy.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .light)
        copy.dimColor = NSColor.tertiaryLabelColor
        copy.hoverColor = NSColor.labelColor.withAlphaComponent(0.85)
        copy.alphaValue = 0
        copy.toolTip = "Copy section"
        header.addSubview(copy)
        copyButton = copy

        // Duplicate button
        let dup = HoverButton(title: "", target: self, action: #selector(duplicateSelf))
        dup.translatesAutoresizingMaskIntoConstraints = false
        dup.isBordered = false
        dup.bezelStyle = .inline
        dup.image = NSImage(systemSymbolName: "plus.square.on.square", accessibilityDescription: "Duplicate")
        dup.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .light)
        dup.dimColor = NSColor.tertiaryLabelColor
        dup.hoverColor = NSColor.labelColor.withAlphaComponent(0.85)
        dup.alphaValue = 0
        dup.toolTip = "Duplicate section"
        header.addSubview(dup)
        dupButton = dup

        // Delete button
        let del = HoverButton(title: "", target: self, action: #selector(deleteSelf))
        del.translatesAutoresizingMaskIntoConstraints = false
        del.isBordered = false
        del.bezelStyle = .inline
        del.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Delete")
        del.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
        del.dimColor = NSColor.tertiaryLabelColor
        del.hoverColor = NSColor.labelColor.withAlphaComponent(0.85)
        del.alphaValue = 0
        header.addSubview(del)
        delButton = del

        // Pin button
        let pin = HoverButton(title: "", target: self, action: #selector(pinToggled))
        pin.translatesAutoresizingMaskIntoConstraints = false
        pin.isBordered = false
        pin.bezelStyle = .inline
        pin.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "Pin")
        pin.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
        pin.dimColor = NSColor.tertiaryLabelColor
        pin.hoverColor = NSColor.labelColor.withAlphaComponent(0.85)
        pin.alphaValue = 0
        pin.toolTip = "Pin section"
        header.addSubview(pin)
        pinButton = pin

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
        // Load content. We detect the format by inspecting the *loaded RTF text*, not content.
        // content always stores textView.string (U+FFFC for attachments); rtfData tells us the format:
        //   • RTF text has ☐/☑  → new format: convert ☐/☑ back to SF Symbol attachments
        //   • RTF text has U+FFFC → old format: TIFF attachments, re-mark as unchecked SF Symbols
        //   • RTF has neither    → plain text (strikethrough only)
        //   • no rtfData         → fall back to plain content string
        if let rtf = section.rtfData,
           let attrStr = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            let loadedText = attrStr.string
            if loadedText.contains("☐") || loadedText.contains("☑") {
                // New format: RTF encodes checkboxes as ☐/☑ text → restore SF Symbol attachments
                textView.textStorage?.setAttributedString(attrStr)
                textView.convertTextCheckboxesToAttachments()
                textView.isInListMode = true
            } else if loadedText.contains("\u{FFFC}") {
                // Old format: RTF has raw TIFF attachments → replace with unchecked SF Symbols
                textView.textStorage?.setAttributedString(attrStr)
                textView.reMarkCheckboxAttachments()
                textView.isInListMode = true
                // Auto-migrate: resave with new RTF format so next launch is instant
                let sid = section.id
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.ctrl?.update(id: sid,
                                      content: self.textView.string,
                                      rtfData: self.textView.rtfDataForStorage())
                }
            } else {
                // Plain text (e.g. strikethrough) — no checkboxes
                textView.textStorage?.setAttributedString(attrStr)
                textView.isInListMode = false
            }
        } else {
            // No saved RTF — load from plain content string
            textView.string = section.content
            textView.isInListMode = false
        }
        // Ensure new typing uses the correct base font & colour
        textView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
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
            self.ctrl?.refreshRowHeightForSection(id: self.sectionId)
        }
        // Persist after a direct storage change (e.g. strikethrough toggle, checkbox click)
        textView.onTextStorageChanged = { [weak self] in
            guard let self = self else { return }
            let rtf = self.textView.rtfDataForStorage()
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

            chevron.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
            chevron.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 14),
            chevron.heightAnchor.constraint(equalToConstant: 14),

            ts.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 5),
            ts.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            handle.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            handle.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            preview.leadingAnchor.constraint(equalTo: ts.trailingAnchor, constant: 6),
            preview.trailingAnchor.constraint(equalTo: copy.leadingAnchor, constant: -8),
            preview.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            count.trailingAnchor.constraint(equalTo: copy.leadingAnchor, constant: -8),
            count.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            del.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            del.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            del.widthAnchor.constraint(equalToConstant: 14),
            del.heightAnchor.constraint(equalToConstant: 14),

            pin.trailingAnchor.constraint(equalTo: del.leadingAnchor, constant: -4),
            pin.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            pin.widthAnchor.constraint(equalToConstant: 14),
            pin.heightAnchor.constraint(equalToConstant: 14),

            dup.trailingAnchor.constraint(equalTo: pin.leadingAnchor, constant: -4),
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

        // Apply initial collapsed state without animation
        applyCollapsed(section.isCollapsed)
        // Apply initial pinned state
        self.isPinned = section.isPinned
        applyPinned(section.isPinned)
    }

    func applyCollapsed(_ collapsed: Bool) {
        textView?.isHidden = collapsed
        previewLabel?.isHidden = !collapsed
        if collapsed { updatePreviewLabel() }
        let symbol = collapsed ? "chevron.down" : "chevron.up"
        collapseButton?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        collapseButton?.toolTip = collapsed ? "Expand section" : "Collapse section"
        // Clip the cell so content doesn't overflow when row height shrinks
        clipsToBounds = true
        wantsLayer = true
    }

    func applyPinned(_ pinned: Bool) {
        isPinned = pinned
        if pinned {
            pinButton?.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Unpin")
            pinButton?.dimColor = NSColor.white.withAlphaComponent(0.85)
            pinButton?.hoverColor = NSColor.white
            pinButton?.toolTip = "Unpin section"
        } else {
            pinButton?.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "Pin")
            pinButton?.dimColor = NSColor.tertiaryLabelColor
            pinButton?.hoverColor = NSColor.labelColor.withAlphaComponent(0.85)
            pinButton?.toolTip = "Pin section"
        }
        pinButton?.alphaValue = isHovered ? 1 : 0
    }

    @objc private func pinToggled() {
        ctrl?.togglePin(id: sectionId)
    }

    private func updatePreviewLabel() {
        guard let tv = textView else { return }
        let firstLine = tv.string
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        // Strip object replacement chars (checkboxes)
        let clean = firstLine.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespaces)
        previewLabel?.stringValue = clean.isEmpty ? "(empty)" : clean
    }


    @objc private func collapseToggled() {
        ctrl?.toggleCollapse(id: sectionId)
    }

    func focus() { textView?.window?.makeFirstResponder(textView) }

    private static let warmFill = NSColor(red: 1.0, green: 0.88, blue: 0.60, alpha: 1.0)

    func setActive(_ active: Bool) {
        layer?.backgroundColor = active
            ? NSColor.white.withAlphaComponent(0.18).cgColor
            : SectionCellView.warmFill.withAlphaComponent(0.04).cgColor
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
        isHovered = true
        if layer?.borderWidth == 0 {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
        }
        updateCountLabel()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            countLabel?.animator().alphaValue = 1
            timestampLabel?.animator().alphaValue = 1
            copyButton?.animator().alphaValue = 1
            dupButton?.animator().alphaValue = 1
            delButton?.animator().alphaValue = 1
            pinButton?.animator().alphaValue = 1
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        if layer?.borderWidth == 0 {
            layer?.backgroundColor = SectionCellView.warmFill.withAlphaComponent(0.04).cgColor
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            countLabel?.animator().alphaValue = 0
            timestampLabel?.animator().alphaValue = 0
            copyButton?.animator().alphaValue = 0
            dupButton?.animator().alphaValue = 0
            delButton?.animator().alphaValue = 0
            pinButton?.animator().alphaValue = 0
        }
    }

    private func updateCountLabel() {
        guard let tv = textView else { return }
        let plain = tv.string
            .replacingOccurrences(of: "\u{FFFC}", with: "")  // strip attachment chars
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let words = plain.isEmpty ? 0 :
            plain.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        let chars = plain.count
        countLabel?.stringValue = "\(words)w · \(chars)c"
    }

    func refreshTimestamp(_ date: Date) {
        timestampLabel?.stringValue = Self.relativeTime(date)
    }

    static func relativeTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60  { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        if seconds < 604800 { return "\(seconds / 86400)d ago" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
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

/// MARK: Text View Delegate

extension SectionCellView: NSTextViewDelegate {

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let stv = textView as? SectionTextView   // typed access to our custom properties

        if selector == #selector(NSResponder.insertTab(_:)) {
            ctrl?.focusSection(offset: +1, from: sectionId)
            return true
        }
        if selector == #selector(NSResponder.insertBacktab(_:)) {
            ctrl?.focusSection(offset: -1, from: sectionId)
            return true
        }

        if selector == #selector(NSResponder.insertNewline(_:)) {
            let sel = textView.selectedRange()
            let str = textView.string as NSString

            // Check whether the current line starts with a checkbox — this is more
            // reliable than the section-level isInListMode flag, which can be true
            // even when the cursor is on a normal line below a list.
            var lineStart = sel.location
            while lineStart > 0 && str.character(at: lineStart - 1) != 10 { lineStart -= 1 }
            let cursorLineHasCheckbox = lineStart < str.length
                && textView.textStorage?.attribute(SectionTextView.checkboxKey,
                                                   at: lineStart,
                                                   effectiveRange: nil) != nil

            if cursorLineHasCheckbox {
                // Empty list item + Enter → exit list mode
                // An empty item = cursor is right after "[attachment] " with nothing else on the line.
                if sel.length == 0, sel.location >= 2 {
                    let c1 = str.character(at: sel.location - 2)   // attachment char = 0xFFFC
                    let c2 = str.character(at: sel.location - 1)   // space = 0x20
                    let isEmptyCheckbox = c1 == 0xFFFC && c2 == 0x20
                        && textView.textStorage?.attribute(SectionTextView.checkboxKey,
                                                           at: sel.location - 2,
                                                           effectiveRange: nil) != nil
                    if isEmptyCheckbox {
                        let atLineStart = sel.location == 2
                            || str.character(at: sel.location - 3) == 10
                        let atLineEnd = sel.location == str.length
                            || str.character(at: sel.location) == 10
                        if atLineStart && atLineEnd {
                            let delRange = NSRange(location: sel.location - 2, length: 2)
                            if textView.shouldChangeText(in: delRange, replacementString: "") {
                                textView.textStorage?.replaceCharacters(in: delRange, with: "")
                                textView.didChangeText()
                            }
                            stv?.isInListMode = false
                            return true
                        }
                    }
                }
                // Non-empty list item → new unchecked item
                let newItem = NSMutableAttributedString(string: "\n")
                newItem.append(SectionTextView.checkboxAttrStr(checked: false))
                newItem.append(NSAttributedString(string: " ", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                ]))
                let plainNew = newItem.string
                if textView.shouldChangeText(in: sel, replacementString: plainNew) {
                    textView.textStorage?.replaceCharacters(in: sel, with: newItem)
                    textView.setSelectedRange(
                        NSRange(location: sel.location + (plainNew as NSString).length, length: 0))
                    textView.didChangeText()
                }
                return true
            }

            // Not on a checkbox line: check if the current line ends with /list
            let lineText = str.substring(with: NSRange(location: lineStart,
                                                        length: sel.location - lineStart))
            if lineText.hasSuffix("/list") {
                // Replace "/list" with newline + checkbox attachment + space
                let triggerStart = lineStart + (lineText as NSString).length - 5
                let replacement = NSMutableAttributedString(string: "\n")
                replacement.append(SectionTextView.checkboxAttrStr(checked: false))
                replacement.append(NSAttributedString(string: " ", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                ]))
                let plainReplacement = replacement.string
                let replaceRange = NSRange(location: triggerStart, length: 5)
                if textView.shouldChangeText(in: replaceRange, replacementString: plainReplacement) {
                    textView.textStorage?.replaceCharacters(in: replaceRange, with: replacement)
                    textView.setSelectedRange(
                        NSRange(location: triggerStart + (plainReplacement as NSString).length,
                                length: 0))
                    textView.didChangeText()
                }
                stv?.isInListMode = true
                return true
            }
        }

        // Backspace on an empty list item alone on its line → remove the checkbox
        if selector == #selector(NSResponder.deleteBackward(_:)), stv?.isInListMode == true {
            let sel = textView.selectedRange()
            if sel.length == 0, sel.location >= 2 {
                let str = textView.string as NSString
                let c1 = str.character(at: sel.location - 2)
                let c2 = str.character(at: sel.location - 1)
                let isEmptyCheckbox = c1 == 0xFFFC && c2 == 0x20
                    && textView.textStorage?.attribute(SectionTextView.checkboxKey,
                                                       at: sel.location - 2,
                                                       effectiveRange: nil) != nil
                if isEmptyCheckbox {
                    let atLineStart = sel.location == 2
                        || str.character(at: sel.location - 3) == 10
                    let atLineEnd = sel.location == str.length
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
        if !(textView as SectionTextView).suppressBreakUndoCoalescing {
            textView.breakUndoCoalescing()
        }
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
        // Auto-reset isInListMode only when all checkboxes have been deleted,
        // so Enter stops adding new items. Never flip false→true here — that
        // only happens via explicit activation (Cmd+Option+L or /list).
        let stv = textView as SectionTextView
        if stv.isInListMode, let storage = stv.textStorage {
            var hasCheckbox = false
            storage.enumerateAttribute(SectionTextView.checkboxKey,
                                       in: NSRange(location: 0, length: storage.length),
                                       options: .longestEffectiveRangeNotRequired) { val, _, stop in
                if val != nil { hasCheckbox = true; stop.pointee = true }
            }
            if !hasCheckbox { stv.isInListMode = false }
        }
        let len = textView.textStorage?.length ?? 0
        let rtf = len > 0 ? (textView.hasRichContent() ? textView.rtfDataForStorage() : nil) : nil
        ctrl?.update(id: sectionId, content: textView.string, rtfData: rtf)
        ctrl?.refreshRowHeight(for: self)
        if isHovered {
            updateCountLabel()
            timestampLabel?.stringValue = Self.relativeTime(Date())
        }
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

        return true
    }
}

// MARK: - Tab Bar (manual layout so tabs shrink to fit without fighting AutoLayout)

class BucketBarView: NSView {
    private(set) var tabs: [BucketTabView] = []
    var spacing: CGFloat = 4
    var maxTabWidth: CGFloat = 160

    /// Called with (originalIndex, finalIndex) when the user finishes dragging a tab.
    var onReorder: ((Int, Int) -> Void)?
    var onAddTab: (() -> Void)?

    private var draggingTab: BucketTabView?
    private var draggingOriginalIndex = 0

    // The + button lives inside the bar and moves with the tabs
    private let addButton: HoverButton = {
        let btn = HoverButton()
        btn.title = "+"
        btn.isBordered = false
        btn.bezelStyle = .inline
        btn.font = NSFont.systemFont(ofSize: 16, weight: .light)
        btn.dimColor = NSColor.white.withAlphaComponent(0.45)
        btn.hoverColor = NSColor.white.withAlphaComponent(0.90)
        btn.wantsLayer = true
        return btn
    }()

    private let addButtonWidth: CGFloat = 24

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(addButton)
        addButton.target = self
        addButton.action = #selector(addTabTapped)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func addTabTapped() { onAddTab?() }

    private func tabWidth(forCount count: Int) -> CGFloat {
        let n = CGFloat(max(1, count))
        let totalSpacing = spacing * (n - 1)
        let available = bounds.width - addButtonWidth - spacing
        return min(maxTabWidth, max(40, (available - totalSpacing) / n))
    }

    func setTabs(_ newTabs: [BucketTabView]) {
        tabs.forEach { $0.removeFromSuperview() }
        tabs = newTabs
        tabs.forEach { tab in
            addSubview(tab)
            tab.onDragMoved = { [weak self, weak tab] event in
                guard let self, let tab else { return }
                self.handleDrag(tab: tab, event: event)
            }
            tab.onDragEnded = { [weak self, weak tab] in
                guard let self, let tab else { return }
                self.commitDrag(tab: tab)
            }
        }
        needsLayout = true
    }

    private func handleDrag(tab: BucketTabView, event: NSEvent) {
        let mouseX = convert(event.locationInWindow, from: nil).x
        let tw = tabWidth(forCount: tabs.count)

        if draggingTab == nil {
            draggingTab = tab
            draggingOriginalIndex = tabs.firstIndex(of: tab) ?? 0
            tab.layer?.zPosition = 10
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.1
                tab.animator().alphaValue = 0.75
            }
            addSubview(tab)  // bring to front
        }

        // Dragged tab follows cursor, clamped within bar bounds
        let clampedX = max(0, min(bounds.width - tw, mouseX - tw / 2))
        tab.frame = CGRect(x: clampedX, y: 0, width: tw, height: bounds.height)

        // Determine where in the order the dragged tab should land
        guard let currentIndex = tabs.firstIndex(of: tab) else { return }
        var targetIndex = 0
        for t in tabs where t !== tab {
            if t.frame.midX < mouseX { targetIndex += 1 }
        }
        targetIndex = min(max(targetIndex, 0), tabs.count - 1)
        guard targetIndex != currentIndex else { return }

        tabs.remove(at: currentIndex)
        tabs.insert(tab, at: targetIndex)

        // Animate non-dragged tabs into their new slots, leaving a gap for the dragged tab
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.allowsImplicitAnimation = true
            for (i, t) in tabs.enumerated() where t !== tab {
                t.animator().frame = CGRect(x: CGFloat(i) * (tw + spacing), y: 0,
                                            width: tw, height: bounds.height)
            }
        }
    }

    private func commitDrag(tab: BucketTabView) {
        guard let finalIndex = tabs.firstIndex(of: tab) else {
            tab.layer?.zPosition = 0
            tab.alphaValue = 1
            draggingTab = nil
            return
        }
        let tw = tabWidth(forCount: tabs.count)
        let finalX = CGFloat(finalIndex) * (tw + spacing)
        let didMove = finalIndex != draggingOriginalIndex
        let from = draggingOriginalIndex
        draggingTab = nil

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            tab.animator().frame = CGRect(x: finalX, y: 0, width: tw, height: bounds.height)
            tab.animator().alphaValue = 1
        }, completionHandler: { [weak tab, weak self] in
            tab?.layer?.zPosition = 0
            if didMove { self?.onReorder?(from, finalIndex) }
        })
    }

    override func layout() {
        super.layout()
        let tw = tabWidth(forCount: tabs.count)
        for (i, tab) in tabs.enumerated() where tab !== draggingTab {
            tab.frame = CGRect(x: CGFloat(i) * (tw + spacing), y: 0, width: tw, height: bounds.height)
        }
        // + button sits right after the last tab
        let tabsEndX = tabs.isEmpty ? 0 : CGFloat(tabs.count) * (tw + spacing) - spacing + spacing
        let btnY = (bounds.height - addButtonWidth) / 2
        addButton.frame = CGRect(x: tabsEndX, y: btnY, width: addButtonWidth, height: addButtonWidth)
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
    var onRequestDuplicate: (() -> Void)?
    var onDidEndEditing: (() -> Void)?
    var onDragMoved: ((NSEvent) -> Void)?
    var onDragEnded: (() -> Void)?
    /// Called when a section is dropped onto this tab. Return true if accepted.
    var onReceiveDrop: ((String) -> Bool)?
    private var hasDragged = false

    private let label = NSTextField(labelWithString: "")
    private let editView = NSTextView()            // NSTextView handles its own key events
    private var editContainer: NSScrollView!
    private let closeButton = HoverButton()
    private let dupButton = HoverButton()
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

        // Close button — plain ×, visible on hover/active
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.title = ""
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.dimColor = NSColor.tertiaryLabelColor
        closeButton.hoverColor = NSColor.labelColor.withAlphaComponent(0.85)
        closeButton.target = self
        closeButton.action = #selector(requestDelete)
        closeButton.alphaValue = 0
        addSubview(closeButton)

        // Duplicate button — same style as close, sits to its left
        dupButton.translatesAutoresizingMaskIntoConstraints = false
        dupButton.title = ""
        dupButton.image = NSImage(systemSymbolName: "plus.square.on.square", accessibilityDescription: "Duplicate")
        dupButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .light)
        dupButton.isBordered = false
        dupButton.bezelStyle = .inline
        dupButton.dimColor = NSColor.tertiaryLabelColor
        dupButton.hoverColor = NSColor.labelColor.withAlphaComponent(0.85)
        dupButton.target = self
        dupButton.action = #selector(requestDuplicate)
        dupButton.alphaValue = 0
        addSubview(dupButton)

        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: dupButton.leadingAnchor, constant: -4),

            dupButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            dupButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            dupButton.widthAnchor.constraint(equalToConstant: 14),
            dupButton.heightAnchor.constraint(equalToConstant: 14),

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
        registerForDraggedTypes([SectionsController.pbType])
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

    // MARK: Drag destination (receive section drops)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isActive,
              sender.draggingPasteboard.availableType(from: [SectionsController.pbType]) != nil
        else { return [] }
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.30).cgColor
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isActive else { return [] }
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        updateStyling()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        updateStyling()
        guard let sectionId = sender.draggingPasteboard.string(forType: SectionsController.pbType) else { return false }
        return onReceiveDrop?(sectionId) ?? false
    }

    // MARK: Click / double-click / drag

    override func mouseDown(with event: NSEvent) {
        hasDragged = false
        // If we're already editing, pass through so NSTextView handles the click
        if !editContainer.isHidden { super.mouseDown(with: event); return }
        if event.clickCount >= 2 {
            beginEditing()
        } else {
            onClick?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard editContainer.isHidden else { return }
        hasDragged = true
        onDragMoved?(event)
    }

    override func mouseUp(with event: NSEvent) {
        if hasDragged {
            onDragEnded?()
            hasDragged = false
        }
    }

    // MARK: Styling — layer-based, no custom drawing

    private func updateStyling() {
        let warmFill = NSColor(red: 1.0, green: 0.88, blue: 0.60, alpha: 1.0)
        if isActive {
            label.textColor = .white
            label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
            layer?.borderWidth = 1
        } else if isHovered {
            label.textColor = NSColor.white.withAlphaComponent(0.75)
            label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
            layer?.borderWidth = 1
        } else {
            label.textColor = NSColor.white.withAlphaComponent(0.55)
            label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            layer?.backgroundColor = warmFill.withAlphaComponent(0.04).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
            layer?.borderWidth = 1
        }
        closeButton.alphaValue = (isHovered || isActive) ? 1.0 : 0.0
        dupButton.alphaValue   = (isHovered || isActive) ? 1.0 : 0.0
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

    @objc private func requestDelete()    { onRequestDelete?() }
    @objc private func requestDuplicate() { onRequestDuplicate?() }
}
