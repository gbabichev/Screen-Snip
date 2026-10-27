# Capture window preservation fix: verification

The app now temporarily orders existing windows out during capture rather than
closing them. Cancellation restores the same window objects and prior foreground
context. A new capture opens in a separate editor when the current editor has
unsaved edits or is minimized. Editor commands, dirty-state tracking, image
delivery, and quit confirmation are scoped to the relevant editor.

## Before / after live matrix

Both runs used five repetitions of normal Escape, startup Escape, and real
mouse-drag/Escape, for initially open/closed editors and hide mode on/off.

| Condition | Baseline 1.5.1 | Fixed build |
| --- | --- | --- |
| Initially closed, hiding off | 15/15 stayed closed | 15/15 stayed closed |
| Initially closed, hiding on | 15/15 stayed closed | 15/15 stayed closed |
| Initially open, hiding off | 15/15 kept the image | 15/15 kept image and original window |
| Initially open, hiding on | **15/15 returned blank** | **15/15 kept image and original window** |

All 60 fixed-build trials observed actual capture overlays and dismissal. Every
editor's WindowServer ID and bounds matched its initial state after cancellation.
No new snip files were observed in the cancellation matrix. All 30 initially open
editors kept selected-image controls; none returned the blank Capture prompt.

Foreground observations: {'com.apple.UserNotificationCenter': 1, 'com.apple.finder': 59}. The one non-Finder observation was macOS
UserNotificationCenter during the new build's first capture. None ended with
Screen Snip unexpectedly foreground.

Raw matrix data: `fixed-window-preservation-matrix-5/`. Original baseline:
`1.5.1-state-matrix-5/`. The earlier startup-Escape gap remains separately
recorded; this patch does not add early-startup cancellation behavior.

## Additional live state / unsaved-work checks

All seven passed in `fixed-edited-capture-verified-v2/summary.json`:

- Minimized editor stays minimized on cancel and retains its image.
- Hidden app stays hidden on cancel and retains its image.
- Settings and editor retain their original windows and image state.
- An unsaved rotation survives capture cancellation in the same editor.
- Completing a real screenshot opens a separate clean editor while the original
  edited window remains selected and dirty.
- Undo in the new editor leaves the old editor's unsaved work intact.
- Quit asks about both dirty editors; cancelling the second confirmation retains
  the app and both windows. Only test-created edits were discarded for cleanup.

The additional check driver refreshes accessibility handles after hide/show and
reads edited state from the close button. Earlier probe-calibration failures are
excluded from the seven passing checks. One actual screenshot was completed to
verify successful capture; the cancellation matrix created no screenshots.

## Build and scope

Release - Web and Debug builds succeeded. Live capture checks used the fixed
Release - Web app at `/private/tmp/screen-snip-preserve-window/Build/Products/Release - Web/Screen Snip.app`.
No fixes were taken from the stashes and no commits were created.

This verifies selected-versus-blank UI, window identity/bounds, visible edited
state, and public UI behavior. It is not a pixel-exact comparison of every drawing
object or an exhaustive test of display/Space arrangements.

Current source hashes (the final difference from the live-tested release build
is comment/whitespace cleanup):

```json
{
  "Screen Snip/Logic/WindowManager.swift": "7175512a4e296036606152b1d7d25a179407e3f52f9a89cd80fa8298ef3f013a",
  "Screen Snip/Logic/GlobalHotKeyManager.swift": "049c420c69529b5d6270b06ff19aa3c0b5ff013aa8ab4ddba2d6c3d89e85817c",
  "Screen Snip/Logic/Selection.swift": "029053051b7cc97cd1bfe3aff9185a699a140a7d37fb00c8068b2a69e304f2fe",
  "Screen Snip/Views/ContentView.swift": "264def4144a65c36405c46dc0720dca32a5b56677ae22d821cb24eb32c3b2abd",
  "Screen Snip/Views/ContentView+Notifications.swift": "9f20fbf915a4654c183a70259c32aa44b6e48b29966357e1c00eea2ca55757a0",
  "Screen Snip/Screen_SnipApp.swift": "3f9e3dc29c34271900123b2fb29bec41eed3b4b8fce8bee9087ffa2ca2bb4c4b"
}
```
