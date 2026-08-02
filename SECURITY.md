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
download before running it:

```powershell
Get-FileHash .\timer-resolution-utility.ps1 -Algorithm SHA256
```

Compare the hash against the one in the corresponding
[release](https://github.com/vadyaravadim/timer-resolution-utility/releases).
