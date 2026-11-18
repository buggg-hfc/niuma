import AppKit

final class StatusEditor: NSView, NSTextFieldDelegate {
    static let height = 327.0
    var showError: ((String) -> Void)?
    override var isFlipped: Bool { true }

    private var draft: StatusPreferences
    private let occupations = NSPopUpButton()
    private let occupationName = NSTextField()
    private var deleteButton: NSButton!
    private var restoreButton: NSButton!
    private var fields: [WorkState: NSTextField] = [:]
    private var previews: [WorkState: NSTextField] = [:]
    private var resets: [WorkState: NSButton] = [:]

    init(preferences: StatusPreferences, frame: NSRect) {
        draft = preferences
        super.init(frame: frame)
        build()
        refreshOccupations()
        loadSelection()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func place(_ view: NSView, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        view.frame = NSRect(x: x, y: y, width: width, height: height)
        addSubview(view)
    }

    private func title(_ text: String, x: CGFloat = 0, y: CGFloat, width: CGFloat = 110, hint: Bool = false) {
        let label = Theme.label(hint ? 11 : 13, color: hint ? Theme.muted : Theme.ink)
        label.stringValue = text
        place(label, x: x, y: y, width: width, height: 22)
    }

    private func button(_ title: String, id: String, action: Selector, x: CGFloat, y: CGFloat, width: CGFloat) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.bezelStyle = .rounded
        place(button, x: x, y: y, width: width, height: 27)
        return button
    }

    private func input(_ field: NSTextField, id: String, label: String, y: CGFloat) {
        field.identifier = NSUserInterfaceItemIdentifier(id)
        field.setAccessibilityLabel(label)
        field.font = .systemFont(ofSize: 13)
        field.cell?.usesSingleLineMode = true
        field.delegate = self
        place(field, x: 122, y: y, width: 282, height: 24)
    }

    private func build() {
        title("职业预设", y: 4)
        occupations.identifier = NSUserInterfaceItemIdentifier("statusOccupation")
        occupations.setAccessibilityLabel("职业预设")
        occupations.target = self
        occupations.action = #selector(selectOccupation(_:))
        place(occupations, x: 122, y: 0, width: 282, height: 28)
        deleteButton = button("删除职业", id: "statusDeleteOccupation", action: #selector(deleteOccupation(_:)), x: 414, y: 0, width: 90)
        restoreButton = button("恢复默认文案", id: "statusRestoreDefaults", action: #selector(restoreAll(_:)), x: 509, y: 0, width: 117)

        title("显示文案", x: 122, y: 39, hint: true)
        title("预览", x: 441, y: 39, hint: true)
        for (index, state) in WorkState.allCases.enumerated() {
            let y = CGFloat(60 + index * 34)
            let key = state.rawValue
            title(state.defaultLabel, y: y + 3)
            let field = NSTextField()
            input(field, id: "statusField." + key, label: state.defaultLabel + "的显示文案", y: y)
            fields[state] = field

            let pill = NSView()
            pill.wantsLayer = true
            pill.layer?.backgroundColor = Theme.green.withAlphaComponent(0.08).cgColor
            pill.layer?.cornerRadius = 14
            place(pill, x: 414, y: y - 2, width: Theme.statusLabelWidth + 10, height: 28)
            let preview = Theme.statusLabel()
            preview.identifier = NSUserInterfaceItemIdentifier("statusPreview." + key)
            preview.frame = NSRect(x: 5, y: 2, width: Theme.statusLabelWidth, height: 20)
            pill.addSubview(preview)
            previews[state] = preview

            let reset = button("恢复", id: "statusReset." + key, action: #selector(restoreState(_:)), x: 530, y: y - 2, width: 70)
            reset.tag = index
            reset.setAccessibilityLabel("恢复「\(state.defaultLabel)」默认文案")
            resets[state] = reset
        }

        title("自定义职业", y: 274)
        occupationName.placeholderString = "输入职业名称"
        input(occupationName, id: "statusOccupationName", label: "自定义职业名称", y: 270)
        occupationName.target = self
        occupationName.action = #selector(saveOccupation(_:))
        _ = button("存为新职业", id: "statusSaveOccupation", action: #selector(saveOccupation(_:)), x: 414, y: 268, width: 105)
        title("新职业会把当前六项预览用作默认文案。", x: 122, y: 301, width: 490, hint: true)
    }

    private func refreshOccupations() {
        occupations.removeAllItems()
        for preset in draft.occupations {
            occupations.addItem(withTitle: preset.name)
            occupations.lastItem?.representedObject = preset.id
        }
    }

    private func loadSelection() {
        occupations.selectItem(at: occupations.indexOfItem(withRepresentedObject: draft.selectedOccupationID))
        deleteButton.isEnabled = draft.canDeleteSelection
        let overrides = draft.activeOverrides
        for state in WorkState.allCases {
            fields[state]?.placeholderString = draft.defaultLabel(for: state)
            fields[state]?.stringValue = overrides[state] ?? ""
        }
        refreshPreviews()
    }

    private func text(in field: NSTextField) -> String {
        field.currentEditor()?.string ?? field.stringValue
    }

    private func refreshPreviews() {
        var hasOverrides = false
        for state in WorkState.allCases {
            guard let field = fields[state], let preview = previews[state] else { continue }
            let input = text(in: field)
            resets[state]?.isEnabled = !input.isEmpty
            hasOverrides = hasOverrides || !input.isEmpty
            do {
                let value = try StatusLabels.cleaned(input, field: "「\(state.defaultLabel)」文案")
                preview.textColor = state == .overtime ? Theme.orange : Theme.green
                Theme.showStatus(value.isEmpty ? draft.defaultLabel(for: state) : value, in: preview)
            } catch {
                preview.textColor = .systemRed
                Theme.showStatus("格式有误", in: preview)
                preview.toolTip = error.localizedDescription
            }
        }
        restoreButton.isEnabled = hasOverrides
    }

    func controlTextDidChange(_ notification: Notification) {
        showError?("")
        if notification.object as? NSTextField !== occupationName { refreshPreviews() }
    }

    func collect() throws -> StatusPreferences {
        var result = draft
        try result.setOverrides(fields.mapValues { text(in: $0) })
        return result
    }

    @objc private func selectOccupation(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        do {
            draft = try collect()
            window?.makeFirstResponder(nil)
            draft.selectOccupation(id)
            loadSelection()
            showError?("")
        } catch {
            occupations.selectItem(at: occupations.indexOfItem(withRepresentedObject: draft.selectedOccupationID))
            showError?(error.localizedDescription)
        }
    }

    @objc private func saveOccupation(_ sender: Any?) {
        do {
            var result = try collect()
            try result.addOccupation(named: text(in: occupationName))
            window?.makeFirstResponder(nil)
            draft = result
            occupationName.stringValue = ""
            refreshOccupations()
            loadSelection()
            showError?("")
        } catch { showError?(error.localizedDescription) }
    }

    @objc private func deleteOccupation(_ sender: NSButton) {
        window?.makeFirstResponder(nil)
        draft.deleteSelectedOccupation()
        refreshOccupations()
        loadSelection()
        showError?("")
    }

    @objc private func restoreState(_ sender: NSButton) {
        window?.makeFirstResponder(nil)
        fields[WorkState.allCases[sender.tag]]?.stringValue = ""
        refreshPreviews()
        showError?("")
    }

    @objc private func restoreAll(_ sender: NSButton) {
        window?.makeFirstResponder(nil)
        for field in fields.values { field.stringValue = "" }
        refreshPreviews()
        showError?("")
    }
}
