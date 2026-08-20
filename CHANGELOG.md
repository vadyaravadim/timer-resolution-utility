# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Each released section below IS the GitHub Release body for that tag: `release.yml` copies the section
verbatim into the release and fails the release if the tag has no section here.

Sections are in release order, newest first. Note that 1.0.1 was tagged *after* 1.2.0: the version number
went backwards once, so release order and version order disagree in this repository's history.

## [Unreleased]

## [1.3.0] - 2026-08-20

### Added

- `-Reset` clears every value this script can set back to the Windows default without consulting the undo
  files. It lists what it is about to clear and asks for confirmation, and it snapshots first - so `-Undo`
  still brings the tweaked state back. This is the way home when the undo chain is broken: a snapshot
  deleted, or the very first one taken over an already-tweaked system.

### Fixed

- Re-selecting a tweak that was already in place quietly burned a step of your undo chain. The run still
  wrote a snapshot, but its "previous" values were the tweaked ones, so the next `-Undo` restored those
  tweaks and marked the file spent without reverting anything. Once the early snapshots were used up or
  deleted, nothing led back to the Windows defaults any more. A run now skips tweaks already in place and
  writes neither a snapshot nor a BCD backup; the holder task stays exempt, because reinstalling it is what
  rewrites a stale script path.
- Reverting could leave the resolution held with no task left to stop it by. Neither unregistering nor
  re-registering the holder task terminates a running instance, so the old process kept holding the timer
  until reboot. The task is now stopped first.

## [1.2.3] - 2026-08-08

### Fixed

- Stopping the holder task no longer left an orphan holding your timer resolution. Since 1.2.2 the
  scheduler launches a console-host wrapper, and stopping the task killed only that wrapper - the `-Hold`
  child survived with no window and no task to stop it by, every reinstall left another one behind, and
  `-Undo` no longer released the resolution until reboot. The holder now watches its parent and exits with
  it, checking every 30 seconds instead of sleeping the full hour.
- `-Measure` now says when it had nothing to compare. If something already holds the finest resolution,
  both runs measure the same state, and the ordinary noise between the two lines read as a regression
  caused by the tweak.

## [1.2.2] - 2026-08-07

### Fixed

- The holder task showed an empty, uninteractive console tab for your whole session. `-WindowStyle Hidden`
  hides only PowerShell's own console window, and on the out-of-the-box Windows 11 setup - where Windows
  Terminal owns the window as the delegated default terminal - the window it should have hidden was not
  PowerShell's. The holder now runs under `conhost --headless`, which creates a console with no window at
  all. Builds below 17763 keep the old command: they predate terminal delegation, and `Hidden` works there.
- Reinstalling the holder task left the old process running. The task's policy ignores a new instance while
  one is running, so the restart was a no-op and the previous process outlived the new definition until the
  next logon. The running instance is now stopped before the task is reinstalled.

## [1.2.1] - 2026-07-20

### Fixed

- The copy a piped `irm ... | iex` run saves into your user profile was written with a UTF-8 BOM, which
  then broke running that saved copy through `irm | iex` again - the parser chokes on the leading byte
  order mark. It is now written without one.

## [1.0.1] - 2026-07-19

### Added

- Published to the PowerShell Gallery: `Install-Script timer-resolution-utility`.
- Every tagged release ships a `SHA256SUMS.txt` alongside the script plus a signed build-provenance
  attestation, so you can verify the file you downloaded is the one the workflow built from this source.

### Fixed

- The `irm | iex` one-liner installed a holder task that re-ran the one-liner on every logon with `-Hold`
  dropped. 1.2.0 saved what it believed was the executing script text, but in a piped run that value is the
  caller's command line, not the script body - so the file it saved was the one-liner you typed, the holder
  task pointed at it, and the bootstrap rerun lost `-Status` / `-Measure` / `-Undo` the same way, since
  there was no parameter block to bind them to. The script is now fetched from its canonical raw URL and
  that file is what the rerun and the holder task point at. Note the trade-off this makes explicit: a piped
  fork or branch is replaced by canonical `main`, so a fork has to point the URL at itself.
- Passing exactly one switch through a relaunch broke argument binding on Windows PowerShell 5.1, where a
  single-element list unrolls to a plain string.
- A failed download or a failed elevation now prints the actual reason - no internet, UAC refused, UAC
  service disabled - and keeps the window open, instead of the console closing on an empty screen.

## [1.2.0] - 2026-07-18

### Added

- The tool runs from a one-line `irm ... | iex` command. A piped run has no file on disk, and this tool
  writes its `timer_undo_*.json` and BCD backup files next to the script and points the holder task at it,
  so the run saves itself to `%USERPROFILE%\timer-resolution-utility.ps1` first and reruns from there,
  elevating from the rerun as usual. What it saves is meant to be the exact text you piped in - a fork, a
  branch, or a local copy rather than a re-download of `main`.
- An existing copy at that path that differs is kept as `.bak` rather than overwritten.
- `-Status` / `-Measure` / `-Samples` / `-Undo` carry through both the bootstrap rerun and the UAC prompt
  through one shared list, so neither path can drop them.

### Changed

- The README Quick Start is now the plain `irm ... | iex` one-liner, because the script saves itself.

### Fixed

