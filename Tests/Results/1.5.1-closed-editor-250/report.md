# 1.5.1: closed-editor hotkey / Escape stress test

Completed **250 verified trials**, with **0 observed editor reopens**.

- Baseline: tag `1.5.1`, commit `08f2c0af639144f90033112e2835e26282ef678a`, Release - Web build.
- The app remained running, but its editor was closed before every hotkey.
- Each trial verified Finder foreground and no editor or selection window before posting the actual Command-Shift-2 system shortcut.
- All 250 shortcuts produced a real selection overlay; all 250 Escape events dismissed it.
- Windows were sampled about every 20 ms for 1.5 seconds after Escape. No editor was observed in any trial or final trial snapshot.
- Escape delays after overlay confirmation: {0: 50, 25: 50, 75: 50, 150: 50, 300: 50} (milliseconds: trial count).
- Hotkey-to-overlay latency: median 487.5 ms; range 438.5–549.4 ms.
- Driver SHA-256: `153ae02b0595ef07c8c746662dde350e83aa228bf28f8ed2e9b2b1b7ab222b0d`.

This run did **not reproduce** the reported intermittent reopen. It does not prove the bug is absent, test Escape before the overlay appears, or test dragging, other Spaces, or longer post-Escape delays. No application fixes were applied.

The visible-editor calibration runs are excluded: reopening is expected when the editor was open before capture.

See `summary.json` and `trials.jsonl` for the measured data.
