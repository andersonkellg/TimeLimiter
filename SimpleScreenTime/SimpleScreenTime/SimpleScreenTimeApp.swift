import SwiftUI
import AppKit

@main
struct SimpleScreenTimeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { Settings { EmptyView() } } // no windows
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    // ====== CONFIG ======
    private let dailyLimitSeconds: TimeInterval = 60 * 60  // 1 hour
    private let hardCodedPin = "0000"                     // change this
    private let blinkWhenOverLimit = true
    private let showBackgroundColor = true                // colored background
    // ====================

    private var statusItem: NSStatusItem!
    private var countdownMenuItem: NSMenuItem!
    private var countdownLabel: NSTextField!
    private var progressIndicator: NSProgressIndicator!
    private var timer: Timer?
    private let speechSynthesizer = NSSpeechSynthesizer()

    private var state = UsageState.load()
    private var lastTick = Date()
    private var isCounting = true
    private var popupsShownToday = 0
    private var lastPopupTime: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupMenu()
        setupObservers()

        log("AppLaunched")
        normalizeForToday()
        popupsShownToday = state.popupsShownToday
        lastPopupTime = state.lastPopupTime

        lastTick = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("AppTerminating")
        UsageState.save(state)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "—m"

        // Add visual styling
        if let button = statusItem.button {
            button.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)

            // Add colored background and border
            if showBackgroundColor {
                button.wantsLayer = true
                button.layer?.cornerRadius = 4
                button.layer?.borderWidth = 1.5
            }
        }
    }

    private func setupMenu() {
        let menu = NSMenu()
        setupCountdownMenuItem(in: menu)
        menu.addItem(NSMenuItem(title: "Edit Today's Limit (PIN)", action: #selector(editTodayLimit), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Edit Alerts (PIN)", action: #selector(editAlerts), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reset Today's Time (PIN)", action: #selector(resetWithPin), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Log Folder", action: #selector(openLogFolder), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit (PIN)", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func setupCountdownMenuItem(in menu: NSMenu) {
        countdownLabel = NSTextField(labelWithString: "Time remaining: --:--")
        countdownLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        countdownLabel.alignment = .center

        progressIndicator = NSProgressIndicator()
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.doubleValue = 0
        progressIndicator.controlSize = .small
        progressIndicator.style = .bar

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 36))
        countdownLabel.frame = NSRect(x: 0, y: 16, width: 240, height: 16)
        progressIndicator.frame = NSRect(x: 12, y: 2, width: 216, height: 10)
        container.addSubview(countdownLabel)
        container.addSubview(progressIndicator)

        countdownMenuItem = NSMenuItem()
        countdownMenuItem.view = container
        menu.addItem(countdownMenuItem)
        menu.addItem(NSMenuItem.separator())
    }

    private func setupObservers() {
        let wnc = NSWorkspace.shared.notificationCenter

        // Sleep/wake
        wnc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isCounting = false
            self?.log("WillSleep")
        }
        wnc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isCounting = true
            self?.lastTick = Date()
            self?.log("DidWake")
        }

        // Session active/inactive (reliable across macOS 13+)
        wnc.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isCounting = false
            self?.log("SessionResignActive")
        }
        wnc.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isCounting = true
            self?.lastTick = Date()
            self?.log("SessionBecomeActive")
        }

        // Optional lock/unlock distributed notifications (helpful when available)
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isCounting = false
            self?.log("ScreenLocked")
        }

        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isCounting = true
            self?.lastTick = Date()
            self?.log("ScreenUnlocked")
        }
    }

    private func tick() {
        normalizeForToday()
        syncAlertState()

        let now = Date()
        defer { lastTick = now }

        if isCounting {
            let dt = now.timeIntervalSince(lastTick)
            if dt > 0 && dt < 10 { // ignore huge jumps
                state.secondsUsedToday += dt
            }
        }

        if remainingSeconds() <= 0 && !state.didHitLimitToday {
            state.didHitLimitToday = true
            state.limitReachedAt = now
            state.postAlertsShown = Array(repeating: false, count: state.postAlertMinutes.count)
            log("LimitReached")
            speakPostAlertIfNeeded()
        }

        UsageState.save(state)
        updateUI()
    }

    private func normalizeForToday() {
        let start = Calendar.current.startOfDay(for: Date())
        if state.dayStart != start {
            state.dayStart = start
            state.secondsUsedToday = 0
            state.didHitLimitToday = false
            state.todayLimitOverride = nil  // Reset to default limit for new day
            popupsShownToday = 0  // Reset popup counter for new day
            lastPopupTime = nil
            state.popupsShownToday = 0
            state.lastPopupTime = nil
            state.spokePreAlert15 = false
            state.spokePreAlert5 = false
            state.spokePostAlert = false
            state.preAlertsSpoken = Array(repeating: false, count: state.preAlertMinutes.count)
            state.postAlertsShown = Array(repeating: false, count: state.postAlertMinutes.count)
            state.limitReachedAt = nil
            log("NewDayReset")
            UsageState.save(state)
        }
    }

    private func effectiveDailyLimit() -> TimeInterval {
        // Use today's override if set, otherwise use default
        state.todayLimitOverride ?? dailyLimitSeconds
    }

    private func remainingSeconds() -> TimeInterval {
        max(0, effectiveDailyLimit() - state.secondsUsedToday)
    }

    private func updateUI() {
        let rem = remainingSeconds()
        let mins = Int(ceil(rem / 60.0)) // show whole minutes remaining

        let over = (rem <= 0)
        let blinkOn = (Int(Date().timeIntervalSince1970) % 2 == 0)

        guard let button = statusItem.button else { return }

        if over {
            // Time is up - make it VERY annoying
            if blinkWhenOverLimit && !blinkOn {
                button.title = "                    " // long empty space
            } else {
                button.title = "⏰ TIME'S UP! ⏰" // much longer, more noticeable
            }

            // Red background and border when time is up
            if showBackgroundColor {
                button.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.8).cgColor
                button.layer?.borderColor = NSColor.systemRed.cgColor
            }

            // Show periodic popups
            speakPostAlertIfNeeded()
            showAnnoyingPopupIfNeeded()

        } else if mins <= 5 {
            // Warning mode - orange
            button.title = "\(mins)m"
            if showBackgroundColor {
                button.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.6).cgColor
                button.layer?.borderColor = NSColor.systemOrange.cgColor
            }
            speakPreAlertIfNeeded(remainingSeconds: rem)

        } else if mins <= 15 {
            // Caution mode - yellow
            button.title = "\(mins)m"
            if showBackgroundColor {
                button.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.5).cgColor
                button.layer?.borderColor = NSColor.systemYellow.cgColor
            }
            speakPreAlertIfNeeded(remainingSeconds: rem)

        } else {
            // Normal mode - green
            button.title = "\(mins)m"
            if showBackgroundColor {
                button.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.4).cgColor
                button.layer?.borderColor = NSColor.systemGreen.cgColor
            }
        }

        updateCountdownMenu(remainingSeconds: rem)
    }

    private func updateCountdownMenu(remainingSeconds: TimeInterval) {
        guard countdownLabel != nil else { return }
        let clampedRemaining = max(0, remainingSeconds)
        let totalSeconds = max(1, effectiveDailyLimit())
        let remainingInt = Int(clampedRemaining.rounded(.down))
        let minutes = remainingInt / 60
        let seconds = remainingInt % 60
        countdownLabel.stringValue = String(format: "Time remaining: %02d:%02d", minutes, seconds)
        let progress = min(1, max(0, state.secondsUsedToday / totalSeconds))
        progressIndicator.doubleValue = progress
    }

    private func speakPreAlertIfNeeded(remainingSeconds: TimeInterval) {
        let preAlertMinutes = normalizedPreAlertMinutes()
        guard !preAlertMinutes.isEmpty else { return }

        for index in preAlertMinutes.indices.reversed() {
            guard state.preAlertEnabled[safe: index] ?? true else { continue }
            let threshold = TimeInterval(preAlertMinutes[index] * 60)
            guard remainingSeconds <= threshold else { continue }
            guard index < state.preAlertsSpoken.count, !state.preAlertsSpoken[index] else { continue }

            state.preAlertsSpoken[index] = true
            let template = state.preAlertMessages[safe: index] ?? defaultPreAlertMessage(minutes: preAlertMinutes[index])
            let message = resolvedAlertMessage(template: template, minutes: preAlertMinutes[index])
            let voiceID = state.preAlertVoiceIDs[safe: index] ?? nil
            speak(message, voiceID: voiceID)
            log("SpokenPreAlert\(index + 1)")
            UsageState.save(state)
            break
        }
    }

    private func speakPostAlertIfNeeded() {
        guard !state.spokePostAlert else { return }
        guard state.limitReachedAlertEnabled else { return }
        state.spokePostAlert = true
        let template = state.limitReachedAlertMessage
        let message = resolvedAlertMessage(template: template, minutes: 0)
        speak(message, voiceID: state.limitReachedAlertVoiceID)
        log("SpokenPostAlert")
        UsageState.save(state)
    }

    private func speak(_ text: String, voiceID: NSSpeechSynthesizer.VoiceName?) {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking()
        }
        if let voiceID, NSSpeechSynthesizer.availableVoices.contains(voiceID) {
            speechSynthesizer.setVoice(voiceID)
        } else {
            speechSynthesizer.setVoice(nil)
        }
        speechSynthesizer.startSpeaking(text)
    }

    private func showAnnoyingPopupIfNeeded() {
        let now = Date()
        let maxAnnoyancePopups = max(0, state.maxAnnoyancePopups)

        let postAlertMinutes = normalizedPostAlertMinutes()
        guard let limitReachedAt = state.limitReachedAt else { return }
        guard popupsShownToday < maxAnnoyancePopups else { return }
        guard let nextIndex = postAlertMinutes.indices.first(where: { index in
            let threshold = TimeInterval(postAlertMinutes[index] * 60)
            return (state.postAlertEnabled[safe: index] ?? true)
                && !state.postAlertsShown[index]
                && now.timeIntervalSince(limitReachedAt) >= threshold
        }) else {
            return
        }

        let template = state.postAlertMessages[safe: nextIndex] ?? defaultPostAlertMessage(minutes: postAlertMinutes[nextIndex])
        let message = resolvedAlertMessage(template: template, minutes: postAlertMinutes[nextIndex])
        let voiceID = state.postAlertVoiceIDs[safe: nextIndex] ?? nil
        speak(message, voiceID: voiceID)

        state.postAlertsShown[nextIndex] = true
        popupsShownToday += 1
        state.popupsShownToday = popupsShownToday
        state.lastPopupTime = now
        UsageState.save(state)

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "⏰ SCREEN TIME IS UP! ⏰"
        alert.informativeText = """
        You've used all your screen time for today.

        \(message)
        """
        alert.addButton(withTitle: "OK, I understand")

        // Make it modal and bring to front
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()

        log("AnnoyancePopup[\(nextIndex + 1)/\(postAlertMinutes.count)]")
    }

    private func syncAlertState() {
        let normalizedPre = normalizedPreAlertMinutes()
        if normalizedPre != state.preAlertMinutes {
            state.preAlertMinutes = normalizedPre
            state.preAlertsSpoken = Array(repeating: false, count: normalizedPre.count)
        }

        let normalizedPost = normalizedPostAlertMinutes()
        if normalizedPost != state.postAlertMinutes {
            state.postAlertMinutes = normalizedPost
            state.postAlertsShown = Array(repeating: false, count: normalizedPost.count)
        }

        if state.preAlertsSpoken.count != state.preAlertMinutes.count {
            state.preAlertsSpoken = Array(repeating: false, count: state.preAlertMinutes.count)
        }
        if state.postAlertsShown.count != state.postAlertMinutes.count {
            state.postAlertsShown = Array(repeating: false, count: state.postAlertMinutes.count)
        }
        if state.preAlertEnabled.count != state.preAlertMinutes.count {
            state.preAlertEnabled = Array(repeating: true, count: state.preAlertMinutes.count)
        }
        if state.postAlertEnabled.count != state.postAlertMinutes.count {
            state.postAlertEnabled = Array(repeating: true, count: state.postAlertMinutes.count)
        }
        if state.preAlertMessages.count != state.preAlertMinutes.count {
            state.preAlertMessages = state.preAlertMinutes.map { defaultPreAlertMessage(minutes: $0) }
        }
        if state.postAlertMessages.count != state.postAlertMinutes.count {
            state.postAlertMessages = state.postAlertMinutes.map { defaultPostAlertMessage(minutes: $0) }
        }
        if state.preAlertVoiceIDs.count != state.preAlertMinutes.count {
            state.preAlertVoiceIDs = Array(repeating: nil, count: state.preAlertMinutes.count)
        }
        if state.postAlertVoiceIDs.count != state.postAlertMinutes.count {
            state.postAlertVoiceIDs = Array(repeating: nil, count: state.postAlertMinutes.count)
        }
    }

    private func normalizedPreAlertMinutes() -> [Int] {
        let minutes = state.preAlertMinutes.count == 3 ? state.preAlertMinutes : UsageState.defaultPreAlertMinutes
        return minutes.map { max(1, $0) }
    }

    private func normalizedPostAlertMinutes() -> [Int] {
        let minutes = state.postAlertMinutes.count == 5 ? state.postAlertMinutes : UsageState.defaultPostAlertMinutes
        return minutes.map { max(1, $0) }
    }

    private func defaultPreAlertMessage(minutes: Int) -> String {
        "\(minutes) minutes remaining."
    }

    private func defaultPostAlertMessage(minutes: Int) -> String {
        "\(minutes) minutes over your limit. Please take a break."
    }

    private func resolvedAlertMessage(template: String, minutes: Int) -> String {
        template.replacingOccurrences(of: "{minutes}", with: "\(minutes)")
    }

    @objc private func editTodayLimit() {
        // First, ask for PIN
        let pinAlert = NSAlert()
        pinAlert.messageText = "Edit Today's Time Limit"
        pinAlert.informativeText = "Enter PIN to modify today's time limit."
        pinAlert.alertStyle = .informational

        let pinField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        pinField.placeholderString = "PIN"
        pinAlert.accessoryView = pinField

        pinAlert.addButton(withTitle: "Continue")
        pinAlert.addButton(withTitle: "Cancel")

        let pinResp = pinAlert.runModal()
        guard pinResp == .alertFirstButtonReturn else { return }

        if pinField.stringValue != hardCodedPin {
            log("EditLimitBADPIN")
            let fail = NSAlert()
            fail.messageText = "Wrong PIN"
            fail.runModal()
            return
        }

        // PIN correct - now ask for new limit
        let limitAlert = NSAlert()
        limitAlert.messageText = "Set Today's Time Limit"

        let currentLimit = Int(effectiveDailyLimit() / 60)
        let used = Int(state.secondsUsedToday / 60)
        limitAlert.informativeText = """
        Current limit: \(currentLimit) minutes
        Time already used: \(used) minutes

        Enter new limit in minutes:
        """
        limitAlert.alertStyle = .informational

        let limitField = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        limitField.placeholderString = "Minutes (e.g., 90)"
        limitField.stringValue = "\(currentLimit)"
        limitAlert.accessoryView = limitField

        limitAlert.addButton(withTitle: "Set Limit")
        limitAlert.addButton(withTitle: "Cancel")

        let limitResp = limitAlert.runModal()
        guard limitResp == .alertFirstButtonReturn else { return }

        if let newMinutes = Int(limitField.stringValue), newMinutes > 0, newMinutes <= 1440 {
            let newSeconds = TimeInterval(newMinutes * 60)
            state.todayLimitOverride = newSeconds
            UsageState.save(state)
            log("LimitChangedTo[\(newMinutes)min]")
            updateUI()

            let confirm = NSAlert()
            confirm.messageText = "Limit Updated"
            confirm.informativeText = "Today's time limit set to \(newMinutes) minutes."
            confirm.runModal()
        } else {
            let error = NSAlert()
            error.messageText = "Invalid Input"
            error.informativeText = "Please enter a number between 1 and 1440 minutes (24 hours)."
            error.runModal()
        }
    }

    @objc private func editAlerts() {
        let pinAlert = NSAlert()
        pinAlert.messageText = "Edit Alert Settings"
        pinAlert.informativeText = "Enter PIN to edit alert settings."
        pinAlert.alertStyle = .informational

        let pinField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        pinField.placeholderString = "PIN"
        pinAlert.accessoryView = pinField

        pinAlert.addButton(withTitle: "Continue")
        pinAlert.addButton(withTitle: "Cancel")

        let pinResp = pinAlert.runModal()
        guard pinResp == .alertFirstButtonReturn else { return }

        if pinField.stringValue != hardCodedPin {
            log("EditAlertsBADPIN")
            let fail = NSAlert()
            fail.messageText = "Wrong PIN"
            fail.runModal()
            return
        }

        syncAlertState()

        let settingsAlert = NSAlert()
        settingsAlert.messageText = "Edit Alert Settings"
        settingsAlert.informativeText = "Toggle alerts on/off, adjust minutes, and edit spoken messages. Use {minutes} in a message to insert the alert minutes."
        settingsAlert.alertStyle = .informational

        let preAlertValues = normalizedPreAlertMinutes()
        let postAlertValues = normalizedPostAlertMinutes()

        let voiceOptions: [(name: String, id: NSSpeechSynthesizer.VoiceName?)] = {
            var options: [(String, NSSpeechSynthesizer.VoiceName?)] = [("System Default", nil)]
            let voices = NSSpeechSynthesizer.availableVoices.compactMap { voiceID -> (String, NSSpeechSynthesizer.VoiceName?) in
                let attrs = NSSpeechSynthesizer.attributes(forVoice: voiceID)
                let name = attrs[NSSpeechSynthesizer.VoiceAttributeKey.name] as? String ?? voiceID
                return (name, voiceID)
            }.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
            options.append(contentsOf: voices)
            return options
        }()

        func makeVoicePopup(selectedVoiceID: NSSpeechSynthesizer.VoiceName?) -> NSPopUpButton {
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26), pullsDown: false)
            popup.removeAllItems()
            for option in voiceOptions {
                let item = NSMenuItem(title: option.name, action: nil, keyEquivalent: "")
                item.representedObject = option.id
                popup.menu?.addItem(item)
            }
            if let selectedVoiceID,
               let selectedItem = popup.itemArray.first(where: { ($0.representedObject as? String) == selectedVoiceID }) {
                popup.select(selectedItem)
            } else {
                popup.selectItem(at: 0)
            }
            return popup
        }

        let limitReachedEnabledButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        limitReachedEnabledButton.state = state.limitReachedAlertEnabled ? .on : .off
        let limitReachedMessageField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        limitReachedMessageField.stringValue = state.limitReachedAlertMessage
        let limitReachedVoicePopup = makeVoicePopup(selectedVoiceID: state.limitReachedAlertVoiceID)

        var preAlertEnabledButtons: [NSButton] = []
        var preAlertFields: [NSTextField] = []
        var preAlertMessageFields: [NSTextField] = []
        var preAlertVoicePopups: [NSPopUpButton] = []

        for index in 0..<3 {
            let enabledButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            enabledButton.state = (state.preAlertEnabled[safe: index] ?? true) ? .on : .off

            let value = preAlertValues[safe: index] ?? UsageState.defaultPreAlertMinutes[index]
            let minutesField = NSTextField(frame: NSRect(x: 0, y: 0, width: 70, height: 22))
            minutesField.stringValue = "\(value)"

            let messageField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
            let message = state.preAlertMessages[safe: index] ?? defaultPreAlertMessage(minutes: value)
            messageField.stringValue = message

            let voicePopup = makeVoicePopup(selectedVoiceID: state.preAlertVoiceIDs[safe: index] ?? nil)

            preAlertEnabledButtons.append(enabledButton)
            preAlertFields.append(minutesField)
            preAlertMessageFields.append(messageField)
            preAlertVoicePopups.append(voicePopup)
        }

        var postAlertEnabledButtons: [NSButton] = []
        var postAlertFields: [NSTextField] = []
        var postAlertMessageFields: [NSTextField] = []
        var postAlertVoicePopups: [NSPopUpButton] = []

        for index in 0..<5 {
            let enabledButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            enabledButton.state = (state.postAlertEnabled[safe: index] ?? true) ? .on : .off

            let value = postAlertValues[safe: index] ?? UsageState.defaultPostAlertMinutes[index]
            let minutesField = NSTextField(frame: NSRect(x: 0, y: 0, width: 70, height: 22))
            minutesField.stringValue = "\(value)"

            let messageField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
            let message = state.postAlertMessages[safe: index] ?? defaultPostAlertMessage(minutes: value)
            messageField.stringValue = message

            let voicePopup = makeVoicePopup(selectedVoiceID: state.postAlertVoiceIDs[safe: index] ?? nil)

            postAlertEnabledButtons.append(enabledButton)
            postAlertFields.append(minutesField)
            postAlertMessageFields.append(messageField)
            postAlertVoicePopups.append(voicePopup)
        }

        func headerLabel(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
            return label
        }

        func gridHeaderRow() -> [NSView] {
            [
                NSTextField(labelWithString: "On"),
                NSTextField(labelWithString: "Minutes"),
                NSTextField(labelWithString: "Spoken Message"),
                NSTextField(labelWithString: "Voice")
            ]
        }

        let limitReachedGrid = NSGridView(views: [
            gridHeaderRow(),
            [limitReachedEnabledButton, NSTextField(labelWithString: "Limit reached"), limitReachedMessageField, limitReachedVoicePopup]
        ])
        limitReachedGrid.rowSpacing = 6
        limitReachedGrid.columnSpacing = 8
        limitReachedGrid.column(at: 2).width = 280

        let preAlertRows = preAlertFields.indices.map { index -> [NSView] in
            [
                preAlertEnabledButtons[index],
                preAlertFields[index],
                preAlertMessageFields[index],
                preAlertVoicePopups[index]
            ]
        }
        let preAlertGrid = NSGridView(views: [gridHeaderRow()] + preAlertRows)
        preAlertGrid.rowSpacing = 6
        preAlertGrid.columnSpacing = 8
        preAlertGrid.column(at: 2).width = 280

        let postAlertRows = postAlertFields.indices.map { index -> [NSView] in
            [
                postAlertEnabledButtons[index],
                postAlertFields[index],
                postAlertMessageFields[index],
                postAlertVoicePopups[index]
            ]
        }
        let postAlertGrid = NSGridView(views: [gridHeaderRow()] + postAlertRows)
        postAlertGrid.rowSpacing = 6
        postAlertGrid.columnSpacing = 8
        postAlertGrid.column(at: 2).width = 280

        let stack = NSStackView(views: [
            headerLabel("Limit Reached Announcement"),
            limitReachedGrid,
            headerLabel("Pre-alerts (minutes before limit)"),
            preAlertGrid,
            headerLabel("Post-alerts (minutes after limit)"),
            postAlertGrid
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 12, right: 0)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 720, height: 420))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.documentView = stack
        stack.frame = NSRect(x: 0, y: 0, width: 720, height: stack.fittingSize.height)

        settingsAlert.accessoryView = scrollView
        settingsAlert.addButton(withTitle: "Save")
        settingsAlert.addButton(withTitle: "Cancel")

        let settingsResp = settingsAlert.runModal()
        guard settingsResp == .alertFirstButtonReturn else { return }

        func parseMinutes(field: NSTextField, fallback: Int, enabled: Bool) -> Int? {
            let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return enabled ? nil : fallback
            }
            if let value = Int(trimmed) {
                return value
            }
            return enabled ? nil : fallback
        }

        let preAlertEnabled = preAlertEnabledButtons.map { $0.state == .on }
        let postAlertEnabled = postAlertEnabledButtons.map { $0.state == .on }

        var preAlertInputs: [Int] = []
        var preAlertMessages: [String] = []
        var preAlertVoiceIDs: [String?] = []

        for index in preAlertFields.indices {
            let enabled = preAlertEnabled[index]
            let fallback = preAlertValues[safe: index] ?? UsageState.defaultPreAlertMinutes[index]
            guard let minutes = parseMinutes(field: preAlertFields[index], fallback: fallback, enabled: enabled) else {
                let error = NSAlert()
                error.messageText = "Invalid Input"
                error.informativeText = "Please enter whole numbers for enabled pre-alerts."
                error.runModal()
                return
            }
            preAlertInputs.append(minutes)

            let trimmedMessage = preAlertMessageFields[index].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = trimmedMessage.isEmpty ? defaultPreAlertMessage(minutes: minutes) : trimmedMessage
            preAlertMessages.append(message)

            let voiceID = preAlertVoicePopups[index].selectedItem?.representedObject as? NSSpeechSynthesizer.VoiceName
            preAlertVoiceIDs.append(voiceID)
        }

        var postAlertInputs: [Int] = []
        var postAlertMessages: [String] = []
        var postAlertVoiceIDs: [String?] = []

        for index in postAlertFields.indices {
            let enabled = postAlertEnabled[index]
            let fallback = postAlertValues[safe: index] ?? UsageState.defaultPostAlertMinutes[index]
            guard let minutes = parseMinutes(field: postAlertFields[index], fallback: fallback, enabled: enabled) else {
                let error = NSAlert()
                error.messageText = "Invalid Input"
                error.informativeText = "Please enter whole numbers for enabled post-alerts."
                error.runModal()
                return
            }
            postAlertInputs.append(minutes)

            let trimmedMessage = postAlertMessageFields[index].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = trimmedMessage.isEmpty ? defaultPostAlertMessage(minutes: minutes) : trimmedMessage
            postAlertMessages.append(message)

            let voiceID = postAlertVoicePopups[index].selectedItem?.representedObject as? NSSpeechSynthesizer.VoiceName
            postAlertVoiceIDs.append(voiceID)
        }

        guard preAlertInputs.allSatisfy({ $0 >= 1 && $0 <= 1440 }),
              postAlertInputs.allSatisfy({ $0 >= 1 && $0 <= 1440 }) else {
            let error = NSAlert()
            error.messageText = "Invalid Alert Minutes"
            error.informativeText = "Alert minutes must be between 1 and 1440."
            error.runModal()
            return
        }

        guard preAlertInputs.enumerated().allSatisfy({ index, value in
            index == 0 || value < preAlertInputs[index - 1]
        }) else {
            let error = NSAlert()
            error.messageText = "Invalid Pre-Alert Order"
            error.informativeText = "Pre-alerts must be in descending order (largest to smallest)."
            error.runModal()
            return
        }

        guard postAlertInputs.enumerated().allSatisfy({ index, value in
            index == 0 || value > postAlertInputs[index - 1]
        }) else {
            let error = NSAlert()
            error.messageText = "Invalid Post-Alert Order"
            error.informativeText = "Post-alerts must be in ascending order (smallest to largest)."
            error.runModal()
            return
        }

        let limitReachedEnabled = limitReachedEnabledButton.state == .on
        let limitReachedMessageTrimmed = limitReachedMessageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let limitReachedMessage = limitReachedMessageTrimmed.isEmpty ? UsageState.defaultLimitReachedAlertMessage : limitReachedMessageTrimmed
        let limitReachedVoiceID = limitReachedVoicePopup.selectedItem?.representedObject as? NSSpeechSynthesizer.VoiceName

        state.preAlertMinutes = preAlertInputs
        state.postAlertMinutes = postAlertInputs
        state.preAlertEnabled = preAlertEnabled
        state.postAlertEnabled = postAlertEnabled
        state.preAlertMessages = preAlertMessages
        state.postAlertMessages = postAlertMessages
        state.preAlertVoiceIDs = preAlertVoiceIDs
        state.postAlertVoiceIDs = postAlertVoiceIDs
        state.limitReachedAlertEnabled = limitReachedEnabled
        state.limitReachedAlertMessage = limitReachedMessage
        state.limitReachedAlertVoiceID = limitReachedVoiceID
        state.preAlert15Minutes = preAlertInputs.first ?? UsageState.defaultPreAlert15Minutes
        state.preAlert5Minutes = preAlertInputs.dropFirst().first ?? UsageState.defaultPreAlert5Minutes
        state.maxAnnoyancePopups = postAlertEnabled.filter { $0 }.count
        popupsShownToday = min(popupsShownToday, state.maxAnnoyancePopups)
        state.popupsShownToday = popupsShownToday
        state.preAlertsSpoken = Array(repeating: false, count: preAlertInputs.count)
        state.postAlertsShown = Array(repeating: false, count: postAlertInputs.count)
        state.spokePreAlert15 = false
        state.spokePreAlert5 = false
        UsageState.save(state)
        log("EditAlertsOK[pre=\(preAlertInputs),post=\(postAlertInputs)]")
        updateUI()
    }

    @objc private func resetWithPin() {
        let alert = NSAlert()
        alert.messageText = "Reset today's time?"
        alert.informativeText = "Enter PIN to reset usage for today."
        alert.alertStyle = .warning

        let pinField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        pinField.placeholderString = "PIN"
        alert.accessoryView = pinField

        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")

        let resp = alert.runModal()
        guard resp == .alertFirstButtonReturn else { return }

        if pinField.stringValue == hardCodedPin {
            state.secondsUsedToday = 0
            state.didHitLimitToday = false
            popupsShownToday = 0  // Reset popup counter
            lastPopupTime = nil
            state.popupsShownToday = 0
            state.lastPopupTime = nil
            state.spokePreAlert15 = false
            state.spokePreAlert5 = false
            state.spokePostAlert = false
            state.preAlertsSpoken = Array(repeating: false, count: state.preAlertMinutes.count)
            state.postAlertsShown = Array(repeating: false, count: state.postAlertMinutes.count)
            state.limitReachedAt = nil
            UsageState.save(state)
            log("ManualResetOK")
            updateUI()
        } else {
            log("ManualResetBADPIN")
            let fail = NSAlert()
            fail.messageText = "Wrong PIN"
            fail.runModal()
        }
    }

    @objc private func openLogFolder() {
        NSWorkspace.shared.open(Logger.logFileURL.deletingLastPathComponent())
    }

    @objc private func quit() {
        let alert = NSAlert()
        alert.messageText = "Quit SimpleScreenTime?"
        alert.informativeText = "Enter PIN to quit."
        alert.alertStyle = .warning

        let pinField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        pinField.placeholderString = "PIN"
        alert.accessoryView = pinField

        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        let resp = alert.runModal()
        guard resp == .alertFirstButtonReturn else { return }

        if pinField.stringValue == hardCodedPin {
            log("QuitWithPIN")
            NSApp.terminate(nil)
        } else {
            log("QuitBADPIN")
            let fail = NSAlert()
            fail.messageText = "Wrong PIN"
            fail.runModal()
        }
    }

    private func log(_ event: String) {
        Logger.append(event: event,
                      used: Int(state.secondsUsedToday),
                      remaining: Int(remainingSeconds()))
    }
}

