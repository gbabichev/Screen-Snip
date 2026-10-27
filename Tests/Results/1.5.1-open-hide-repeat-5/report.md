# Repeat: open editor, selected image, hiding enabled

Fresh run on unchanged tag **1.5.1**, commit `08f2c0af639144f90033112e2835e26282ef678a`,
**Screen Snip GitHub / Release - Web** build.

| Test | Repetitions | Returned blank / selected image lost | New editor window ID |
| --- | ---: | ---: | ---: |
| Normal hotkey → Escape | 5 | 5 | 5 |
| Quick Escape during startup | 5 | 5 | 5 |
| Hold mouse → drag → Escape → release | 5 | 5 | 5 |

**Reproduced in 15/15 trials.** Every initial state had an open editor with the
test image loaded, hide-during-capture verified on through Settings, and Finder
foreground. Every final state had a visible editor with the blank Capture prompt
and no image-specific Crop control. WindowServer IDs changed in all 15 trials,
confirming the original editor window was replaced.

In the quick-Escape group, **3/5** first presses were too early and
required a separately logged second Escape to cancel the late overlay. The blank
result in those trials is measured after that actual cancellation. All five
mouse drags were verified through the selection-size label and held-button state;
all cancelled before mouse-up. No new snip files were observed.

This tests selected-versus-blank UI state with the deterministic three-color
fixture, not a pixel-exact comparison. It uses the same release baseline as the
previous matrix; it is not a Debug-build comparison. No application code was
changed. The hide preference was restored to its original value afterward.

See `trials.jsonl` for each initial/final window ID and selection probe, and
`summary.json` for totals.

Driver SHA-256: `518dc1d50a74057fc4001207711854616637acede3ec343f706d552a2fa9b4d3`
