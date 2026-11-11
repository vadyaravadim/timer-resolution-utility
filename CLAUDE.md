# Timer Resolution Utility

Maintainer notes for Claude Code and the maintainer. Contributors start with [CONTRIBUTING.md](https://github.com/vadyaravadim/.github/blob/main/CONTRIBUTING.md); `rigpolice`, named below, is the maintainer's private website repository.

A single self-contained PowerShell script (`timer-resolution-utility.ps1`, ~630 lines - the largest in the
family) that manages the Windows timer stack: timer resolution, the `bcdedit` timer tweaks, HPET, and the
Windows 11 global resolution requests. It shows state, measures real `Sleep(1)` precision, and applies the
tweaks picked in a grid. Part of a family of six single-script Windows tuning tools that share this layout:
one `.ps1`, `Run.bat`, `PSScriptAnalyzerSettings.psd1`, and two thin workflows, `ci.yml` and `release.yml`,
that call the family's shared pipeline in `vadyaravadim/latency-toolbox-ci`.

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
- **A piped run downloads the latest release asset and saves it to the user profile with no BOM.** It cannot
  persist `$MyInvocation.MyCommand.Definition` - under `irm | iex` that is the caller's command line, and
  the holder task ended up re-running the one-liner on every logon. The user profile rather than `%TEMP%`
  because the undo files live next to the script and the holder task points at it.
- The `trap` rethrows instead of `exit`ing when the script text was piped, which would close the user's own
  console.

## Version numbers went backwards once

1.0.1 was tagged AFTER 1.2.0 and is its descendant. `CHANGELOG.md` is ordered by release, not by version,
and says so. Do not "fix" that ordering - it would misstate what shipped when.

## The CI gates

The gates and the release job live in `.github/workflows/pipeline.yml` of `vadyaravadim/latency-toolbox-ci`,
not here: `ci.yml` runs it on every push and pull request, `release.yml` from a dispatch. Change a gate there.

**`main` moves only to a commit whose `ci` passed on a branch.** Its ruleset requires `ci / psanalyzer`,
`ci / ascii`, `ci / pester (5.1)` and `ci / pester (runner)` from GitHub Actions, so a commit made on `main`
is rejected. Push the branch, wait for `ci`, then merge it into `main` (`--no-ff` works while the branch is
up to date with `main`) and push; push a commit made on `main` to a branch first (`git push origin
main:<branch>`). A pin bump that renames one of these checks needs the new name in the ruleset before it is
pushed to `main`. The preview leg is not required: it only warns.

- **The ASCII gate - every tracked `.ps1` must be pure ASCII with no BOM.** Both halves are load-bearing: a
  BOM makes `irm | iex` choke on a leading U+FEFF, and non-ASCII in a BOM-less file turns into mojibake when
  Windows PowerShell 5.1 runs it with `-File`. This bites here more than elsewhere: the localized `bcdedit`
  tokens the script matches on are written as `\uXXXX` regex escapes for exactly this reason - do not paste
  the literal characters back in. Only `.ps1` files are checked; Markdown is free.
- **The lint gate - PSScriptAnalyzer over the whole repo, Error + Warning, any finding fails.** Suppressions
  live in `PSScriptAnalyzerSettings.psd1` with the reason written next to each rule; add a justified
  exclusion there instead of an inline suppression attribute. The file is the family's: lint fails unless it
  is byte-identical to the one in `vadyaravadim/latency-toolbox-ci` at the pinned commit, so change it there
  and copy it into all six repos. Lint also fails unless `ci.yml` and `release.yml` pin `latency-toolbox-ci`
  to the full SHA of the commit the run uses. It also checks syntax and .NET types against Windows
  PowerShell 5.1 (`PSUseCompatibleSyntax`/`PSUseCompatibleTypes`). The type check knows APIs only up to .NET
  Core 3.1, so a newer one such as `[Convert]::ToHexString` passes lint and only a test running under 5.1
  would catch it. `PSUseCompatibleCommands` stays off: it flagged every Pester 5 parameter against the
  Pester 3.4 built into 5.1.
- **The Pester gate runs every tracked `*.Tests.ps1` under Windows PowerShell 5.1 and the runner's `pwsh`,
  and both legs block the release.** `tests/timer-resolution-utility.Tests.ps1` loads single functions from
  the script's syntax tree and runs the `irm | iex` rerun against a stub script. Its whole-script test runs a
  copy in `TestDrive` with every device, task, registry and grid command mocked and `bcdedit` stubbed on
  `PATH`, only when elevated, after proving the mocks reach a script started with `&`; keep new tests that
  way, contributors run them on their own PCs. Test code stays 5.1-safe: `Run.bat` and the elevated relaunch
  always run 5.1.

## Release - the newest CHANGELOG section is the version

`gh workflow run release.yml` (or Actions > release > Run workflow) on `main` releases the newest `## [X.Y.Z]`
section of `CHANGELOG.md`: it gates that commit, stamps the version into `.VERSION`, hashes the script,
attests build provenance, publishes to the PowerShell Gallery and, last, creates the GitHub Release, which
creates the `vX.Y.Z` tag at that commit. A run from any other branch fails at the `release` environment before
the release job's first step, so nothing is written. Nothing ships from a push to `main`, and no tag exists
until every gate has passed.

- **The `irm | iex` URL is `releases/latest/download/timer-resolution-utility.ps1` - in the README AND in the
  script's bootstrap download, never `raw.githubusercontent.com/.../main`.** That is what keeps the
  sentence above true for the one-liner, and makes the saved copy byte-identical to the attested asset.
- **`ci.yml` and `release.yml` pin `pipeline.yml` of `vadyaravadim/latency-toolbox-ci` to the same full
  commit SHA, with its version tag as a comment.** There the release job `needs:` the lint, ASCII and Pester
  jobs of the same run, on the same commit: the push-triggered `ci` runs on `main` do not block a release,
  and a PSGallery version cannot be re-published. A pipeline change reaches this repo only when the pin
  moves: Dependabot proposes the bump monthly, a hand bump changes both lines together (lint fails while
  they differ), and reverting the whole bump - including a `PSScriptAnalyzerSettings.psd1` copy it brought -
  undoes it.
- **The provenance is signed by `pipeline.yml` of `vadyaravadim/latency-toolbox-ci`, not by this repo.**
  `gh attestation verify` needs
  `--signer-workflow vadyaravadim/latency-toolbox-ci/.github/workflows/pipeline.yml` (SECURITY.md); 1.0.1 and
  1.2.1 to 1.3.2 were signed by this repo's own `release.yml`; 1.0.0 and 1.1.0 to 1.2.0 carry no
  provenance. Never rename or delete `latency-toolbox-ci`: GitHub does not redirect a renamed reusable
  workflow, so every caller breaks.
- **`NUGET_API_KEY` is a secret of the `release` environment, which only `main` can use; the repository has no
  secret of that name.** `release.yml` passes it by name and the shared pipeline's release job runs in that
  environment, so no workflow on another branch can read the key. Rotate it with `gh secret set NUGET_API_KEY
  --env release`. After a pin bump, a dispatch on `main` stops at "Check the version is not released yet"
  while the newest CHANGELOG section is already released - that is the probe.
- **`v*` tags cannot be moved or deleted (tag ruleset) and releases are immutable (repo setting).** A broken
  release is fixed by releasing a new patch version (a new CHANGELOG section), never by re-tagging. The
  ruleset leaves tag creation open on purpose: the release creates the tag with `GITHUB_TOKEN`.
- **Never push a `v*` tag by hand.** It starts no release and cannot be deleted; unless it sits on the exact
  commit the release then runs on, the release stops before publishing and that version is burned.
- **Finish a failed release with "Re-run failed jobs" on that run, not a new run.** The re-run builds the
  same commit with the same pinned pipeline: the Gallery step (`.github/Publish-GalleryScript.ps1` of
  `vadyaravadim/latency-toolbox-ci`) skips a version already there with identical bytes and fails on
  different bytes. A run cancelled during the GitHub Release step can leave a draft - delete it before
  re-running. Release the next version instead only when that run is older than 30 days and can no longer
  be re-run. A failure inside the pipeline itself needs a fixed `latency-toolbox-ci` version, a bump here and
  a new run.

**Before releasing, move the `## [Unreleased]` bullets in `CHANGELOG.md` into a `## [X.Y.Z] - YYYY-MM-DD`
section and add its `[X.Y.Z]: .../compare/vPREV...vX.Y.Z` link at the bottom.** That section is the version.
The release job copies exactly that section into the release body and **fails before anything is tagged or
published when it is empty or its compare link is missing**; a newest section that is already released, or
lower than a released version, fails the same way. This is a gate on purpose, not a fallback: notes are
hand-written because GitHub's `--generate-notes` lists merged PRs, and this repo lands nearly everything as
direct commits to `main`, so it published releases whose whole body was a compare link.

Write the entries for someone who runs the tool, not for someone reading the diff: what changed on their
machine and why it matters. A fix says what was broken and what it cost them.

Do NOT bump `.VERSION` in the `.ps1` by hand - it is a placeholder the workflow overwrites, and a
hand-edited value that disagrees with the tag would only mislead whoever reads the committed file.
**The placeholder is `0.0.0` and must stay exactly that**: the banner reads its own `.VERSION` line and
prints `dev build` for `0.0.0`, the stamped tag otherwise. It used to be `1.0.0`, which is also a real tag,
so a clone of `main` was indistinguishable from the v1.0.0 release.

## README claims

**The README claims only what a published measurement shows** (the companion article, `bench/results`).
An effect nobody measured, on frame times, DPC latency, stutter or input lag, is attributed to the guides
that recommend the tweak or marked as not measured, never stated as fact, and the star ask names no
effect. Frame time and ISR/DPC time are not input lag. The method lives in rigpolice's
`.claude/rules/bench-methodology.md`, section "Conclusions".

## The RigPolice pages that mirror this script

- **The hub card.** `src/lib/latency-toolbox.ts` in the rigpolice repo holds this script's card on
  https://rigpolice.com/system/latency-toolbox/: what it does, what was measured with it, and whether it
  writes an undo file. A release that changes any of those updates the card in the same pass; nothing
  there reads this repo, so the card drifts silently otherwise.
