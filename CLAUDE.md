# Timer Resolution Utility

A single self-contained PowerShell script (`timer-resolution-utility.ps1`, ~630 lines - the largest in the
family) that manages the Windows timer stack: timer resolution, the `bcdedit` timer tweaks, HPET, and the
Windows 11 global resolution requests. It shows state, measures real `Sleep(1)` precision, and applies the
tweaks picked in a grid. Part of a family of six single-script Windows tuning tools that share this layout:
one `.ps1`, `Run.bat`, `PSScriptAnalyzerSettings.psd1`, and the same three workflows.

## The undo chain is the fragile part

Undo files are per-run JSON snapshots applied newest-to-oldest; only the OLDEST holds the original state.
Everything below exists because a broken chain silently strands the machine in a tweaked state:

- **A no-op run must write NO snapshot.** Re-selecting a tweak already in place used to record the tweaked
  values as "previous", so the next `-Undo` spent a step of the chain restoring the tweaks it was supposed
  to revert. Tweaks already in place are skipped (`IsApplied` per definition). The holder task is the one
  exemption - reinstalling it is what rewrites a stale script path.
- **`-Reset` is the escape hatch, not a second revert implementation.** It drives the same
  `Invoke-UndoEntries` engine with records describing the Windows default, and snapshots first so `-Undo`
  can bring the tweaked state back. Keep it on that one engine.
- **`bcdedit` exit codes are checked** (`Invoke-Bcdedit`). A failing call reported as `[OK]` is how an undo
  file comes to describe changes that never happened.
- **State is re-read AFTER the grid selection.** The system can change while the picker is open, and a
  snapshot taken before selection records the wrong "previous" values.
- **Localized `bcdedit` Yes/No values are canonicalized before storage**, and unrecognized values are shown
  verbatim rather than guessed at - the tool has to work on a non-English Windows.

## The holder task

- **It runs under `conhost --headless`, not `-WindowStyle Hidden`.** Hidden hides only PowerShell's own
  console window; with a delegated default terminal (out-of-the-box Windows 11, where Windows Terminal owns
  the window) it left an empty console tab open all session. `--headless` is ConPTY, so builds below 17763
  keep the old command - they predate terminal delegation and Hidden works there.
- **Stop the running instance before re-registering OR unregistering it.** Neither call terminates a
  running task, and the policy ignores a new instance while one runs - so a "restart" was a no-op and an
  unregister left the resolution held with no task to stop it by.
- **The holder watches its parent and exits with it**, ticking every 30s. The scheduler now launches the
  conhost wrapper, so killing the task kills only the wrapper; without the watch, the `-Hold` child
  survives as an unkillable-by-task orphan and every reinstall leaves another one behind.
- **`-Hold` re-asserts the request hourly** - Windows 11 coalesces background resolution requests.
- The task is bound to the pre-elevation user with an explicit Interactive principal, not the elevated
  admin account, or it never runs at that user's logon. A pre-existing holder task's XML is saved into the
  undo file and restored on `-Undo`.

## Invariants shared with the family

- **`Get-ForwardedSwitchList` is the ONE place mode switches are listed**, used by both the `irm | iex`
  bootstrap rerun and the UAC elevation. Splat it as `@(...)`: on PS 5.1 a single forwarded switch unrolls
  to a scalar string and breaks `powershell.exe -File` switch binding.
- **A piped run downloads from the canonical raw URL and saves to the user profile with no BOM.** It cannot
  persist `$MyInvocation.MyCommand.Definition` - under `irm | iex` that is the caller's command line, and
  the holder task ended up re-running the one-liner on every logon. The user profile rather than `%TEMP%`
  because the undo files live next to the script and the holder task points at it.
- The `trap` rethrows instead of `exit`ing when the script text was piped, which would close the user's own
  console.

## Version numbers went backwards once

1.0.1 was tagged AFTER 1.2.0 and is its descendant. `CHANGELOG.md` is ordered by release, not by version,
and says so. Do not "fix" that ordering - it would misstate what shipped when.

## The two CI gates

- **`ascii-check.yml` - the .ps1 must be pure ASCII with no BOM.** Both halves are load-bearing: a BOM
  makes `irm | iex` choke on a leading U+FEFF, and non-ASCII in a BOM-less file turns into mojibake when
  Windows PowerShell 5.1 runs it with `-File`. This bites here more than elsewhere: the localized `bcdedit`
  tokens the script matches on are written as `\uXXXX` regex escapes for exactly this reason - do not paste
  the literal characters back in. Only the `.ps1` is checked; Markdown is free.
- **`lint.yml` - PSScriptAnalyzer over the whole repo, Error + Warning, any finding fails.** Suppressions
  live in `PSScriptAnalyzerSettings.psd1` with the reason written next to each rule. Extend that file with
  a justification instead of adding an inline suppression attribute.

## Release - the tag is the only source of truth

`git tag vX.Y.Z && git push origin vX.Y.Z` runs `release.yml`, which stamps the tag into `.VERSION`, hashes
the script, attests build provenance, creates the GitHub Release and publishes to the PowerShell Gallery.
Nothing ships from a push to `main`.

**Before tagging, move the `## [Unreleased]` bullets in `CHANGELOG.md` into a `## [X.Y.Z] - YYYY-MM-DD`
section and add the compare link at the bottom.** The release job copies exactly that section into the
release body and **fails the release when the tag's section is missing**. This is a gate on purpose, not a
fallback: notes are hand-written because GitHub's `--generate-notes` lists merged PRs, and this repo lands
nearly everything as direct commits to `main`, so it published releases whose whole body was a compare
link.

Write the entries for someone who runs the tool, not for someone reading the diff: what changed on their
machine and why it matters. A fix says what was broken and what it cost them.

Do NOT bump `.VERSION` in the `.ps1` by hand - it is a placeholder the workflow overwrites, and a
hand-edited value that disagrees with the tag would only mislead whoever reads the committed file.
