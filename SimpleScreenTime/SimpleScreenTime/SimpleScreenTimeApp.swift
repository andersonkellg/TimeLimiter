import SwiftUI
import AppKit
import AVFoundation
import CoreAudio

@main
struct SimpleScreenTimeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { Settings { EmptyView() } } // no windows
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    // ====== CONFIG ======
    private let dailyLimitSeconds: TimeInterval = 60 * 60  // 1 hour (change to desired seconds)
    private let hardCodedPin = "0000"                      // CHANGE THIS before deployment!
    private let blinkWhenOverLimit = true
    private let showBackgroundColor = true                 // colored background
    private let maxAnnoyancePopups = 5                     // number of popups before stopping
    private let playAlertSound = true                      // play sound when time is up
    private let alertVolumeLevel: Float = 0.5              // 0.0 to 1.0 (50% volume for alert)
    // ====================

    private var statusItem: NSStatusItem!
    private var timer: Timer?

    private var state = UsageState.load()
    private var alertsConfig = AlertsConfig.load()
    private var lastTick = Date()
    private var isCounting = true
    private var alertsShownToday: Set<Int> = []  // Track which alerts have been shown
    private var audioPlayer: AVAudioPlayer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupMenu()
        setupObservers()

        log("AppLaunched")
        normalizeForToday()

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
        menu.addItem(NSMenuItem(title: "Edit Alerts (PIN)", action: #selector(editAlerts), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Edit Today's Limit (PIN)", action: #selector(editTodayLimit), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reset Today's Time (PIN)", action: #selector(resetWithPin), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Log Folder", action: #selector(openLogFolder), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
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
            alertsShownToday.removeAll()  // Reset shown alerts for new day
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
            showAnnoyingPopupIfNeeded()

        } else if mins <= 5 {
            // Warning mode - orange
            button.title = "\(mins)m"
            if showBackgroundColor {
                button.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.6).cgColor
                button.layer?.borderColor = NSColor.systemOrange.cgColor
            }

        } else if mins <= 15 {
            // Caution mode - yellow
            button.title = "\(mins)m"
            if showBackgroundColor {
                button.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.5).cgColor
                button.layer?.borderColor = NSColor.systemYellow.cgColor
            }

        } else {
            // Normal mode - green
            button.title = "\(mins)m"
            if showBackgroundColor {
                button.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.4).cgColor
                button.layer?.borderColor = NSColor.systemGreen.cgColor
            }
        }
    }

    private func showAnnoyingPopupIfNeeded() {
        // Calculate minutes over the limit
        let overSeconds = abs(min(0, remainingSeconds()))
        let minutesOver = Int(overSeconds / 60)

        // Check which alerts should fire based on minutes over
        for alertConfig in alertsConfig.alerts where alertConfig.enabled {
            // Skip if already shown
            if alertsShownToday.contains(alertConfig.id) {
                continue
            }

            // Check if enough time has passed for this alert
            if minutesOver >= alertConfig.minutesAfterExpiry {
                showAlert(alertConfig)
                alertsShownToday.insert(alertConfig.id)
                log("Alert[\(alertConfig.id)]Shown")
            }
        }
    }

    private func showAlert(_ config: AlertConfig) {
        // Play alert sound with volume override
        if playAlertSound {
            playAlertSoundWithVolumeOverride(config: config)
        }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Screen Time Alert"
        alert.informativeText = config.message
        alert.addButton(withTitle: "OK, I understand")

        // Make it modal and bring to front
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func playAlertSoundWithVolumeOverride(config: AlertConfig) {
        // Save current system volume
        let originalVolume = getSystemVolume()

        // Set volume to alert level
        setSystemVolume(alertVolumeLevel)

        switch config.audioType {
        case .defaultBeep:
            // Play system alert sound multiple times
            NSSound.beep()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSSound.beep() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSSound.beep() }

        case .customFile:
            if let fileName = config.customSoundFileName {
                // Play custom sound file
                let soundURL = AlertsConfig.audioFilesURL.appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: soundURL.path) {
                    audioPlayer = try? AVAudioPlayer(contentsOf: soundURL)
                    audioPlayer?.play()
                } else {
                    // Fallback to default if custom file missing
                    NSSound.beep()
                }
            } else {
                // No file specified, use default
                NSSound.beep()
            }

        case .speakMessage:
            if let message = config.speechMessage, !message.isEmpty {
                // Use text-to-speech
                speakMessage(message, voiceName: config.voiceName)
            } else {
                // No speech message, use default beep
                NSSound.beep()
            }
        }

        // Restore original volume after sound plays (5 seconds to allow for speech)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            self.setSystemVolume(originalVolume)
        }
    }

    private func getSystemVolume() -> Float {
        var outputDeviceID = AudioDeviceID(0)
        var outputDeviceIDSize = UInt32(MemoryLayout.size(ofValue: outputDeviceID))

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &outputDeviceIDSize,
            &outputDeviceID
        )

        var volume: Float = 0.0
        var volumeSize = UInt32(MemoryLayout.size(ofValue: volume))

        address.mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        address.mScope = kAudioDevicePropertyScopeOutput

        AudioObjectGetPropertyData(
            outputDeviceID,
            &address,
            0,
            nil,
            &volumeSize,
            &volume
        )

        return volume
    }

    private func setSystemVolume(_ volume: Float) {
        var outputDeviceID = AudioDeviceID(0)
        var outputDeviceIDSize = UInt32(MemoryLayout.size(ofValue: outputDeviceID))

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &outputDeviceIDSize,
            &outputDeviceID
        )

        var newVolume = min(max(volume, 0.0), 1.0) // Clamp between 0 and 1
        let volumeSize = UInt32(MemoryLayout.size(ofValue: newVolume))

        address.mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        address.mScope = kAudioDevicePropertyScopeOutput

        AudioObjectSetPropertyData(
            outputDeviceID,
            &address,
            0,
            nil,
            volumeSize,
            &newVolume
        )
    }

    @objc private func editAlerts() {
        // PIN verification first
        if !verifyPIN() { return }

        // Create window to show all alerts
        let alert = NSAlert()
        alert.messageText = "Configure Alerts"
        alert.informativeText = "Select an alert to edit, or enable/disable alerts below:"
        alert.alertStyle = .informational

        // Create custom view with table of alerts
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))

        var yOffset: CGFloat = 160
        for (index, alertConfig) in alertsConfig.alerts.enumerated() {
            // Checkbox for enable/disable
            let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            checkbox.state = alertConfig.enabled ? .on : .off
            checkbox.frame = NSRect(x: 10, y: yOffset, width: 20, height: 20)
            checkbox.tag = alertConfig.id
            view.addSubview(checkbox)

            // Alert summary label
            let label = NSTextField(labelWithString: "Alert \(alertConfig.id): +\(alertConfig.minutesAfterExpiry)min - \(alertConfig.message.prefix(40))...")
            label.frame = NSRect(x: 35, y: yOffset, width: 350, height: 20)
            view.addSubview(label)

            // Edit button
            let editBtn = NSButton(title: "Edit", target: self, action: #selector(editSingleAlert(_:)))
            editBtn.frame = NSRect(x: 400, y: yOffset - 2, width: 80, height: 24)
            editBtn.tag = alertConfig.id
            view.addSubview(editBtn)

            yOffset -= 30
        }

        alert.accessoryView = view
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Update enabled states from checkboxes
            for subview in view.subviews {
                if let checkbox = subview as? NSButton, checkbox.title == "" {
                    if let index = alertsConfig.alerts.firstIndex(where: { $0.id == checkbox.tag }) {
                        alertsConfig.alerts[index].enabled = (checkbox.state == .on)
                    }
                }
            }
            AlertsConfig.save(alertsConfig)
            log("AlertsConfigUpdated")
        }
    }

    @objc private func editSingleAlert(_ sender: NSButton) {
        let alertId = sender.tag
        guard let index = alertsConfig.alerts.firstIndex(where: { $0.id == alertId }) else { return }
        var config = alertsConfig.alerts[index]

        let alert = NSAlert()
        alert.messageText = "Edit Alert \(alertId)"
        alert.informativeText = "Configure this alert:"
        alert.alertStyle = .informational

        // Create form with larger height for additional controls
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: 320))

        // Message text
        let msgLabel = NSTextField(labelWithString: "Alert Message:")
        msgLabel.frame = NSRect(x: 10, y: 290, width: 380, height: 20)
        view.addSubview(msgLabel)

        let msgField = NSTextView(frame: NSRect(x: 10, y: 220, width: 430, height: 65))
        msgField.string = config.message
        msgField.font = NSFont.systemFont(ofSize: 13)
        let scrollView = NSScrollView(frame: msgField.frame)
        scrollView.documentView = msgField
        scrollView.hasVerticalScroller = true
        view.addSubview(scrollView)

        // Minutes after expiry
        let minLabel = NSTextField(labelWithString: "Minutes after time expires:")
        minLabel.frame = NSRect(x: 10, y: 190, width: 200, height: 20)
        view.addSubview(minLabel)

        let minField = NSTextField(frame: NSRect(x: 220, y: 190, width: 60, height: 24))
        minField.stringValue = "\(config.minutesAfterExpiry)"
        view.addSubview(minField)

        // Audio options with radio buttons using NSPopUpButton for simplicity
        let audioLabel = NSTextField(labelWithString: "Alert Sound:")
        audioLabel.frame = NSRect(x: 10, y: 160, width: 100, height: 20)
        view.addSubview(audioLabel)

        let audioTypePopup = NSPopUpButton(frame: NSRect(x: 10, y: 130, width: 430, height: 24))
        audioTypePopup.removeAllItems()
        audioTypePopup.addItem(withTitle: "Default Beep")
        audioTypePopup.addItem(withTitle: "Custom Sound File")
        audioTypePopup.addItem(withTitle: "Speak Message (Text-to-Speech)")

        // Select current option
        switch config.audioType {
        case .defaultBeep:
            audioTypePopup.selectItem(at: 0)
        case .customFile:
            audioTypePopup.selectItem(at: 1)
        case .speakMessage:
            audioTypePopup.selectItem(at: 2)
        }

        view.addSubview(audioTypePopup)

        // Custom sound file selection
        let soundFileLabel = NSTextField(labelWithString: config.customSoundFileName ?? "No file selected")
        soundFileLabel.frame = NSRect(x: 30, y: 85, width: 300, height: 20)
        view.addSubview(soundFileLabel)

        let chooseSoundBtn = NSButton(title: "Choose Audio File...", target: nil, action: nil)
        chooseSoundBtn.frame = NSRect(x: 340, y: 83, width: 100, height: 24)
        chooseSoundBtn.bezelStyle = .rounded
        view.addSubview(chooseSoundBtn)

        // Speech message text field
        let speechLabel = NSTextField(labelWithString: "Text to Speak:")
        speechLabel.frame = NSRect(x: 30, y: 60, width: 100, height: 20)
        view.addSubview(speechLabel)

        let speechField = NSTextField(frame: NSRect(x: 130, y: 60, width: 310, height: 24))
        speechField.placeholderString = "Enter message to speak aloud..."
        speechField.stringValue = config.speechMessage ?? ""
        view.addSubview(speechField)

        // Voice selection dropdown
        let voiceLabel = NSTextField(labelWithString: "Voice:")
        voiceLabel.frame = NSRect(x: 30, y: 30, width: 100, height: 20)
        view.addSubview(voiceLabel)

        let voicePopup = NSPopUpButton(frame: NSRect(x: 130, y: 28, width: 310, height: 24))
        voicePopup.removeAllItems()

        // Get all available system voices
        let availableVoices = NSSpeechSynthesizer.availableVoices
        var voiceNames: [String] = []
        for voice in availableVoices {
            if let name = NSSpeechSynthesizer.attributes(forVoice: voice)[.name] as? String {
                voiceNames.append(name)
                voicePopup.addItem(withTitle: name)
            }
        }

        // Select current voice or default
        if let currentVoice = config.voiceName, voiceNames.contains(currentVoice) {
            voicePopup.selectItem(withTitle: currentVoice)
        } else {
            voicePopup.selectItem(at: 0)
        }

        view.addSubview(voicePopup)

        // Test speak button
        let testSpeakBtn = NSButton(title: "Test", target: nil, action: nil)
        testSpeakBtn.frame = NSRect(x: 340, y: 0, width: 100, height: 24)
        testSpeakBtn.bezelStyle = .rounded
        view.addSubview(testSpeakBtn)

        alert.accessoryView = view
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        // Handle "Choose Audio File" button click
        chooseSoundBtn.target = self
        chooseSoundBtn.action = #selector(chooseAudioFile(_:))
        chooseSoundBtn.tag = alertId  // Store alertId for the callback

        // Handle "Test" button for speech
        testSpeakBtn.target = self
        testSpeakBtn.action = #selector(testSpeech(_:))

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Save changes
            config.message = msgField.string
            if let minutes = Int(minField.stringValue), minutes >= 0 {
                config.minutesAfterExpiry = minutes
            }

            // Determine selected audio type from popup
            let selectedIndex = audioTypePopup.indexOfSelectedItem
            switch selectedIndex {
            case 0:
                config.audioType = .defaultBeep
            case 1:
                config.audioType = .customFile
            case 2:
                config.audioType = .speakMessage
                config.speechMessage = speechField.stringValue.isEmpty ? nil : speechField.stringValue
                config.voiceName = voicePopup.titleOfSelectedItem
            default:
                config.audioType = .defaultBeep
            }

            alertsConfig.alerts[index] = config
            AlertsConfig.save(alertsConfig)
            log("Alert[\(alertId)]Updated")
        }
    }

    @objc private func chooseAudioFile(_ sender: NSButton) {
        let openPanel = NSOpenPanel()
        openPanel.title = "Choose Audio File"
        openPanel.allowedContentTypes = [.audio]
        openPanel.allowsMultipleSelection = false

        if openPanel.runModal() == .OK, let url = openPanel.url {
            // Copy file to app support directory
            let destURL = AlertsConfig.audioFilesURL.appendingPathComponent(url.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: AlertsConfig.audioFilesURL, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: url, to: destURL)

                // Update the label in the current alert view
                if let alertWindow = NSApp.windows.first(where: { $0.isVisible }),
                   let contentView = alertWindow.contentView,
                   let label = contentView.subviews.first(where: { ($0 as? NSTextField)?.frame.origin.y == 85 }) as? NSTextField {
                    label.stringValue = url.lastPathComponent
                }

                // Update config
                let alertId = sender.tag
                if let index = alertsConfig.alerts.firstIndex(where: { $0.id == alertId }) {
                    alertsConfig.alerts[index].customSoundFileName = url.lastPathComponent
                }
            } catch {
                let errorAlert = NSAlert()
                errorAlert.messageText = "Error"
                errorAlert.informativeText = "Could not copy audio file: \(error.localizedDescription)"
                errorAlert.runModal()
            }
        }
    }

    @objc private func testSpeech(_ sender: NSButton) {
        // Find the speech field and voice popup in the current alert
        if let alertWindow = NSApp.windows.first(where: { $0.isVisible }),
           let contentView = alertWindow.contentView {

            var speechText = ""
            var voiceName = ""

            // Find the speech text field
            for subview in contentView.subviews {
                if let textField = subview as? NSTextField,
                   textField.placeholderString == "Enter message to speak aloud..." {
                    speechText = textField.stringValue
                }
                if let popup = subview as? NSPopUpButton,
                   let title = popup.titleOfSelectedItem {
                    voiceName = title
                }
            }

            if !speechText.isEmpty {
                speakMessage(speechText, voiceName: voiceName)
            }
        }
    }

    private func speakMessage(_ message: String, voiceName: String?) {
        let synthesizer = NSSpeechSynthesizer()

        // Find the voice identifier for the given name
        if let voiceName = voiceName {
            for voice in NSSpeechSynthesizer.availableVoices {
                if let name = NSSpeechSynthesizer.attributes(forVoice: voice)[.name] as? String,
                   name == voiceName {
                    synthesizer.setVoice(voice)
                    break
                }
            }
        }

        synthesizer.startSpeaking(message)
    }

    private func verifyPIN() -> Bool {
        let pinAlert = NSAlert()
        pinAlert.messageText = "Enter PIN"
        pinAlert.informativeText = "Authentication required"
        pinAlert.alertStyle = .informational

        let pinField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        pinField.placeholderString = "PIN"
        pinAlert.accessoryView = pinField

        pinAlert.addButton(withTitle: "OK")
        pinAlert.addButton(withTitle: "Cancel")

        let response = pinAlert.runModal()
        guard response == .alertFirstButtonReturn else { return false }

        if pinField.stringValue == hardCodedPin {
            return true
        } else {
            let fail = NSAlert()
            fail.messageText = "Wrong PIN"
            fail.runModal()
            log("PINVerificationFailed")
            return false
        }
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
            alertsShownToday.removeAll()  // Reset alert tracking
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
        NSApp.terminate(nil)
    }

    private func log(_ event: String) {
        Logger.append(event: event,
                      used: Int(state.secondsUsedToday),
                      remaining: Int(remainingSeconds()))
    }
}

