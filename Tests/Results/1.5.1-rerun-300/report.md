# Repeat run: 300 closed-editor trials on 1.5.1

All three requested sets completed against unchanged baseline commit
`08f2c0af639144f90033112e2835e26282ef678a`, Release - Web build. The editor was
verified closed before every hotkey; the app remained running with Finder
foreground. These are fresh runs, separate from the previous results.

| Scenario | Trials | Confirmed capture overlays | Unintended editor reopens | Cancellation result |
| --- | ---: | ---: | ---: | --- |
| Normal hotkey, then Escape | 100 | 100 | 0 | 100 overlays dismissed |
| Quick Escape during startup | 100 | 100 | 0 | 76 first Escapes missed cancellation; separate cleanup Escape required |
| Mouse-down, drag, Escape, mouse-up | 100 | 100 | 0 | 100 active drags verified; 100 cancelled before mouse-up |

The startup and drag tests observed no new image files in the monitored snip
folders. Every drag was verified with both a selection-size label and the system
mouse-button state. No drag cleanup was needed.

The results match the previous controlled tests: the closed-editor reopen bug
was not reproduced, while very early Escape can miss capture startup.

**The new background-window hypothesis is not exercised by these runs.** An
editor that was already open, with an image selected, would need a separate
selection-preservation test. An expected window restoration and a lost selection
are different outcomes from an unexpected reopen of an initially closed editor.

No application code was changed and no application fix was applied. The previous
commit remains stashed.

Raw data and summaries are in `normal/`, `startup/`, and `drag/`. Observations
are time bounded (normal: 1.5 seconds after Escape; dragging: 400 ms before
mouse-up and 1.5 seconds after it). No other Spaces/display conditions were tested.

Driver source hashes for this repeat run:

```json
{
  "HotkeyEscapeStress.swift": "8bc0373476c5dc204749d2204d0cb9e2223f0e66ae8a7c98ea9041addb50a434",
  "TimedEscapeStress.swift": "64601972803fd395dd0d2cc71675cfe181a4e6e4aca1b38c4f07639a79c1798a",
  "StressDriverPermissions.swift": "167c8e289fb2995f496da1a3417712dc2f0d3b2dd4b5cda3a39557d507b58dd1"
}
```
