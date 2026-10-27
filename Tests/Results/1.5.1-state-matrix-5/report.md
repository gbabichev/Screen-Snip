# 1.5.1: editor state × hide setting × cancellation test

**60 completed trials:** 5 repetitions of each of 3 tests for every combination
of initially open/closed editor and hiding on/off. Baseline application code is
unchanged (`08f2c0af639144f90033112e2835e26282ef678a`, Release - Web).

| Initial editor | Hide during capture | Normal Escape | Quick Escape | Drag + Escape |
| --- | --- | --- | --- | --- |
| Closed | Off | 5/5 stayed closed | 5/5 stayed closed | 5/5 stayed closed |
| Closed | On | 5/5 stayed closed | 5/5 stayed closed | 5/5 stayed closed |
| Open | Off | 5/5 image kept | 5/5 image kept | 5/5 image kept |
| Open | On | 5/5 returned blank | 5/5 returned blank | 5/5 returned blank |

The background-window explanation reproduced: **15/15 open-editor + hiding-on
trials restored a blank editor and lost the selected image**. All 15 returned
with a different WindowServer window ID. With hiding off, all 15 open-editor
trials kept the image-selected UI and the same editor window ID. Initially
closed editors stayed closed in all 30 trials.

This matches the implementation: [closeAllAppWindows](</Users/georgebabichev/Developer/Apps-Code/Screen Snip/Screen Snip/Logic/WindowManager.swift:53>)
closes the editor; [capture completion](</Users/georgebabichev/Developer/Apps-Code/Screen Snip/Screen Snip/Logic/GlobalHotKeyManager.swift:355>) calls
`ensureMainWindow()` on cancellation when the editor was initially visible.
After the original controller is cleared, this creates a fresh ContentView.
The restore preserves visibility but loses view-local selection state.

## Method and evidence

- The actual Settings switch was changed and its UI value verified. Original
  hide-on preference was restored after the run.
- A deterministic 317×211 three-color PNG was opened through the app's normal
  file-open path before each trial. Closed trials then closed the real editor;
  open trials left it visible behind Finder.
- Initial and final selected-image UI was measured by the image-only Crop
  toolbar button and the blank Capture prompt. This checks selected versus
  blank UI, not a pixel-for-pixel image-content comparison. A loaded fixture
  was also visually confirmed while calibrating this probe.
- Real global hotkey, Escape, and mouse events were posted. All 60 overlays were
  observed; all 20 drags were verified by the visible size label and held-button
  state. Every drag cancelled before mouse-up.
- Quick-Escape trials separately record a missed first Escape and a cleanup
  Escape; a cleanup never counts as successful first cancellation.
- No new snip image files were observed in the monitored save directories.
- The incomplete `1.5.1-state-matrix-probe-calibration` run is excluded; its old
  Copy-to-Clipboard accessibility-label probe was not stable across toolbar
  presentation. The completed run uses the Crop control instead.

No application fixes have been applied. See `trials.jsonl`, `summary.json`, and
`case-summary.json` for raw measurements and per-case counts.

Driver SHA-256: `06a1e0738ba267439b14d85c5d0af0b9140ab2badae0dd8f5d9920b29dd62a21`