// Alert Configuration
enum AlertAudioType: String, Codable {
    case defaultBeep
    case customFile
    case speakMessage
}

struct AlertConfig: Codable, Identifiable {
    var id: Int
    var enabled: Bool
    var message: String
    var minutesAfterExpiry: Int  // How many minutes after 0 to show this alert
    var audioType: AlertAudioType
    var customSoundFileName: String?  // For customFile type
    var speechMessage: String?  // For speakMessage type
    var voiceName: String?  // For speakMessage type (e.g. "Samantha")

    // Legacy support for useDefaultSound
    var useDefaultSound: Bool {
        get { audioType == .defaultBeep }
        set { audioType = newValue ? .defaultBeep : .customFile }
    }

    static func defaultAlerts() -> [AlertConfig] {
        return [
            AlertConfig(id: 1, enabled: true, message: "⏰ SCREEN TIME IS UP! ⏰\n\nYou've used all your screen time for today.\n\nPlease take a break from the computer.", minutesAfterExpiry: 0, audioType: .defaultBeep, customSoundFileName: nil, speechMessage: nil, voiceName: nil),
            AlertConfig(id: 2, enabled: true, message: "Second reminder: Please step away from the computer.", minutesAfterExpiry: 5, audioType: .defaultBeep, customSoundFileName: nil, speechMessage: nil, voiceName: nil),
            AlertConfig(id: 3, enabled: true, message: "Third reminder: Time to take a break now.", minutesAfterExpiry: 10, audioType: .defaultBeep, customSoundFileName: nil, speechMessage: nil, voiceName: nil),
            AlertConfig(id: 4, enabled: false, message: "Fourth reminder: Please close the computer.", minutesAfterExpiry: 15, audioType: .defaultBeep, customSoundFileName: nil, speechMessage: nil, voiceName: nil),
            AlertConfig(id: 5, enabled: false, message: "Final reminder: Computer time is over for today.", minutesAfterExpiry: 20, audioType: .defaultBeep, customSoundFileName: nil, speechMessage: nil, voiceName: nil)
        ]
    }
}