- An error under `irm | iex` closed your console. The script's error trap called `exit 1`, which in a piped
  run ends the session it was piped into rather than the script; it now rethrows the error instead, so it
  stops only itself.
- The script is now pure ASCII with no BOM, reversing the UTF-8 BOM 1.1.0 shipped: a BOM breaks
  `irm | iex`, and non-ASCII in a BOM-less file breaks the `-File` path under Windows PowerShell 5.1. The
  localized `bcdedit` tokens it matches on are written as `\uXXXX` escapes, and an `ascii-check` CI
  workflow keeps the file that way.

## [1.1.1] - 2026-07-18

### Changed

- The README's Related section now links GameDVR & FSO Disabler and Interrupt Affinity Utility.

### Fixed

- Two runs within the same second silently destroyed the first run's undo file and BCD backup. Both are
  named from a whole-second timestamp and were overwritten without asking, so what you would have reverted
  with was gone. Colliding names now get a numeric suffix - `_1`, `_2`, and so on, the first one free.

## [1.1.0] - 2026-07-18

Reliability release: every finding from a deep code review of the first release is fixed here.

### Changed

- The per-tweak backup, undo and apply logic now lives in a single definition table, so there is one place
  to extend and nothing to drift apart.

### Fixed

- A failing `bcdedit` was reported as `[OK]`. Windows PowerShell 5.1 never throws on a native command's
  nonzero exit code, so a locked or corrupt BCD store still printed `[OK]` and "REBOOT REQUIRED". Exit
  codes are now checked everywhere the script shells out to it - applying, reverting, and exporting the
  BCD - and the real error is surfaced, so a change that did not happen is no longer reported as one that
  did.
- Repeated `-Undo` re-picked the same snapshot instead of walking back through the chain: the
  `timer_undo_*.json` filter also matched the `*.applied.json` files an undo leaves behind, so the same
  file kept being re-applied. Undo now excludes files it has already applied, sorts by the timestamp in the
  name, and reports how many older snapshots remain after each step.
- The holder task was registered against the elevated administrator account rather than the user who
  launched it, so it did not run at that user's logon. It bit when a standard user elevated with a separate
  admin account: both the logon trigger and the principal were created for the admin. The pre-elevation
  user is now carried through the relaunch and the task gets an explicit Interactive principal.
- A holder task you already had was destroyed when you re-selected the holder tweak. The existing task's
  XML is now saved into the undo file, and `-Undo` restores that definition instead of just deleting the
  task.
- Undo recorded the wrong "previous" values when the system changed between the scan and your selection in
  the grid; state is re-read after the grid closes now.
- Localized `bcdedit` Yes/No values are canonicalized before being stored as the previous value, because
  `bcdedit /set` accepts only the invariant tokens - so an undo written on a non-English Windows restores
  the right thing. Values the script does not recognize are shown verbatim in the grid rather than
  masquerading as "default".
- Windows 11 coalesces background timer-resolution requests, which let the held resolution slip. `-Hold`
  now re-asserts the request hourly, and the status output flags when the holder has no system-wide effect
  yet.
- Windows PowerShell 5.1 misread the script's non-ASCII regex tokens - the ones that match localized
  `bcdedit` output. As of this release the file ships as UTF-8 with a BOM, so `powershell.exe` parses them
  correctly.

## [1.0.0] - 2026-07-17

### Added

- First public release. Shows the state of the whole Windows timer stack - timer resolution, dynamic tick,
  platform tick, HPET, and the Windows 11 `GlobalTimerResolutionRequests` - measures real `Sleep(1)`
  precision, and applies the tweaks you pick in a grid. `disabledynamictick`, `useplatformtick` and
  un-forcing HPET are each opt-in; there is no "apply all".
- Holds 0.5 ms timer resolution through a hidden scheduled task - pure PowerShell, no binary. On Windows 11
  the hold reaches the whole system only together with the system-wide registry tweak.
- Writes a JSON undo file and a full BCD backup before any change, and `-Undo` reverts the newest snapshot.
- `-Status` prints the timer state and exits; `-Measure` benchmarks `Sleep(1)` precision at the current and
  at the maximum resolution, so you can verify every tweak on your own hardware, and it does not need
  Administrator rights.
- Self-elevates through UAC. Zero external dependencies. A `Run.bat` ships alongside the script for a
  double-click start. The `bcdedit` and registry changes need a reboot; the holder task takes effect
  immediately.
- An open-source alternative to the closed-source TimerResolution.exe and ISLC.

[Unreleased]: https://github.com/vadyaravadim/timer-resolution-utility/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/vadyaravadim/timer-resolution-utility/compare/v1.2.3...v1.3.0
[1.2.3]: https://github.com/vadyaravadim/timer-resolution-utility/compare/v1.2.2...v1.2.3
[1.2.2]: https://github.com/vadyaravadim/timer-resolution-utility/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/vadyaravadim/timer-resolution-utility/compare/v1.0.1...v1.2.1
[1.0.1]: https://github.com/vadyaravadim/timer-resolution-utility/compare/v1.2.0...v1.0.1
[1.2.0]: https://github.com/vadyaravadim/timer-resolution-utility/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/vadyaravadim/timer-resolution-utility/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/vadyaravadim/timer-resolution-utility/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/vadyaravadim/timer-resolution-utility/releases/tag/v1.0.0
