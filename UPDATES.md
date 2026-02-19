# UPDATES.md

This guide explains how to add Zippy-style "Check for Updates" to another macOS Swift app.

## What This Uses

- GitHub tags API to detect the newest version.
- One Info.plist value to configure the app:
  - `UpdateCheckReleasesURL`
- A reusable helper:
  - `AppUpdateCenter`

## Files To Copy

From this project, copy:

- `Zippy/Logic/AppUpdateCenter.swift`

You can rename it or keep the same filename/class name.

## Info.plist Setup

Add this key to your app's `Info.plist`:

```xml
<key>UpdateCheckReleasesURL</key>
<string>https://github.com/OWNER/REPO/releases</string>
```

Example:

```xml
<key>UpdateCheckReleasesURL</key>
<string>https://github.com/georgebabichev/Zippy/releases</string>
```

`AppUpdateCenter` will parse `OWNER/REPO` from this URL and check tags from:

`https://api.github.com/repos/OWNER/REPO/tags`

## Launch-Time Check

Call update check when the app finishes launching.

In your app delegate (or app lifecycle hook):

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    AppUpdateCenter.shared.checkForUpdates(trigger: .automaticLaunch)
}
```

Current Zippy reference:

- `Zippy/Logic/AppTerminationDelegate.swift`

Behavior:

- Automatic checks are quiet unless a newer version is found.

## App Menu Integration

Add a menu item under the App menu ("About" section is standard macOS placement):

```swift
Button("Check for Updates…", systemImage: "arrow.triangle.2.circlepath.circle") {
    AppUpdateCenter.shared.checkForUpdates(trigger: .manual)
}
```

Current Zippy reference:

- `Zippy/UI/AppCommands.swift`

Behavior:

- Manual checks always show a result alert (up-to-date, error, or update available).

## About View Integration (Optional but Recommended)

Use shared state in About UI:

```swift
@ObservedObject private var updateCenter = AppUpdateCenter.shared
```

Add button:

```swift
Button("Check for Updates…", systemImage: "arrow.triangle.2.circlepath.circle") {
    updateCenter.checkForUpdates(trigger: .manual)
}
.disabled(updateCenter.isChecking)
```

Optional status text:

```swift
if let lastStatusMessage = updateCenter.lastStatusMessage {
    Text(lastStatusMessage)
}
```

Current Zippy reference:

- `Zippy/UI/AboutView.swift`

## Versioning Expectations

- Your app version should be in `CFBundleShortVersionString`.
- GitHub tags should follow numeric style (examples: `1.0.0`, `v1.2.3`).
- The comparator is tolerant of a leading `v`.

## Common Pitfalls

- Missing `UpdateCheckReleasesURL` key: update check will be treated as not configured.
- Non-GitHub URL: owner/repo parsing will fail by design.
- No tags in repo: manual checks show a friendly error.

## Reuse Checklist

1. Copy `AppUpdateCenter.swift`.
2. Add `UpdateCheckReleasesURL` to `Info.plist`.
3. Wire launch check (`automaticLaunch`).
4. Add App menu action (`manual`).
5. Add About button + status text (optional).

