# SimpleScreenTime

<div align="center">

**A lightweight macOS menu bar app for managing daily screen time**

[![macOS](https://img.shields.io/badge/macOS-13.0+-blue.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.0-orange.svg)](https://swift.org/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

<img src="https://img.shields.io/badge/Status-Active-success" alt="Active">

</div>

---

## Overview

SimpleScreenTime is a non-intrusive macOS menu bar application designed to help users (especially children) self-regulate their daily computer usage. Unlike restrictive parental controls, this app provides **gentle reminders** through a visible countdown timer without blocking functionality.

### Key Features

- 🕐 **Visual Countdown Timer** - Menu bar shows remaining time in minutes
- 🎨 **Color-Coded Status** - Green → Yellow → Orange → Red as time decreases
- ⏸️ **Smart Tracking** - Only counts active, unlocked screen time
- 🔐 **PIN Protection** - Secure admin controls for resets and limit changes
- 📊 **Audit Logging** - Track usage patterns and reset events
- 🔔 **Progressive Alerts** - Configurable popup reminders when time expires
- 💻 **Universal Binary** - Supports both Apple Silicon and Intel Macs

---

## Why SimpleScreenTime?

Apple's Screen Time can enforce hard limits, but it lacks visual feedback and can be frustrating during legitimate use. SimpleScreenTime takes a different approach:

✅ **Self-Regulation** - Helps kids build awareness and self-control
✅ **Emergency-Friendly** - Never blocks access for important tasks
✅ **Transparent** - Always visible in menu bar, no surprises
✅ **Parent-Friendly** - Audit logs show actual usage and compliance
✅ **Zero Permissions** - No accessibility or screen recording required

---

## Screenshots

### Normal Operation
```
Menu Bar: [60m] 🟢     →  [15m] 🟡  →  [5m] 🟠  →  [⏰ TIME'S UP! ⏰] 🔴
```

### Menu Options
- Edit Today's Limit (PIN)
- Reset Today's Time (PIN)
- Open Log Folder
- Quit

---

## Quick Start

### Prerequisites
- macOS 13.0 (Ventura) or later
- Xcode 15+ (for building from source)

### Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/yourusername/TimeLimiter.git
   cd TimeLimiter
   ```

2. **Configure your settings** (Optional)

   Open `SimpleScreenTime/SimpleScreenTime/SimpleScreenTimeApp.swift` and customize:
   ```swift
   private let dailyLimitSeconds: TimeInterval = 60 * 60  // 1 hour
   private let hardCodedPin = "0000"                      // CHANGE THIS!
   private let maxAnnoyancePopups = 5                     // popup limit
   ```

3. **Build the app**
   ```bash
   cd SimpleScreenTime
   open SimpleScreenTime.xcodeproj
   ```
   - In Xcode: Product → Build (⌘B)
   - For distribution: Product → Archive

4. **Install and run**
   - Copy `SimpleScreenTime.app` to `/Applications`
   - Right-click → Open (first time only)
   - Add to Login Items for auto-start

See [BUILD_INSTRUCTIONS.md](BUILD_INSTRUCTIONS.md) for detailed build and deployment instructions.

---

## Configuration

All settings are configured at compile time in `SimpleScreenTimeApp.swift`:

| Setting | Default | Description |
|---------|---------|-------------|
| `dailyLimitSeconds` | 3600 (1 hour) | Daily screen time allowance in seconds |
| `hardCodedPin` | "0000" | PIN for admin functions (CHANGE THIS!) |
| `blinkWhenOverLimit` | true | Blink menu bar when time expires |
| `showBackgroundColor` | true | Color-coded background indicators |
| `maxAnnoyancePopups` | 5 | Maximum daily popup reminders |

---

## How It Works

### Time Tracking
- ✅ Counts time when Mac is **unlocked** and **awake**
- ⏸️ Pauses when **locked**, **asleep**, or **logged out**
- 🔄 Resets automatically at **midnight** each day

### Visual Feedback
- **> 15 minutes** - Green background
- **≤ 15 minutes** - Yellow background
- **≤ 5 minutes** - Orange background
- **0 minutes** - Red background, flashing text, popup alerts

### Admin Controls

#### Edit Today's Limit
Adjust the time limit for the current day without resetting usage:
- Enter PIN → Set new limit in minutes
- Useful for earned extra time or special occasions

#### Reset Today's Time
Reset the usage counter back to zero:
- Enter PIN → Confirm reset
- Starts fresh countdown with current limit

### Audit Logging
All events are logged to:
```
~/Library/Application Support/SimpleScreenTime/events.log
```

Example log entries:
```
2025-01-15T14:23:45Z    AppLaunched              used=0s       remaining=3600s
2025-01-15T15:30:12Z    ScreenLocked             used=4027s    remaining=0s
2025-01-15T16:45:00Z    LimitReached             used=3600s    remaining=0s
2025-01-15T17:00:00Z    AnnoyancePopup[1/5]      used=3900s    remaining=0s
2025-01-15T18:00:00Z    ManualResetOK            used=0s       remaining=3600s
```

---

## Architecture

### Technology Stack
- **Language**: Swift 5.0
- **Framework**: AppKit (NSStatusBar)
- **UI**: SwiftUI + AppKit hybrid
- **Persistence**: JSON file storage
- **Deployment**: macOS 13.0+

### Design Principles

1. **Menu Bar Only** - Uses `LSUIElement` to hide from Dock
2. **Minimal Permissions** - No accessibility or screen recording required
3. **Local Storage** - All data stored in user's Application Support folder
4. **Universal Binary** - Built for both ARM64 and x86_64 architectures
5. **Automatic Signing** - Works on any Mac without manual code signing setup

### File Structure
```
SimpleScreenTime/
├── SimpleScreenTime.xcodeproj/    # Xcode project
├── SimpleScreenTime/
│   ├── SimpleScreenTimeApp.swift  # Main application code
│   ├── Info.plist                 # App configuration
│   └── Assets.xcassets/           # App icons
└── .gitignore
```

---

## Advanced Usage

### Auto-Start on Login

**On the child's macOS account:**
1. System Settings → General → Login Items
2. Click "+" and select SimpleScreenTime.app
3. Ensure it's enabled

### Distribution to Other Macs

For Intel MacBook deployment from Apple Silicon Mac:
1. Build with `ARCHS = $(ARCHS_STANDARD)` (universal binary)
2. Archive and export the app
3. Transfer via AirDrop, USB, or network
4. First run: Right-click → Open to bypass Gatekeeper

See [BUILD_INSTRUCTIONS.md](BUILD_INSTRUCTIONS.md) for complete details.

---

## Troubleshooting

### App won't start
- Check macOS version (must be 13.0+)
- View Console.app for crash logs
- Ensure app is in `/Applications` or `~/Applications`

### Gatekeeper blocking
```bash
# Remove quarantine attribute
xattr -dr com.apple.quarantine /Applications/SimpleScreenTime.app
```

Or: System Settings → Privacy & Security → Open Anyway

### Time not counting
- Check if Mac is unlocked (locks pause the timer)
- Verify app is running (check menu bar)
- Review logs: Open Log Folder from menu

### Need to change PIN
Edit `SimpleScreenTimeApp.swift` line 14 and rebuild:
```swift
private let hardCodedPin = "YOUR_NEW_PIN"
```

---

## Contributing

Contributions are welcome! This is a simple, focused tool - please keep enhancements aligned with the core philosophy of non-intrusive monitoring.

### Development Setup
```bash
git clone https://github.com/yourusername/TimeLimiter.git
cd TimeLimiter/SimpleScreenTime
open SimpleScreenTime.xcodeproj
```

### Code Style
- Swift standard style
- Minimal dependencies
- Clear comments for configuration options
- Maintain backward compatibility

---

## Security Notes

⚠️ **Before making this repository public or sharing:**

1. **Change the default PIN** from "0000" to something private
2. Do not commit your personal PIN to version control
3. Consider using environment variables or a separate config file for sensitive settings

This app is designed for trust-based monitoring, not security enforcement. A determined user can:
- Force quit the app
- Modify system time
- Delete state files

The audit log helps detect these behaviors.

---

## License

MIT License - See [LICENSE](LICENSE) file for details.

---

## Acknowledgments

Built with ❤️ for parents who want to teach self-regulation rather than enforce restriction.

Inspired by the need for transparent, respectful screen time management tools.

---

## Support

- 📖 [Build Instructions](BUILD_INSTRUCTIONS.md)
- 🐛 [Issue Tracker](https://github.com/yourusername/TimeLimiter/issues)
- 💬 [Discussions](https://github.com/yourusername/TimeLimiter/discussions)

---

<div align="center">

**Made for macOS • Built with Swift • Designed for Trust**

</div>
