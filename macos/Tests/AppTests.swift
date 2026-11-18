import AppKit

@main
struct AppTests {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("niuma-app-test-" + UUID().uuidString)
        let store = SettingsStore(directory: directory)
        let controller = AppController(store: store)
        let clipboard = NSPasteboard.general.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        func cleanup() {
            controller.shutdown()
            try? FileManager.default.removeItem(at: directory)
            NSPasteboard.general.clearContents()
            let items = clipboard.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { NSPasteboard.general.writeObjects(items) }
        }
        defer { cleanup() }
        controller.start()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            guard condition else {
                cleanup()
                fatalError("FAIL: \(message)")
            }
        }
        check(controller.panel.isVisible, "main panel visible")
        check(controller.panel.level == .floating, "floating panel")
        check(controller.settingsWindow != nil && !controller.settings.salaryConfigured, "first launch opens salary setup with example state")
        controller.settingsWindow!.close()
        check(!controller.settings.salaryConfigured, "skipping setup keeps example state")
        controller.copyReport(nil)
        check(NSPasteboard.general.string(forType: .string)?.contains("示例战报") == true, "copy entry identifies example data")
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        check(descendants(controller.panel.mainView).compactMap { $0 as? NSButton }.contains { $0.title == "战报已复制" }, "copy action shows success feedback")
        controller.toggleMini(nil)
        check(controller.settings.mini && controller.panel.frame.height < 150, "mini action changes actual window")
        check(try !store.load().salaryConfigured, "runtime toggles keep example marker persisted")
        check(descendants(controller.panel.mainView).compactMap { $0 as? NSTextField }.contains { !$0.isHidden && $0.stringValue.contains("示例") }, "mini mode identifies example salary")
        check(descendants(controller.panel.mainView).compactMap { $0 as? NSTextField }.contains { !$0.isHidden && $0.stringValue.contains("战报已复制") }, "mini mode shows copy feedback")
        controller.toggleMini(nil)
        check(!controller.settings.mini && controller.panel.frame.height > 200, "full mode restored")
        controller.toggleMask(nil)
        check(controller.panel.mainView.amount.isHidden, "privacy removes actual amount view")
        check(controller.panel.mainView.visibleSalaryText.allSatisfy { !$0.contains("¥100") && !$0.contains("11.11") }, "privacy covers related salary fields")
        controller.copyReport(nil)
        let privateReport = NSPasteboard.general.string(forType: .string) ?? ""
        check(privateReport.contains("****") && !privateReport.contains("100.00") && !privateReport.contains("11.11"), "copy report respects privacy")
        controller.toggleClickThrough(nil)
        check(controller.panel.ignoresMouseEvents, "click-through enabled")
        controller.openSettings(nil)
        guard let editor = controller.settingsWindow else {
            cleanup()
            fatalError("missing settings window")
        }
        editor.window!.contentView!.layoutSubtreeIfNeeded()
        let root = editor.window!.contentView!
        let navigation = descendants(root).compactMap { $0 as? NSSegmentedControl }.first!
        check(navigation.segmentCount == 3, "settings exposes three groups")
        let pages = root.subviews.compactMap { $0 as? NSScrollView }
        check(pages.count == 3 && pages.filter { !$0.isHidden }.count == 1, "only the selected settings page is visible")
        check(!editor.fields["monthDays"]!.isEnabled && !editor.fields["lunchStart"]!.isEnabled && !editor.fields["overtimeRate"]!.isEnabled, "inactive salary options are disabled")
        let sliders = descendants(editor.window!.contentView!).compactMap { $0 as? NSSlider }
        check(sliders.count == 4 && sliders.allSatisfy { $0.frame.width > 200 }, "all setting sliders have usable tracks")
        check(editor.fields["bgPath"]!.frame.width > 200, "background path field remains visible")
        check(!editor.window!.ignoresMouseEvents, "settings stays clickable during click-through")
        editor.fields["amount"]!.stringValue = "not a number"
        check(!editor.saveDraft(), "invalid settings rejected")
        check(controller.settings.amount == 100, "invalid settings don't affect live salary")
        editor.fields["amount"]!.stringValue = "999"
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: editor.fields["amount"]))
        let preview = descendants(root).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "calculationPreview" }!
        check(preview.stringValue.contains("999.00"), "typing updates the salary preview before save")
        navigation.selectedSegment = 1
        navigation.sendAction(navigation.action, to: navigation.target)
        check(!editor.fields["appName"]!.isHiddenOrHasHiddenAncestor && editor.fields["amount"]!.isHiddenOrHasHiddenAncestor, "group navigation changes actual visible fields")
        editor.fields["appName"]!.stringValue = "取消的名称"
        editor.close()
        let cancelled = try store.load()
        check(controller.settings.amount == 100 && cancelled.amount == 100, "cancel preserves both live and saved settings")
        check(!cancelled.salaryConfigured && cancelled.appName == "牛马脱敏器", "cancel keeps setup unfinished and discards other-page changes")
        controller.openSettings(nil)
        let draft = controller.settingsWindow!
        draft.fields["amount"]!.stringValue = "222"
        draft.fields["monthDays"]!.stringValue = "invalid"
        draft.fields["lunchStart"]!.stringValue = "invalid"
        draft.fields["lunchEnd"]!.stringValue = "invalid"
        draft.fields["overtimeRate"]!.stringValue = "invalid"
        draft.fields["appName"]!.stringValue = "我的牛马"
        let draftControls = descendants(draft.window!.contentView!)
        let mode = draftControls.compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "salaryMode" }!
        let lunch = draftControls.compactMap { $0 as? NSButton }.first { $0.title == "暂停计薪" }!
        let overtime = draftControls.compactMap { $0 as? NSButton }.first { $0.title == "下班后继续计薪" }!
        mode.selectItem(at: 1)
        mode.sendAction(mode.action, to: mode.target)
        check(draft.fields["monthDays"]!.isEnabled && !draft.saveDraft(), "re-enabling monthly salary validates its divisor")
        mode.selectItem(at: 0)
        mode.sendAction(mode.action, to: mode.target)
        lunch.performClick(nil)
        check(draft.fields["lunchStart"]!.isEnabled && !draft.saveDraft(), "re-enabling lunch validates its time")
        lunch.performClick(nil)
        overtime.performClick(nil)
        check(draft.fields["overtimeRate"]!.isEnabled && !draft.saveDraft(), "re-enabling overtime validates its rate")
        overtime.performClick(nil)
        let wish = draftControls.compactMap { $0 as? NSTextView }.first { $0.string.contains("一瓶可乐=3") }!
        wish.string = "一份快乐=25"
        check(draft.saveDraft(), "disabled invalid fields allow valid settings save")
        let saved = try store.load()
        check(controller.settings.amount == 222 && saved.amount == 222, "save applies and persists")
        check(saved.salaryConfigured && saved.appName == "我的牛马" && saved.wishlist == "一份快乐=25", "one save commits setup and edits across all groups")
        check(saved.monthDays == 21.75 && saved.lunchStart == "12:00" && saved.overtimeRate == 1.5, "disabled invalid fields preserve stored values")
        check(controller.settings.masked && controller.settings.clickThrough, "saving retains runtime toggles")

        var savedHuawei: AppSettings?
        let huaweiEditor = SettingsWindow(settings: saved) { settings, _ in savedHuawei = settings }
        let huaweiControls = descendants(huaweiEditor.window!.contentView!)
        let huaweiMode = huaweiControls.compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "salaryMode" }!
        let baseSalary = huaweiEditor.fields["huaweiBaseSalary"]!
        check(baseSalary.isHiddenOrHasHiddenAncestor, "Huawei fields are concealed in standard salary mode")
        huaweiMode.selectItem(at: 2)
        huaweiMode.sendAction(huaweiMode.action, to: huaweiMode.target)
        check(!baseSalary.isHiddenOrHasHiddenAncestor && huaweiEditor.fields["payDay"]!.isHiddenOrHasHiddenAncestor, "Huawei mode reveals pay inputs and replaces the fixed payday input")
        baseSalary.stringValue = "21000"
        huaweiEditor.fields["huaweiPerformanceSalary"]!.stringValue = "4200"
        huaweiEditor.fields["huaweiAnnualBonus"]!.stringValue = ""
        huaweiEditor.fields["huaweiMonthDays"]!.stringValue = "20"
        huaweiEditor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: baseSalary))
        let huaweiPreview = huaweiControls.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "calculationPreview" }!
        check(huaweiPreview.stringValue.contains("1260.00") && huaweiPreview.stringValue.contains("2100.00"), "Huawei settings preview shows regular and double rates")
        check(huaweiEditor.saveDraft() && savedHuawei?.usesHuaweiPayroll == true && savedHuawei?.huaweiAnnualBonus == 0 && savedHuawei?.huaweiMonthDays == 20, "Huawei settings save with blank annual bonus and a manual divisor")

        controller.openSettings(nil)
        let statusEditor = controller.settingsWindow!
        let statusControls = descendants(statusEditor.window!.contentView!)
        func control<T: NSControl>(_ id: String, as type: T.Type) -> T {
            let match = statusControls.compactMap { $0 as? T }.first { $0.identifier?.rawValue == id }
            check(match != nil, "settings exposes \(id)")
            return match!
        }
        let statusNavigation = statusControls.compactMap { $0 as? NSSegmentedControl }.first!
        statusNavigation.selectedSegment = 1
        statusNavigation.sendAction(statusNavigation.action, to: statusNavigation.target)
        let occupations = control("statusOccupation", as: NSPopUpButton.self)
        let workText = control("statusField.working", as: NSTextField.self)
        let workPreview = control("statusPreview.working", as: NSTextField.self)
        let resetWork = control("statusReset.working", as: NSButton.self)
        func selectOccupation(_ name: String) {
            occupations.selectItem(withTitle: name)
            occupations.sendAction(occupations.action, to: occupations.target)
        }
        check(!workText.isHiddenOrHasHiddenAncestor, "status editor is visible in Desktop Appearance")
        check(statusControls.filter { $0.identifier?.rawValue.hasPrefix("statusPreview.") == true }.count == 6, "all six states have a preview")
        check(workPreview.stringValue == "上班中", "regular occupation previews legacy wording")
        for state in WorkState.allCases {
            let input = control("statusField.\(state.rawValue)", as: NSTextField.self)
            let preview = control("statusPreview.\(state.rawValue)", as: NSTextField.self)
            check(statusEditor.window!.makeFirstResponder(input), "\(state.rawValue) accepts individual edits")
            input.currentEditor()!.insertText("自定义\(state.defaultLabel)")
            check(preview.stringValue == "自定义\(state.defaultLabel)", "\(state.rawValue) previews its own edits")
            control("statusReset.\(state.rawValue)", as: NSButton.self).performClick(nil)
            check(preview.stringValue == state.defaultLabel, "\(state.rawValue) restores its default individually")
        }
        selectOccupation("上钟 / 下钟")
        check(workPreview.stringValue == "上钟中", "selecting an occupation previews its defaults immediately")
        check(statusEditor.window!.makeFirstResponder(workText), "status input accepts keyboard focus")
        let fieldEditor = workText.currentEditor()!
        fieldEditor.insertText("驻场中")
        check(workPreview.stringValue == "驻场中", "typing previews the active field before commit")
        selectOccupation("厨师")
        check(workPreview.stringValue == "掌勺中", "another occupation starts with its own defaults")
        selectOccupation("上钟 / 下钟")
        check(workPreview.stringValue == "驻场中", "switching back restores the occupation's override")
        resetWork.performClick(nil)
        check(workPreview.stringValue == "上钟中", "one-state restore uses the current occupation's default")
        check(statusEditor.window!.makeFirstResponder(workText), "can edit restored status")
        workText.currentEditor()!.insertText("驻场中")
        control("statusOccupationName", as: NSTextField.self).stringValue = "驻场演出"
        control("statusSaveOccupation", as: NSButton.self).performClick(nil)
        check(occupations.titleOfSelectedItem == "驻场演出" && workText.stringValue.isEmpty && workPreview.stringValue == "驻场中",
              "saving a named occupation makes the previewed labels its defaults")
        check(statusEditor.window!.makeFirstResponder(workText), "can override the new occupation's default")
        workText.currentEditor()!.insertText("排练中")
        control("statusRestoreDefaults", as: NSButton.self).performClick(nil)
        check(workPreview.stringValue == "驻场中", "group restore returns to the custom occupation's defaults")
        check(controller.settings == saved, "editing status settings affects only the draft")
        check(statusEditor.saveDraft(), "status draft saves through the settings window")
        let persistedStatus = try store.load().statusPreferences
        check(persistedStatus.customOccupations.map(\.name) == ["驻场演出"] && persistedStatus.label(for: .working) == "驻场中", "selected custom occupation persists")
        var workingSnapshot = Snapshot()
        workingSnapshot.state = .working
        workingSnapshot.secondsToNext = 3600
        controller.panel.mainView.update(workingSnapshot, engine: Engine(), at: Date())
        let badge = descendants(controller.panel.mainView).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "workStatus" }!
        check(badge.stringValue == "驻场中" && badge.toolTip == "驻场中", "full window applies the saved label and exposes its full text")
        let longStatus = "现场排练中 · Rehearsing 🧑‍🎤 今天还有两场演出"
        var smallPanel = controller.settings
        smallPanel.uiZoom = 0.5
        try smallPanel.statusPreferences.setOverrides([.working: longStatus])
        controller.panel.apply(smallPanel)
        controller.panel.mainView.update(workingSnapshot, engine: Engine(), at: Date())
        check(badge.frame.width == workPreview.frame.width && badge.maximumNumberOfLines == 1 && badge.lineBreakMode == .byTruncatingTail,
              "minimum zoom keeps a single-line status matching the preview's width")
        check(badge.stringValue == longStatus && badge.toolTip == longStatus, "long mixed-script wording stays available in the tooltip")
        controller.toggleMini(nil)
        controller.panel.mainView.setReportCopied(false)
        controller.panel.mainView.update(workingSnapshot, engine: Engine(), at: Date())
        check(badge.stringValue.hasSuffix("后下班"), "mini mode keeps the working countdown")
        workingSnapshot.state = .afterWork
        controller.panel.mainView.update(workingSnapshot, engine: Engine(), at: Date())
        check(badge.stringValue == "已下钟", "mini mode uses the occupation label outside active work")
        controller.toggleMini(nil)
        controller.openSettings(nil)
        let discardStatus = controller.settingsWindow!
        let discardControls = descendants(discardStatus.window!.contentView!)
        let removeOccupation = discardControls.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "statusDeleteOccupation" }!
        check(removeOccupation.isEnabled, "reopening restores the selected editable occupation")
        removeOccupation.performClick(nil)
        discardStatus.close()
        check(try store.load().statusPreferences == persistedStatus, "cancelling after deletion preserves the saved occupation")

        controller.toggleClickThrough(nil)
        check(!controller.panel.ignoresMouseEvents, "menu can recover click-through")
        controller.toggleVisible(nil)
        check(!controller.panel.isVisible, "hide action")
        controller.toggleVisible(nil)
        check(controller.panel.isVisible, "menu restores hidden panel")
        controller.resetPosition(nil)
        check(NSScreen.screens.contains { $0.visibleFrame.contains(controller.panel.frame) }, "panel kept within screen")
        check(controller.makeMenu().items.contains { $0.action == #selector(AppController.toggleClickThrough(_:)) }, "recovery action present in menu")
        controller.openSettings(nil)
        let resetEditor = controller.settingsWindow!
        DispatchQueue.main.async { NSApp.stopModal(withCode: .alertFirstButtonReturn) }
        NSApp.sendAction(NSSelectorFromString("restoreDefaults:"), to: resetEditor, from: nil)
        check(resetEditor.fields["amount"]!.stringValue == "100.0", "restore defaults updates the draft")
        resetEditor.close()
        let afterReset = try store.load()
        check(controller.settings.amount == 222 && afterReset.amount == 222, "cancel after restore preserves saved and live settings")
        let failingEditor = SettingsWindow(settings: AppSettings()) { _, _ in throw SettingsError(message: "测试保存失败") }
        failingEditor.showWindow(nil)
        check(!failingEditor.saveDraft() && failingEditor.window!.isVisible, "failed persistence keeps the editor open")
        check(descendants(failingEditor.window!.contentView!).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "测试保存失败" }, "failed persistence displays its error")
        failingEditor.close()
        controller.shutdown()
        let area = NSScreen.main!.visibleFrame
        for mini in [true, false] {
            var restored = try store.load()
            restored.mini = mini
            restored.windowX = area.minX + 60
            restored.windowY = area.minY + 36
            try store.save(restored)
            let reopened = AppController(store: store)
            reopened.start()
            defer { reopened.shutdown() }
            check(reopened.settingsWindow == nil && reopened.settings.salaryConfigured, "configured relaunch skips first-run setup")
            check(abs(reopened.panel.frame.minX - restored.windowX!) < 1 && abs(reopened.panel.frame.minY - restored.windowY!) < 1,
                  "relaunch preserves saved origin in \(mini ? "mini" : "full") mode")
        }
        print("PASS: \(checks) native app checks — setup, grouped settings, live preview, privacy, copy, mini and persistence")
    }
}
