# Building SimpleScreenTime

This document provides step-by-step instructions for building and deploying the SimpleScreenTime macOS app.

## Prerequisites

- Mac Studio (or any Mac) with Xcode 15 or later
- macOS 13 (Ventura) or later
- Apple Developer ID (optional, but recommended for easier deployment)

## Project Configuration

The app is already configured with:
- **LSUIElement = YES** (menu bar only, no Dock icon)
- **Universal Binary** support (Apple Silicon + Intel)
- **Deployment Target**: macOS 13.0
- **Code Signing**:
  - Debug: Automatic (Apple Development)
  - Release: Manual (Developer ID Application)

## Customization

Before building, you may want to customize:

1. **Daily Time Limit** (default: 1 hour)
   - Edit `SimpleScreenTime/SimpleScreenTime/SimpleScreenTimeApp.swift`
   - Line 13: `private let dailyLimitSeconds: TimeInterval = 60 * 60`
   - Change to desired seconds (e.g., `90 * 60` for 90 minutes)

2. **PIN Code** (default: "4739")
   - Same file, line 14: `private let hardCodedPin = "4739"`
   - Change to your desired PIN

3. **Bundle Identifier** (recommended)
   - Open `SimpleScreenTime.xcodeproj` in Xcode
   - Select the project in the navigator
   - Under "Signing & Capabilities", change the Bundle Identifier from `com.yourcompany.SimpleScreenTime` to your own identifier

## Building the App

### Option 1: Build for Testing (Debug)

1. Open `SimpleScreenTime.xcodeproj` in Xcode
2. Select the SimpleScreenTime scheme
3. Product → Build (⌘B)
4. Product → Run (⌘R) to test locally

### Option 2: Build Universal Binary for Distribution (Release)

1. Open `SimpleScreenTime.xcodeproj` in Xcode

2. **Configure Code Signing (if you have a Developer ID)**:
   - Select the project → SimpleScreenTime target
   - Go to "Signing & Capabilities"
   - For Release configuration:
     - Set "Signing Certificate" to "Developer ID Application"
     - Enter your Team ID if prompted
   - If you don't have a Developer ID, you can use automatic signing with "Apple Development"

3. **Build Settings Check**:
   - Select the project → Build Settings
   - Search for "Architectures"
   - Ensure "Architectures" = `$(ARCHS_STANDARD)` (should be "Standard Architectures")
   - Search for "Build Active Architecture Only"
   - Ensure it's set to:
     - Debug: Yes
     - **Release: No** (important for universal binary!)

4. **Create Archive**:
   - Product → Scheme → Edit Scheme
   - Select "Run" → Change Build Configuration to "Release"
   - Product → Archive
   - Wait for the archive to complete

5. **Export the App**:
   - Window → Organizer → Archives
   - Select your SimpleScreenTime archive
   - Click "Distribute App"
   - Choose **"Copy App"** (or "Developer ID" if you have one)
   - Click "Next" and follow the prompts
   - Choose export location
   - The exported `SimpleScreenTime.app` will be ready

## Deploying to the Intel MacBook

### Transfer the App

Choose one of these methods:
- **AirDrop**: Right-click the app → Share → AirDrop to MacBook
- **USB Drive**: Copy to USB, then transfer
- **Network**: Use file sharing or cloud storage

### Install on MacBook

1. Copy `SimpleScreenTime.app` to `/Applications` folder on the MacBook

2. **First Launch**:
   - Right-click `SimpleScreenTime.app` → **Open**
   - If Gatekeeper blocks it, go to:
     - System Settings → Privacy & Security
     - Scroll down and click **"Open Anyway"**
   - Click **"Open"** in the confirmation dialog

3. **Verify it's Running**:
   - Look for the time indicator in the menu bar (top right)
   - Should show something like `60m` or `—m`

### Set Up Auto-Start (on Child's Account)

1. Log into the **child's macOS user account**
2. System Settings → General → **Login Items**
3. Click the **"+"** button under "Open at Login"
4. Navigate to `/Applications` and select `SimpleScreenTime.app`
5. Ensure it's enabled in the list

## App Usage

### Menu Bar Display
- Shows remaining time in minutes (e.g., `45m`)
- When time runs out, it blinks between `0m` and ` ` (space) to get attention
- **Does NOT block apps** - it's just a reminder!

### Reset Time
- Click the menu bar icon
- Select "Reset (PIN)"
- Enter the PIN (default: 4739)
- Time resets to full daily limit

### View Activity Log
- Click the menu bar icon
- Select "Open Log Folder"
- Logs are stored at: `~/Library/Application Support/SimpleScreenTime/events.log`

### State File
- Daily usage is tracked in: `~/Library/Application Support/SimpleScreenTime/state.json`

## Troubleshooting

### App Doesn't Start
- Check Console.app for crash logs
- Verify macOS version is 13.0 or later

### Wrong Architecture
- Ensure you built with `ONLY_ACTIVE_ARCH = NO` for Release
- Check that `ARCHS` includes both arm64 and x86_64

### Gatekeeper Issues
- If the app won't open, try removing the quarantine attribute:
  ```bash
  xattr -dr com.apple.quarantine /Applications/SimpleScreenTime.app
  ```

### Signing Issues
- If you don't have a Developer ID, use automatic signing
- Users may need to explicitly allow the app in System Settings

## Updating the App

To update:
1. Make changes to the code
2. Increment the version in `Info.plist` (CFBundleShortVersionString)
3. Rebuild and redistribute
4. On the MacBook, replace the old app with the new one
5. May need to restart or re-add to Login Items

## Notes

- The app intentionally has no enforcement - it's a reminder system
- Kids can force-quit it, but events are logged
- Parent can review `events.log` to check compliance
- Auto-resets at midnight each day
- Pauses counting when Mac is locked, asleep, or logged out
