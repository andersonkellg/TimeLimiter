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
        let alertMinutes = normalizedPreAlertMinutes()
        let alertPairs = Array(zip(alertMinutes, state.preAlertsSpoken))
        guard let nextIndex = alertPairs.firstIndex(where: { minutes, spoken in
            !spoken && remainingSeconds <= TimeInterval(minutes * 60)
        }) else {
            return
        }

        state.preAlertsSpoken[nextIndex] = true
        speak("\(alertMinutes[nextIndex]) minutes remaining.")
        log("SpokenPreAlert[\(alertMinutes[nextIndex])m]")
        UsageState.save(state)
    }

    private func speakPostAlertIfNeeded() {
        guard !state.spokePostAlert else { return }
        state.spokePostAlert = true
        speak("Screen time is up. Please take a break.")
        log("SpokenPostAlert")
        UsageState.save(state)
    }

    private func speak(_ text: String) {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking()
        }
        speechSynthesizer.startSpeaking(text)
    }

    private func showAnnoyingPopupIfNeeded() {
        let now = Date()
        guard let limitReachedAt = state.limitReachedAt else { return }

        let postAlertMinutes = normalizedPostAlertMinutes()
        guard let nextIndex = postAlertMinutes.indices.first(where: { index in
            let threshold = TimeInterval(postAlertMinutes[index] * 60)
            return !state.postAlertsShown[index] && now.timeIntervalSince(limitReachedAt) >= threshold
        }) else {
            return
        }

        state.postAlertsShown[nextIndex] = true
        UsageState.save(state)

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "⏰ SCREEN TIME IS UP! ⏰"
        alert.informativeText = """
        You've used all your screen time for today.

        Please take a break from the computer.
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
    }

    private func normalizedPreAlertMinutes() -> [Int] {
        let minutes = state.preAlertMinutes.count == 3 ? state.preAlertMinutes : UsageState.defaultPreAlertMinutes
        let cleaned = minutes.map { max(1, $0) }
        return cleaned.sorted(by: >)
    }

    private func normalizedPostAlertMinutes() -> [Int] {
        let minutes = state.postAlertMinutes.count == 5 ? state.postAlertMinutes : UsageState.defaultPostAlertMinutes
        let cleaned = minutes.map { max(1, $0) }
        return cleaned.sorted()
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

        let settingsAlert = NSAlert()
        settingsAlert.messageText = "Edit Alert Settings"
        settingsAlert.informativeText = "Set the minutes for 3 pre-alerts and 5 post-alert popups."
        settingsAlert.alertStyle = .informational

        let preAlertMinutes = normalizedPreAlertMinutes()
        let preAlertFields = preAlertMinutes.enumerated().map { index, value -> NSTextField in
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 70, height: 22))
            field.placeholderString = "\(value)"
            field.stringValue = "\(value)"
            field.alignment = .right
            return field
        }

        let postAlertMinutes = normalizedPostAlertMinutes()
        let postAlertFields = postAlertMinutes.enumerated().map { index, value -> NSTextField in
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 70, height: 22))
            field.placeholderString = "\(value)"
            field.stringValue = "\(value)"
            field.alignment = .right
            return field
        }

        let rows: [[NSView]] = [
            [NSTextField(labelWithString: "Pre-alert 1 (minutes remaining):"), preAlertFields[0]],
            [NSTextField(labelWithString: "Pre-alert 2 (minutes remaining):"), preAlertFields[1]],
            [NSTextField(labelWithString: "Pre-alert 3 (minutes remaining):"), preAlertFields[2]],
            [NSTextField(labelWithString: "Post-alert 1 (minutes after limit):"), postAlertFields[0]],
            [NSTextField(labelWithString: "Post-alert 2 (minutes after limit):"), postAlertFields[1]],
            [NSTextField(labelWithString: "Post-alert 3 (minutes after limit):"), postAlertFields[2]],
            [NSTextField(labelWithString: "Post-alert 4 (minutes after limit):"), postAlertFields[3]],
            [NSTextField(labelWithString: "Post-alert 5 (minutes after limit):"), postAlertFields[4]]
        ]

        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 260))
        container.addSubview(grid)

        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            grid.topAnchor.constraint(equalTo: container.topAnchor),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        settingsAlert.accessoryView = container
        settingsAlert.addButton(withTitle: "Save")
        settingsAlert.addButton(withTitle: "Cancel")

        let settingsResp = settingsAlert.runModal()
        guard settingsResp == .alertFirstButtonReturn else { return }

        let preAlertInputs = preAlertFields.compactMap { Int($0.stringValue) }
        let postAlertInputs = postAlertFields.compactMap { Int($0.stringValue) }
        guard preAlertInputs.count == preAlertFields.count,
              postAlertInputs.count == postAlertFields.count else {
            let error = NSAlert()
            error.messageText = "Invalid Input"
            error.informativeText = "Please enter whole numbers for every alert field."
            error.runModal()
            return
        }

        let preAlertSorted = preAlertInputs.sorted(by: >)
        guard preAlertSorted.count == 3,
              preAlertSorted[0] > preAlertSorted[1],
              preAlertSorted[1] > preAlertSorted[2],
              preAlertSorted.allSatisfy({ $0 >= 1 && $0 <= 1440 }) else {
            let error = NSAlert()
            error.messageText = "Invalid Alert Minutes"
            error.informativeText = "Pre-alerts must be three distinct values between 1 and 1440 minutes, ordered from largest to smallest."
            error.runModal()
            return
        }

        let postAlertSorted = postAlertInputs.sorted()
        guard postAlertSorted.count == 5,
              postAlertSorted.allSatisfy({ $0 >= 1 && $0 <= 1440 }),
              postAlertSorted == postAlertSorted.sorted(),
              Set(postAlertSorted).count == postAlertSorted.count else {
            let error = NSAlert()
            error.messageText = "Invalid Post-alert Minutes"
            error.informativeText = "Post-alerts must be five distinct values between 1 and 1440 minutes, ordered from smallest to largest."
            error.runModal()
            return
        }

        state.preAlertMinutes = preAlertSorted
        state.postAlertMinutes = postAlertSorted
        state.preAlertsSpoken = Array(repeating: false, count: preAlertSorted.count)
        state.postAlertsShown = Array(repeating: false, count: postAlertSorted.count)
        state.spokePreAlert15 = false
        state.spokePreAlert5 = false
        state.limitReachedAt = nil
        UsageState.save(state)
        let preAlertSummary = preAlertSorted.map(String.init).joined(separator: ",")
        let postAlertSummary = postAlertSorted.map(String.init).joined(separator: ",")
        log("EditAlertsOK[pre=\(preAlertSummary),post=\(postAlertSummary)]")
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
    var preAlertMinutes: [Int]
    var postAlertMinutes: [Int]
    var preAlertsSpoken: [Bool]
    var postAlertsShown: [Bool]
    var limitReachedAt: Date?

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
        case preAlertMinutes
        case postAlertMinutes
        case preAlertsSpoken
        case postAlertsShown
        case limitReachedAt
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
         preAlertMinutes: [Int],
         postAlertMinutes: [Int],
         preAlertsSpoken: [Bool],
         postAlertsShown: [Bool],
         limitReachedAt: Date?) {
        self.dayStart = dayStart
        self.secondsUsedToday = secondsUsedToday
        self.didHitLimitToday = didHitLimitToday
        self.todayLimitOverride = todayLimitOverride
        self.popupsShownToday = popupsShownToday
        self.lastPopupTime = lastPopupTime
        self.spokePreAlert15 = spokePreAlert15
        self.spokePreAlert5 = spokePreAlert5
        self.spokePostAlert = spokePostAlert
        self.preAlertMinutes = preAlertMinutes
        self.postAlertMinutes = postAlertMinutes
        self.preAlertsSpoken = preAlertsSpoken
        self.postAlertsShown = postAlertsShown
        self.limitReachedAt = limitReachedAt
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
        preAlertMinutes = try container.decodeIfPresent([Int].self, forKey: .preAlertMinutes) ?? UsageState.defaultPreAlertMinutes
        postAlertMinutes = try container.decodeIfPresent([Int].self, forKey: .postAlertMinutes) ?? UsageState.defaultPostAlertMinutes
        preAlertsSpoken = try container.decodeIfPresent([Bool].self, forKey: .preAlertsSpoken) ?? Array(repeating: false, count: preAlertMinutes.count)
        postAlertsShown = try container.decodeIfPresent([Bool].self, forKey: .postAlertsShown) ?? Array(repeating: false, count: postAlertMinutes.count)
        limitReachedAt = try container.decodeIfPresent(Date.self, forKey: .limitReachedAt)
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
        try container.encode(preAlertMinutes, forKey: .preAlertMinutes)
        try container.encode(postAlertMinutes, forKey: .postAlertMinutes)
        try container.encode(preAlertsSpoken, forKey: .preAlertsSpoken)
        try container.encode(postAlertsShown, forKey: .postAlertsShown)
        try container.encodeIfPresent(limitReachedAt, forKey: .limitReachedAt)
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
                          preAlertMinutes: UsageState.defaultPreAlertMinutes,
                          postAlertMinutes: UsageState.defaultPostAlertMinutes,
                          preAlertsSpoken: Array(repeating: false, count: UsageState.defaultPreAlertMinutes.count),
                          postAlertsShown: Array(repeating: false, count: UsageState.defaultPostAlertMinutes.count),
                          limitReachedAt: nil)
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

    static let defaultPreAlertMinutes = [15, 10, 5]
    static let defaultPostAlertMinutes = [1, 2, 3, 4, 5]
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