struct UsageState: Codable {
    var dayStart: Date
    var secondsUsedToday: TimeInterval
    var didHitLimitToday: Bool
    var todayLimitOverride: TimeInterval?  // Optional override for today's limit
    var popupsShownToday: Int
    var lastPopupTime: Date?
    var spokePreAlert15: Bool
    var spokePreAlert5: Bool
    var spokePostAlert: Bool
    var preAlert15Minutes: Int
    var preAlert5Minutes: Int
    var maxAnnoyancePopups: Int
    var preAlertMinutes: [Int]
    var postAlertMinutes: [Int]
    var preAlertsSpoken: [Bool]
    var postAlertsShown: [Bool]
    var limitReachedAt: Date?
    var preAlertEnabled: [Bool]
    var postAlertEnabled: [Bool]
    var preAlertMessages: [String]
    var postAlertMessages: [String]
    var preAlertVoiceIDs: [NSSpeechSynthesizer.VoiceName?]
    var postAlertVoiceIDs: [NSSpeechSynthesizer.VoiceName?]
    var limitReachedAlertEnabled: Bool
    var limitReachedAlertMessage: String
    var limitReachedAlertVoiceID: NSSpeechSynthesizer.VoiceName?

    private enum CodingKeys: String, CodingKey {
        case dayStart
        case secondsUsedToday
        case didHitLimitToday
        case todayLimitOverride
        case popupsShownToday
        case lastPopupTime
        case spokePreAlert15
        case spokePreAlert5
        case spokePostAlert
        case preAlert15Minutes
        case preAlert5Minutes
        case maxAnnoyancePopups
        case preAlertMinutes
        case postAlertMinutes
        case preAlertsSpoken
        case postAlertsShown
        case limitReachedAt
        case preAlertEnabled
        case postAlertEnabled
        case preAlertMessages
        case postAlertMessages
        case preAlertVoiceIDs
        case postAlertVoiceIDs
        case limitReachedAlertEnabled
        case limitReachedAlertMessage
        case limitReachedAlertVoiceID
    }