struct AlertsConfig: Codable {
    var alerts: [AlertConfig]

    static func load() -> AlertsConfig {
        if let data = try? Data(contentsOf: configURL),
           let config = try? JSONDecoder().decode(AlertsConfig.self, from: data) {
            return config
        }
        return AlertsConfig(alerts: AlertConfig.defaultAlerts())
    }

    static func save(_ config: AlertsConfig) {
        do {
            try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(config)
            try data.write(to: configURL, options: [.atomic])
        } catch {
            // best-effort
        }
    }

    private static var appSupportURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("SimpleScreenTime", isDirectory: true)
    }

    private static var configURL: URL {
        appSupportURL.appendingPathComponent("alerts_config.json")
    }

    static var audioFilesURL: URL {
        appSupportURL.appendingPathComponent("AlertSounds", isDirectory: true)
    }
}

struct UsageState: Codable {
    var dayStart: Date
    var secondsUsedToday: TimeInterval
    var didHitLimitToday: Bool
    var todayLimitOverride: TimeInterval?  // Optional override for today's limit

    static func load() -> UsageState {
        if let data = try? Data(contentsOf: stateURL),
           let s = try? JSONDecoder().decode(UsageState.self, from: data) {
            return s
        }
        return UsageState(dayStart: Calendar.current.startOfDay(for: Date()),
                          secondsUsedToday: 0,
                          didHitLimitToday: false,
                          todayLimitOverride: nil)
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
