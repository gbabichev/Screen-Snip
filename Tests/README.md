# Real hotkey → Escape stress test

This external macOS driver tests the unmodified app. It posts the system
Command–Shift–2 shortcut, waits for actual selection-overlay windows, posts
Escape, and reads WindowServer's on-screen window list. It does not call or stub
Screen Snip's capture/cancellation methods.

The required starting state is **the app is running, but the editor window is
closed**. If the editor is open, the driver presses its real accessibility close
button. It verifies there is no editor or selection overlay before every hotkey.
Finder is foreground when the hotkey is sent. Merely hiding/minimizing the
editor is not the setup action.

Configure the app to **Drag to Select**, **Command–Shift–2**, and **Hide Screen
Snip During Capture = on**. Screen Recording permission must already be granted.
The external driver/terminal host needs system-event and UI-access authorization
(**Device Control and Data Access** on macOS 27; **Accessibility** on older macOS).
Granting Screen Snip access does not grant the external driver access. It controls
keyboard focus while running; leave the keyboard and mouse idle during a run.

```sh
# Ask macOS which driver/launcher entry needs authorization; no test inputs sent.
zsh Tests/run-hotkey-escape-stress.sh --request-permissions

# After granting the entry named in the OS prompt, recheck. When running from
# Terminal, the responsible entry is normally Terminal, not Screen Snip.
# Restart the terminal app if the permission change has not taken effect.
zsh Tests/run-hotkey-escape-stress.sh --preflight

# Run against the exact built app. Use a fresh result directory for each run.
zsh Tests/run-hotkey-escape-stress.sh \
  '/path/to/Screen Snip.app' 250 \
  'Tests/Results/my-closed-editor-run' \
  "$(git rev-parse HEAD)"
```

Each counted trial must confirm a real capture overlay. Missing overlays,
invalid initial/focus state, or Escape not dismissing the overlay stop the run
with exit status 2; they are not counted as successful trials. The driver samples
on-screen windows about every 20 ms for 1.5 seconds after Escape. Escape delay
after overlay confirmation cycles through 0, 25, 75, 150, and 300 ms.

`trials.jsonl` records each verified trial, including the actual initial windows,
capture latency, and any editor reopen. A completed run writes `summary.json`.
A completed run can contain reopens: inspect `editorReopened` in the summary.
No screenshots are saved and no private app APIs are used.

The `calibration-visible-editor-*` results start with a visible editor. Reopening
is **expected** in those controls; they are excluded from the closed-editor bug
results. The first closed-editor pilot stopped without any counted trials when
its hotkey did not produce an overlay. The second pilot added launch settling
and completed three verified trials.

The baseline for this investigation is tag **1.5.1**, commit
`08f2c0af639144f90033112e2835e26282ef678a`, built using the **Screen Snip GitHub**
scheme and **Release - Web** configuration. The previous commit `38864ce` is
preserved in a Git stash; none of its capture fixes are applied to the baseline.

## Escape during startup and while dragging

The separate timed driver keeps the original 250-cycle driver unchanged:

```sh
zsh Tests/run-timed-escape-stress.sh \
  '/path/to/Screen Snip.app' startup 100 \
  'Tests/Results/my-startup-run' "$(git rev-parse HEAD)"

zsh Tests/run-timed-escape-stress.sh \
  '/path/to/Screen Snip.app' drag 100 \
  'Tests/Results/my-drag-run' "$(git rev-parse HEAD)"
```

Both scenarios start with the editor closed and Finder foreground.

- **startup:** requests Escape 40, 75, 125, 200, 300, 400, 475, or 550 ms after
  the hotkey begins. Records actual timing and whether the overlay was visible
  when Escape was sent. If a late overlay remains, sends a separately recorded
  cleanup Escape. That cleanup does not turn an ignored first Escape into a
  successful first cancellation. An attempt with no observed overlay is marked
  unverified, rather than being claimed as a confirmed capture/cancel pass.
- **drag:** confirms the real overlay, posts mouse-down and eight drag events,
  and requires both a visible selection-size label (read through Accessibility)
  and the system's left-button-held state before Escape. Sends Escape while
  holding the button, observes for 400 ms before posting mouse-up, and then
  observes for another 1.5 seconds. Requested extra delay before Escape varies
  between 0, 25, 75, 150, and 300 ms.

If drag Escape fails, cleanup moves the still-held drag back to its starting
point before releasing, to cancel a zero-size region rather than save a snip.
This is recorded as failed first cancellation plus cleanup. The driver also
checks the configured/default snip directories for new image files and stops if
one appears unexpectedly. It never deletes user images. Any held mouse button
is released on normal/error exit. Neither driver modifies application code.

## Driver identity and permission diagnostics

Both runners cache their executable in `Tests/.build/` and rebuild only when the
Swift sources change. `--preflight` prints the exact executable path, terminal
host when identifiable, and the two permission checks. `--request-permissions`
uses macOS's own authorization prompts; it does not send hotkeys/mouse events or
change a privacy toggle. Both flags are available on either runner.

macOS retains API names such as `AXIsProcessTrusted` even though the macOS 27
settings pane is named Device Control and Data Access. A successful preflight
under Codex does not establish that the same program launched from a terminal
has permission. Follow the app identity named by the OS prompt.

The saved investigation reports contain source hashes of the driver versions
used for those runs. Later permission-diagnostic changes do not change those
historical results; the current scripts include the shared permissions source.

## Five-per-case editor/hide matrix

```sh
zsh Tests/run-matrix-escape-stress.sh \
  '/path/to/Screen Snip.app' \
  "$PWD/Tests/Fixtures/selection-sentinel.png" \
  5 'Tests/Results/my-state-matrix' "$(git rev-parse HEAD)"
```

This runs 60 trials: normal, startup, and drag/Escape; initially open or closed;
hide-during-capture on or off; five repetitions per combination. It changes and
verifies the actual Settings switch through the UI, then restores its original
value after a successful run. A small test image is opened before every trial;
closed-editor trials then press the actual close button. No app source is edited.

Open-editor trials check whether image-specific Crop controls remain present or
the blank Capture prompt appears. WindowServer IDs distinguish keeping an editor
from creating a fresh one. This checks selected-versus-blank UI state, not exact
pixel contents. Results distinguish expected window restoration from selection
loss. `1.5.1-state-matrix-probe-calibration` is an excluded incomplete probe run;
the verified 60-trial run is `1.5.1-state-matrix-5`.

To repeat only the initially open, selected-image, hide-on condition (five of
normal/startup/drag; 15 trials total), append `--open-hide-only`:

```sh
zsh Tests/run-matrix-escape-stress.sh \
  '/path/to/Screen Snip.app' "$PWD/Tests/Fixtures/selection-sentinel.png" \
  5 'Tests/Results/my-open-hide-repeat' "$(git rev-parse HEAD)" --open-hide-only
```

## Unsaved work, hidden/minimized windows, and successful captures

`run-edited-capture-checks.sh APP_PATH FIXTURE_PNG OUTPUT_DIRECTORY` runs seven
live checks for hidden/minimized windows, Settings retention, unsaved cancellation,
a completed capture into a separate editor, scoped undo, and quit confirmation
across two dirty editors. It creates a real screenshot for the success check and
discards only its own test-created unsaved rotations during cleanup. Run in an
otherwise clean test app session, with no unrelated unsaved work open.

Fixed-build verification is documented in
`Tests/Results/window-preservation-fix-report.md`. Both the original failing
baseline matrix and the fixed passing matrix are retained separately.