    init(dayStart: Date,
         secondsUsedToday: TimeInterval,
         didHitLimitToday: Bool,
         todayLimitOverride: TimeInterval?,
         popupsShownToday: Int,
         lastPopupTime: Date?,
         spokePreAlert15: Bool,
         spokePreAlert5: Bool,
         spokePostAlert: Bool,
         preAlert15Minutes: Int,
         preAlert5Minutes: Int,
         maxAnnoyancePopups: Int,
         preAlertMinutes: [Int],
         postAlertMinutes: [Int],
         preAlertsSpoken: [Bool],
         postAlertsShown: [Bool],
         limitReachedAt: Date?,
         preAlertEnabled: [Bool],
         postAlertEnabled: [Bool],
         preAlertMessages: [String],
         postAlertMessages: [String],
         preAlertVoiceIDs: [NSSpeechSynthesizer.VoiceName?],
         postAlertVoiceIDs: [NSSpeechSynthesizer.VoiceName?],
         limitReachedAlertEnabled: Bool,
         limitReachedAlertMessage: String,
         limitReachedAlertVoiceID: NSSpeechSynthesizer.VoiceName?) {
        self.dayStart = dayStart
        self.secondsUsedToday = secondsUsedToday
        self.didHitLimitToday = didHitLimitToday
        self.todayLimitOverride = todayLimitOverride
        self.popupsShownToday = popupsShownToday
        self.lastPopupTime = lastPopupTime
        self.spokePreAlert15 = spokePreAlert15
        self.spokePreAlert5 = spokePreAlert5
        self.spokePostAlert = spokePostAlert
        self.preAlert15Minutes = preAlert15Minutes
        self.preAlert5Minutes = preAlert5Minutes
        self.maxAnnoyancePopups = maxAnnoyancePopups
        self.preAlertMinutes = preAlertMinutes
        self.postAlertMinutes = postAlertMinutes
        self.preAlertsSpoken = preAlertsSpoken
        self.postAlertsShown = postAlertsShown
        self.limitReachedAt = limitReachedAt
        self.preAlertEnabled = preAlertEnabled
        self.postAlertEnabled = postAlertEnabled
        self.preAlertMessages = preAlertMessages
        self.postAlertMessages = postAlertMessages
        self.preAlertVoiceIDs = preAlertVoiceIDs
        self.postAlertVoiceIDs = postAlertVoiceIDs
        self.limitReachedAlertEnabled = limitReachedAlertEnabled
        self.limitReachedAlertMessage = limitReachedAlertMessage
        self.limitReachedAlertVoiceID = limitReachedAlertVoiceID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dayStart = try container.decode(Date.self, forKey: .dayStart)
        secondsUsedToday = try container.decode(TimeInterval.self, forKey: .secondsUsedToday)
        didHitLimitToday = try container.decode(Bool.self, forKey: .didHitLimitToday)
        todayLimitOverride = try container.decodeIfPresent(TimeInterval.self, forKey: .todayLimitOverride)
        popupsShownToday = try container.decodeIfPresent(Int.self, forKey: .popupsShownToday) ?? 0
        lastPopupTime = try container.decodeIfPresent(Date.self, forKey: .lastPopupTime)
        spokePreAlert15 = try container.decodeIfPresent(Bool.self, forKey: .spokePreAlert15) ?? false
        spokePreAlert5 = try container.decodeIfPresent(Bool.self, forKey: .spokePreAlert5) ?? false
        spokePostAlert = try container.decodeIfPresent(Bool.self, forKey: .spokePostAlert) ?? false
        preAlert15Minutes = try container.decodeIfPresent(Int.self, forKey: .preAlert15Minutes) ?? UsageState.defaultPreAlert15Minutes
        preAlert5Minutes = try container.decodeIfPresent(Int.self, forKey: .preAlert5Minutes) ?? UsageState.defaultPreAlert5Minutes
        maxAnnoyancePopups = try container.decodeIfPresent(Int.self, forKey: .maxAnnoyancePopups) ?? UsageState.defaultMaxAnnoyancePopups
        preAlertMinutes = try container.decodeIfPresent([Int].self, forKey: .preAlertMinutes) ?? UsageState.defaultPreAlertMinutes
        postAlertMinutes = try container.decodeIfPresent([Int].self, forKey: .postAlertMinutes) ?? UsageState.defaultPostAlertMinutes
        preAlertsSpoken = try container.decodeIfPresent([Bool].self, forKey: .preAlertsSpoken) ?? Array(repeating: false, count: preAlertMinutes.count)
        postAlertsShown = try container.decodeIfPresent([Bool].self, forKey: .postAlertsShown) ?? Array(repeating: false, count: postAlertMinutes.count)
        limitReachedAt = try container.decodeIfPresent(Date.self, forKey: .limitReachedAt)
        preAlertEnabled = try container.decodeIfPresent([Bool].self, forKey: .preAlertEnabled) ?? UsageState.defaultPreAlertEnabled
        postAlertEnabled = try container.decodeIfPresent([Bool].self, forKey: .postAlertEnabled) ?? UsageState.defaultPostAlertEnabled
        preAlertMessages = try container.decodeIfPresent([String].self, forKey: .preAlertMessages)
            ?? UsageState.defaultPreAlertMinutes.map { UsageState.defaultPreAlertMessage(minutes: $0) }
        postAlertMessages = try container.decodeIfPresent([String].self, forKey: .postAlertMessages)
            ?? UsageState.defaultPostAlertMinutes.map { UsageState.defaultPostAlertMessage(minutes: $0) }
        let decodedPreAlertVoiceIDs = try container.decodeIfPresent([String?].self, forKey: .preAlertVoiceIDs)
            ?? Array(repeating: nil, count: preAlertMinutes.count)
        preAlertVoiceIDs = decodedPreAlertVoiceIDs.map { $0 }
        let decodedPostAlertVoiceIDs = try container.decodeIfPresent([String?].self, forKey: .postAlertVoiceIDs)
            ?? Array(repeating: nil, count: postAlertMinutes.count)
        postAlertVoiceIDs = decodedPostAlertVoiceIDs.map { $0 }
        limitReachedAlertEnabled = try container.decodeIfPresent(Bool.self, forKey: .limitReachedAlertEnabled) ?? true
        limitReachedAlertMessage = try container.decodeIfPresent(String.self, forKey: .limitReachedAlertMessage)
            ?? UsageState.defaultLimitReachedAlertMessage
        if let decodedVoiceID = try container.decodeIfPresent(String.self, forKey: .limitReachedAlertVoiceID) {
            limitReachedAlertVoiceID = decodedVoiceID
        } else {
            limitReachedAlertVoiceID = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dayStart, forKey: .dayStart)
        try container.encode(secondsUsedToday, forKey: .secondsUsedToday)
        try container.encode(didHitLimitToday, forKey: .didHitLimitToday)
        try container.encodeIfPresent(todayLimitOverride, forKey: .todayLimitOverride)
        try container.encode(popupsShownToday, forKey: .popupsShownToday)
        try container.encodeIfPresent(lastPopupTime, forKey: .lastPopupTime)
        try container.encode(spokePreAlert15, forKey: .spokePreAlert15)
        try container.encode(spokePreAlert5, forKey: .spokePreAlert5)
        try container.encode(spokePostAlert, forKey: .spokePostAlert)
        try container.encode(preAlert15Minutes, forKey: .preAlert15Minutes)
        try container.encode(preAlert5Minutes, forKey: .preAlert5Minutes)
        try container.encode(maxAnnoyancePopups, forKey: .maxAnnoyancePopups)
        try container.encode(preAlertMinutes, forKey: .preAlertMinutes)
        try container.encode(postAlertMinutes, forKey: .postAlertMinutes)
        try container.encode(preAlertsSpoken, forKey: .preAlertsSpoken)
        try container.encode(postAlertsShown, forKey: .postAlertsShown)
        try container.encodeIfPresent(limitReachedAt, forKey: .limitReachedAt)
        try container.encode(preAlertEnabled, forKey: .preAlertEnabled)
        try container.encode(postAlertEnabled, forKey: .postAlertEnabled)
        try container.encode(preAlertMessages, forKey: .preAlertMessages)
        try container.encode(postAlertMessages, forKey: .postAlertMessages)
        let encodedPreAlertVoiceIDs = preAlertVoiceIDs.map { $0 as String? }
        let encodedPostAlertVoiceIDs = postAlertVoiceIDs.map { $0 as String? }
        try container.encode(encodedPreAlertVoiceIDs, forKey: .preAlertVoiceIDs)
        try container.encode(encodedPostAlertVoiceIDs, forKey: .postAlertVoiceIDs)
        try container.encode(limitReachedAlertEnabled, forKey: .limitReachedAlertEnabled)
        try container.encode(limitReachedAlertMessage, forKey: .limitReachedAlertMessage)
        try container.encodeIfPresent(limitReachedAlertVoiceID as String?, forKey: .limitReachedAlertVoiceID)
    }

