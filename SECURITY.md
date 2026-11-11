# Security Policy

## Reporting a Vulnerability

Please report security issues **privately** via
[GitHub Security Advisories](https://github.com/vadyaravadim/timer-resolution-utility/security/advisories/new)
— not through a public issue.

Expect a first response within 7 days. If a fix is warranted, it ships as a new
tagged release and the advisory is published once the fix is available.

## Supported Versions

Only the latest release receives fixes. Older tags are left as-is — update to the
newest version before reporting.

## Scope

This script runs **with administrator rights**, edits the boot configuration via
`bcdedit`, writes a registry value under `Session Manager\kernel`, and registers a
scheduled task that runs at logon. That is its intended purpose, not a
vulnerability.

In scope:

- The self-elevation path (`irm | iex` downloading to `%USERPROFILE%` and
  re-running from there) — e.g. a way to make it execute attacker-controlled
  content
- The **holder task** (`timer-resolution-utility-holder`), which runs
  `powershell.exe -File "<script path>" -Hold` at logon — e.g. a way to bind it to
  a path an unprivileged user can write, turning it into code execution at logon
- The `timer_undo_*.json` and `bcd_backup_*` handling — e.g. a path that
  overwrites an unrelated file, or an undo file that restores something other
  than what was recorded
- The release pipeline — checksums, provenance, or the PowerShell Gallery package
  not matching the tagged source

Out of scope:

- Requiring admin rights, or the UAC prompt
- Needing a reboot for the bcdedit and registry tweaks — documented in
  [Using the picker](README.md#using-the-picker)
- Battery-life cost of `disabledynamictick`, or mouse stutter from the contested
  `useplatformtick` — both documented in the [FAQ](README.md#faq)
- Applying a tweak that makes timing worse on your hardware — that is what
  `-Measure` and [Reverting](README.md#reverting) are for

## Verifying a Release

Each release publishes `SHA256SUMS.txt` and Sigstore build provenance. Verify a
download before running it. The `gh` checks below need the
[GitHub CLI](https://cli.github.com/), signed in to a GitHub account (`gh auth login`).

Releases from v1.3.1 on are immutable: when one is published, GitHub itself attests
its tag, its commit and every file attached to it. This check works for every one of
them, whichever workflow built the file. Without a tag it checks against the latest
release; to check an older one, put its tag (`vX.Y.Z`) before the file name:

```powershell
gh release verify-asset .\timer-resolution-utility.ps1 -R vadyaravadim/timer-resolution-utility
```

Without the GitHub CLI or a GitHub account, compare the file's hash against the one in
the corresponding [release](https://github.com/vadyaravadim/timer-resolution-utility/releases):

```powershell
Get-FileHash .\timer-resolution-utility.ps1 -Algorithm SHA256
```

The hash only proves the file matches the release page. The provenance proves the
file was built from the tagged commit of this repository. Releases after v1.3.2 are
built by the release workflow shared by the six RigPolice Latency Toolbox scripts,
[`vadyaravadim/latency-toolbox-ci`](https://github.com/vadyaravadim/latency-toolbox-ci):

```powershell
gh attestation verify .\timer-resolution-utility.ps1 -R vadyaravadim/timer-resolution-utility --signer-workflow vadyaravadim/latency-toolbox-ci/.github/workflows/pipeline.yml
```

Without `--signer-workflow` the command rejects these releases: by default it only
accepts a signature from this repository's own workflows.

Releases v1.0.1 and v1.2.1 to v1.3.2 were built by this repository's own `release.yml`
(v1.0.0 and v1.1.0 to v1.2.0 carry no provenance). Verify those with:

```powershell
gh attestation verify .\timer-resolution-utility.ps1 -R vadyaravadim/timer-resolution-utility
```
