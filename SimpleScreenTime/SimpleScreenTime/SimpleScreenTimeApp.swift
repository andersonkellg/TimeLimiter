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
    private let maxAnnoyancePopups = 5                    // number of popups before stopping
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
        if remainingSeconds <= 5 * 60, !state.spokePreAlert5 {
            state.spokePreAlert5 = true
            speak("Five minutes remaining.")
            log("SpokenPreAlert5")
            UsageState.save(state)
            return
        }
        if remainingSeconds <= 15 * 60, !state.spokePreAlert15 {
            state.spokePreAlert15 = true
            speak("Fifteen minutes remaining.")
            log("SpokenPreAlert15")
            UsageState.save(state)
        }
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

        // Only show up to maxAnnoyancePopups times per day
        if popupsShownToday >= maxAnnoyancePopups {
            return
        }

        // Show popup every 60 seconds
        if let lastPopup = lastPopupTime {
            if now.timeIntervalSince(lastPopup) < 60 {
                return
            }
        }

        lastPopupTime = now
        popupsShownToday += 1
        state.lastPopupTime = lastPopupTime
        state.popupsShownToday = popupsShownToday

        let remaining = maxAnnoyancePopups - popupsShownToday

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "⏰ SCREEN TIME IS UP! ⏰"
        alert.informativeText = """
        You've used all your screen time for today.

        Please take a break from the computer.

        Popups remaining today: \(remaining)
        """
        alert.addButton(withTitle: "OK, I understand")

        // Make it modal and bring to front
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()

        log("AnnoyancePopup[\(popupsShownToday)/\(maxAnnoyancePopups)]")
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
    }

    init(dayStart: Date,
         secondsUsedToday: TimeInterval,
         didHitLimitToday: Bool,
         todayLimitOverride: TimeInterval?,
         popupsShownToday: Int,
         lastPopupTime: Date?,
         spokePreAlert15: Bool,
         spokePreAlert5: Bool,
         spokePostAlert: Bool) {
        self.dayStart = dayStart
        self.secondsUsedToday = secondsUsedToday
        self.didHitLimitToday = didHitLimitToday
        self.todayLimitOverride = todayLimitOverride
        self.popupsShownToday = popupsShownToday
        self.lastPopupTime = lastPopupTime
        self.spokePreAlert15 = spokePreAlert15
        self.spokePreAlert5 = spokePreAlert5
        self.spokePostAlert = spokePostAlert
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
                          spokePostAlert: false)
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