    static func load() -> UsageState {
        if let data = try? Data(contentsOf: stateURL),
           let s = try? JSONDecoder().decode(UsageState.self, from: data) {
            return s
        }
        return UsageState(dayStart: Calendar.current.startOfDay(for: Date()),
                          secondsUsedToday: 0,
                          didHitLimitToday: false,
                          todayLimitOverride: nil,
                          popupsShownToday: 0,
                          lastPopupTime: nil,
                          spokePreAlert15: false,
                          spokePreAlert5: false,
                          spokePostAlert: false,
                          preAlert15Minutes: UsageState.defaultPreAlert15Minutes,
                          preAlert5Minutes: UsageState.defaultPreAlert5Minutes,
                          maxAnnoyancePopups: UsageState.defaultMaxAnnoyancePopups,
                          preAlertMinutes: UsageState.defaultPreAlertMinutes,
                          postAlertMinutes: UsageState.defaultPostAlertMinutes,
                          preAlertsSpoken: Array(repeating: false, count: UsageState.defaultPreAlertMinutes.count),
                          postAlertsShown: Array(repeating: false, count: UsageState.defaultPostAlertMinutes.count),
                          limitReachedAt: nil,
                          preAlertEnabled: UsageState.defaultPreAlertEnabled,
                          postAlertEnabled: UsageState.defaultPostAlertEnabled,
                          preAlertMessages: UsageState.defaultPreAlertMinutes.map { UsageState.defaultPreAlertMessage(minutes: $0) },
                          postAlertMessages: UsageState.defaultPostAlertMinutes.map { UsageState.defaultPostAlertMessage(minutes: $0) },
                          preAlertVoiceIDs: Array(repeating: nil, count: UsageState.defaultPreAlertMinutes.count),
                          postAlertVoiceIDs: Array(repeating: nil, count: UsageState.defaultPostAlertMinutes.count),
                          limitReachedAlertEnabled: true,
                          limitReachedAlertMessage: UsageState.defaultLimitReachedAlertMessage,
                          limitReachedAlertVoiceID: nil)
    }

