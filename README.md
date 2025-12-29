# TimeLimiter

# SimpleScreenTime (macOS 13+) — Lightweight Menu Bar Countdown + Audit Log

This document captures the plan, design decisions, and a working code baseline for a **very simple**, **low-overhead** “Screen Time reminder” app for a child macOS account.

Goal: Show a **menu bar countdown in minutes** (e.g., `45m`) that:
- Counts down **cumulative time per day**
- Tracks **“time actively logged in + unlocked”**
- **Stops** when the Mac is **locked**, **asleep**, **logged out**, or **shut down**
- When time is exhausted, it **blinks annoyingly** (but does **not** block apps)
- Provides a **Reset Today** action protected by a **hard-coded PIN**
- Writes an **audit log** so parent can review behavior and correct if needed
- Works on **macOS 13 (Ventura) onward**
- Built on a Mac Studio with Xcode and copied to an Intel MacBook

---

## Why this approach

Apple Screen Time can enforce limits, but it doesn’t provide a persistent “time left” badge in the menu bar. This app is intentionally **non-enforcing** and **non-invasive**:
- Helps kids self-regulate (“reminder”)
- Preserves full functionality for emergencies
- Gives parents an audit trail without full management overhead

---

## Key architectural decisions

### 1) UI: Menu bar only
- Uses `NSStatusBar` / `NSStatusItem` to render a text label in the macOS menu bar (top right).
- No windows. Optional: hide Dock icon via `LSUIElement`.

### 2) Measurement: “Active session time”
We count time when:
- User session is active (unlocked / interactive)
- Mac is awake

We pause time when:
- Screen is locked
- Session resigns active (fast user switching, lock, etc.)
- System sleeps

> We are **not** doing mouse/keyboard idleness detection to keep it simple and permission-free.

### 3) Persistence: Minimal JSON state per user
- Store daily usage state in:
  - `~/Library/Application Support/SimpleScreenTime/state.json`
- Store append-only audit log in:
  - `~/Library/Application Support/SimpleScreenTime/events.log`

### 4) Tamper stance
Not trying to defeat a determined user.
- Child can quit or force-quit; we log restart gaps implicitly and record explicit quit events when possible.
- PIN gate is “good enough” (hard-coded).

### 5) macOS 13+ compatibility strategy
- Use documented notifications:
  - `NSWorkspace.willSleepNotification` / `didWakeNotification`
  - `NSWorkspace.sessionDidResignActiveNotification` / `sessionDidBecomeActiveNotification`
- Optionally also observe distributed lock/unlock notifications (useful but not formally documented):
  - `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`
- The **session active/inactive** pair is the reliable backbone for 13+.

---

## Build + Distribution (Mac Studio → Intel MacBook)

Because the MacBook is Intel (2017), build a **Universal** app.

### 1) Configure Universal build
In Xcode (Target → Build Settings):
- **Architectures**: `Standard Architectures (Apple Silicon + Intel)`  
  (Typically `$(ARCHS_STANDARD)`)
- **Build Active Architecture Only**:
  - Debug: Yes is fine
  - **Release: No** (important for universal export)

### 2) Signing (Paid Developer Account)
Use **Developer ID Application** signing for easiest Gatekeeper experience on the MacBook.

In Xcode (Target → Signing & Capabilities):
- “Automatically manage signing” can be ON
- Choose **Developer ID** for release/distribution if offered
- If needed, set the signing cert to **Developer ID Application**

> For personal distribution, notarization is optional, but **Developer ID signing** reduces friction a lot.

### 3) Export the .app
Preferred: Archive & export:
- `Product → Archive`
- Xcode Organizer → Archives → select build → **Distribute App**
- Choose **Copy App** (or “Developer ID” style export depending on Xcode UI)

### 4) Transfer to MacBook
Copy the exported `.app` to the MacBook (AirDrop, file share, USB).

### 5) Install on the MacBook
- Move app to `/Applications` (or `~/Applications`)
- First run might prompt Gatekeeper:
  - Right-click → **Open**
  - Or System Settings → Privacy & Security → **Open Anyway**

### 6) Auto-start on login (child account)
On the **child macOS user**:
- System Settings → General → **Login Items**
- Add the app to “Open at Login”

---

## App Behavior Spec

### Display
- Menu bar text: **minutes remaining**: `90m`, `45m`, etc.
- Uses ceiling rounding so it doesn’t show `0m` too early (e.g., 1–59 seconds left → `1m`).

### Counting rules
- Counts while `isCounting == true`
- Pauses on:
  - sleep
  - session inactive / locked
- Resumes on:
  - wake
  - session active / unlocked

### Annoy mode
- When remaining time hits 0:
  - Menu bar label blinks by alternating between `" "` and `"0m"` every second

### Reset
- Menu action: `Reset (PIN)`
- PIN prompt via `NSSecureTextField`
- On correct PIN:
  - reset today’s used seconds to 0
  - clear limit-reached flag
  - log event

### Audit log
Events like:
- `AppLaunched`
- `SessionResignActive`, `SessionBecomeActive`
- `WillSleep`, `DidWake`
- `LimitReached`
- `ManualResetOK`, `ManualResetBADPIN`

---

## Xcode Project Setup Notes

### Hide Dock icon (menu-bar-only)
Set in the target’s Info (Info.plist):
- **Application is agent (UIElement)** = `YES`
- (Key: `LSUIElement`)

### No extra permissions required
This design doesn’t require Accessibility or Screen Recording permissions.

---

## Code (Single-file baseline)

Create a new **macOS App (SwiftUI)** project and replace the generated files with this single file
(or keep the `@main` file and paste the contents accordingly).

> Change `dailyLimitSeconds` and `hardCodedPin` as desired.

```swift
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
    private let hardCodedPin = "4739"                     // change this
    private let blinkWhenOverLimit = true
    // ====================

    private var statusItem: NSStatusItem!
    private var timer: Timer?

    private var state = UsageState.load()
    private var lastTick = Date()
    private var isCounting = true

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
    }

    private func setupMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Reset (PIN)", action: #selector(resetWithPin), keyEquivalent: ""))
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
            log("NewDayReset")
            UsageState.save(state)
        }
    }

    private func remainingSeconds() -> TimeInterval {
        max(0, dailyLimitSeconds - state.secondsUsedToday)
    }

    private func updateUI() {
        let rem = remainingSeconds()
        let mins = Int(ceil(rem / 60.0)) // show whole minutes remaining

        let over = (rem <= 0)
        let blinkOn = (Int(Date().timeIntervalSince1970) % 2 == 0)

        if blinkWhenOverLimit && over && !blinkOn {
            statusItem.button?.title = " "
        } else {
            statusItem.button?.title = "\(mins)m"
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

struct UsageState: Codable {
    var dayStart: Date
    var secondsUsedToday: TimeInterval
    var didHitLimitToday: Bool

    static func load() -> UsageState {
        if let data = try? Data(contentsOf: stateURL),
           let s = try? JSONDecoder().decode(UsageState.self, from: data) {
            return s
        }
        return UsageState(dayStart: Calendar.current.startOfDay(for: Date()),
                          secondsUsedToday: 0,
                          didHitLimitToday: false)
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