    static func save(_ state: UsageState) {
        do {
            try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateURL, options: [.atomic])
        } catch {
            // best-effort
        }
    }

    private static var appSupportURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("SimpleScreenTime", isDirectory: true)
    }
    private static var stateURL: URL {
        appSupportURL.appendingPathComponent("state.json")
    }

    static let defaultPreAlert15Minutes = 15
    static let defaultPreAlert5Minutes = 5
    static let defaultMaxAnnoyancePopups = 5
    static let defaultPreAlertMinutes = [15, 5, 1]
    static let defaultPostAlertMinutes = [1, 3, 5, 10, 15]
    static let defaultPreAlertEnabled = [true, true, true]
    static let defaultPostAlertEnabled = [true, true, true, true, true]
    static let defaultLimitReachedAlertMessage = "Screen time is up. Please take a break."

    static func defaultPreAlertMessage(minutes: Int) -> String {
        "\(minutes) minutes remaining."
    }

    static func defaultPostAlertMessage(minutes: Int) -> String {
        "\(minutes) minutes over your limit. Please take a break."
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

enum Logger {
    static var logDirURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("SimpleScreenTime", isDirectory: true)
    }
    static var logFileURL: URL {
        logDirURL.appendingPathComponent("events.log")
    }

    static func append(event: String, used: Int, remaining: Int) {
        do {
            try FileManager.default.createDirectory(at: logDirURL, withIntermediateDirectories: true)
            let ts = ISO8601DateFormatter().string(from: Date())
            let line = "\(ts)\t\(event)\tused=\(used)s\tremaining=\(remaining)s\n"
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                let h = try FileHandle(forWritingTo: logFileURL)
                try h.seekToEnd()
                h.write(line.data(using: .utf8)!)
                try h.close()
            } else {
                try line.write(to: logFileURL, atomically: true, encoding: .utf8)
            }
        } catch {
            // best-effort
        }
    }
}
