<div align="center">

# Timer Resolution Utility

**Set 0.5 ms timer resolution. Tame dynamic tick & HPET. Measure, don't guess.**

An open-source PowerShell script for the whole Windows timer stack: view and set **timer resolution**, apply the **`disabledynamictick` / `useplatformtick` bcdedit tweaks**, un-force **HPET** — with a built-in `Sleep(1)` benchmark that shows the real effect on *your* hardware. A transparent alternative to the closed-source `TimerResolution.exe` from forum threads.
Zero install. Zero dependencies. Zero binaries. Built-in undo.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Windows 10/11](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?logo=windows)](https://www.microsoft.com/windows)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white)](https://docs.microsoft.com/en-us/powershell/)
[![Latest release](https://img.shields.io/github/v/release/vadyaravadim/timer-resolution-utility)](https://github.com/vadyaravadim/timer-resolution-utility/releases)
![GitHub Stars](https://img.shields.io/github/stars/vadyaravadim/timer-resolution-utility?style=social)

</div>

---

```
=== Windows timer status ===
Timer resolution   : current 1 ms | finest 0.5 ms | OS default 15.625 ms
Sleep(1) actually  : avg 15.142 ms (10 samples; run -Measure for a full benchmark)
Dynamic tick       : default (enabled)
Platform tick      : default (not forced)
Forced HPET clock  : not forced (good)
HPET device        : present (OK)
Global timer res   : not set - resolution requests are per-process (Win10 2004+ default)
Holder task        : not installed
```

> Real output from a Windows 11 machine. Note the catch: the *system* reports 1 ms (some app requested it), but this process still sleeps **15 ms** — that's the Windows 11 per-process timer behavior this utility explains and fixes. See [Windows 11 changed everything](#timer-resolution-on-windows-11-why-old-tools-stopped-working).

## Quick Start

**Easiest — download & double-click:**

1. Click **Code ▸ Download ZIP** at the top of this page, then unzip.
2. Double-click **`Run.bat`**.
3. Click **Yes** on the UAC prompt (the script requests admin rights on its own).
4. Read the status block, then `Ctrl`-click the tweaks you want in the grid and click **OK**.
5. **Reboot** (for the bcdedit / registry tweaks; the resolution holder works immediately).

**One-liner** instead (in any PowerShell — it self-elevates):

```powershell
irm https://raw.githubusercontent.com/vadyaravadim/timer-resolution-utility/main/timer-resolution-utility.ps1 | iex
```

The script saves itself to `%USERPROFILE%\timer-resolution-utility.ps1` (not a temp folder) on purpose: the `timer_undo_*.json` and BCD backup files are written next to it, and the resolution-holder scheduled task points at it.

**Or clone:**

```powershell
git clone https://github.com/vadyaravadim/timer-resolution-utility.git
cd timer-resolution-utility
.\Run.bat
```

### Switches

| Switch | Effect |
| --- | --- |
| *(none)* | Show timer status, then pick tweaks in a grid — each one opt-in |
| `-Status` | Status only, change nothing |
| `-Measure [-Samples N]` | Benchmark real `Sleep(1)` precision at current vs finest resolution (no admin needed) |
| `-Undo` | Revert the changes recorded in the newest `timer_undo_*.json` |

## What It Does

1. **Shows** the whole timer stack: current/finest timer resolution, `disabledynamictick`, `useplatformtick`, forced `useplatformclock` (HPET), the HPET device, the Windows 11 `GlobalTimerResolutionRequests` key, and whether a resolution holder is installed
2. **Measures** actual `Sleep(1)` precision — so you verify every tweak on your own hardware instead of trusting a forum post
3. **Backs up** before changing anything: a full `bcdedit /export` BCD store backup plus a `timer_undo_*.json` with the previous value of every setting it touches
4. **Applies only what you select** in the grid — there is no "apply all" button on purpose

**Measured effect** (same Windows 11 machine as above, 20 samples):

```
Sleep(1) at the CURRENT resolution:
  avg 15.199 ms | stdev 0.398 | min 14.600 | max 15.912
Sleep(1) after requesting the FINEST resolution for this process:
  avg  1.404 ms | stdev 0.182 | min  1.010 | max  1.630
```

## The Problem: Why the Windows Timer Matters

By default Windows wakes the scheduler every **15.625 ms** (64 Hz). Anything that waits — frame limiters, `Sleep()`-based game loops, audio buffers, input polling — can only be as precise as that tick. Raising timer resolution to **0.5–1 ms** makes those waits precise; the timer tweaks (`disabledynamictick`, `useplatformtick`) change *how* the tick is generated.

**Symptoms this addresses:**

- Frame limiters overshooting (capped 240 fps that actually delivers uneven 220–260)
- Micro-stutters and frame-time spikes despite high FPS
- Sleep-based game logic (common in older engines) running visibly unevenly

## Timer Resolution on Windows 11 (Why Old Tools Stopped Working)

Since **Windows 10 2004**, a raised timer resolution applies **only to the process that requested it** — and Windows 11 also ignores requests from minimized/background windows. That's why running `TimerResolution.exe` in the background no longer does what it did in 2018.

Two things restore the old behavior, and this utility handles both:

1. The documented **`GlobalTimerResolutionRequests = 1`** registry value (Windows 11 / Server 2022+) makes resolution requests system-wide again.
2. A **holder** must keep the request alive — a resolution request dies with the process that made it. The utility installs a hidden scheduled task (pure PowerShell, no binary) that requests the finest resolution at logon and holds it.

## How It Works

- **Timer resolution** is read and requested via `NtQueryTimerResolution` / `NtSetTimerResolution` (ntdll) — the same calls TimerResolution.exe and ISLC make, compiled in-memory from inline C#; no `.exe` is shipped or dropped
- **Dynamic tick / platform tick / HPET clock** are standard BCD settings, applied with documented `bcdedit /set` commands:

```
bcdedit /set disabledynamictick yes   (stop the kernel from turning the tick off on idle)
bcdedit /set useplatformtick yes      (fixed platform tick - contested, measure it)
bcdedit /deletevalue useplatformclock (un-force HPET if an old guide forced it)
```

- **Windows 11 system-wide requests**:

```
HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel
    Value: GlobalTimerResolutionRequests (DWORD) 1 = system-wide
```

- The **holder task** (`timer-resolution-utility-holder`) runs this same script with `-Hold` at logon, hidden, and just keeps the finest resolution requested

## Verify

Run the built-in benchmark before and after any tweak:

```powershell
.\timer-resolution-utility.ps1 -Measure
```

If a tweak doesn't improve your `Sleep(1)` numbers (or your frame-time graph), undo it. That's the whole philosophy: **measure, don't cargo-cult**.

## Reverting

```powershell
.\timer-resolution-utility.ps1 -Undo
```

Reverts everything recorded in the newest `timer_undo_*.json`: bcdedit values are restored or removed, the registry value is restored or deleted, the holder task is unregistered (or restored to its previous definition if it existed before the tweak). Ran the utility several times? Undo files are per-run snapshots — revert newest-to-oldest; after each `-Undo` the script tells you how many older undo files remain.

Last resort: every bcdedit change is preceded by a full BCD store export (`bcd_backup_*` next to the script). Restore it with:

```powershell
bcdedit /import "C:\path\to\bcd_backup_20260717_120000"
```

## Requirements

| | |
|---|---|
| **Windows** | 10, 11 |
| **PowerShell** | Windows PowerShell 5.1 (ships with Windows 10/11). The tweak grid uses `Out-GridView` — PowerShell 7 needs the `Microsoft.PowerShell.GraphicalTools` module. `-Measure` works anywhere |
| **Rights** | Administrator (self-elevates via UAC). `-Measure` runs without admin |

## FAQ

### What is timer resolution in Windows?

The granularity of the system interrupt timer — how often Windows can wake a waiting thread. Default is 15.625 ms (64 Hz); applications can request down to 0.5 ms. Every `Sleep()`, timer callback, and frame limiter is quantized to it.

### Does 0.5 ms timer resolution reduce input lag or increase FPS?

It doesn't raise average FPS. It makes **waiting precise**: frame limiters hit their cap exactly, sleep-based game loops stop jittering, frame pacing evens out. If a game busy-waits instead of sleeping (many modern engines do), you won't see a difference — which is exactly what `-Measure` and your frame-time graph will tell you.

### Why doesn't TimerResolution.exe work on Windows 11?

Two changes: since Windows 10 2004 a resolution request affects **only the requesting process**, and Windows 11 ignores requests from background windows. A background tool raising "the system timer" is mostly a no-op now. The fix is the `GlobalTimerResolutionRequests = 1` registry value plus a persistent holder — both are tweaks in this utility's grid.

### Should I disable dynamic tick (`disabledynamictick yes`)?

It's the most commonly beneficial bcdedit timer tweak: it stops the kernel from suspending the periodic tick on idle, which some systems handle poorly (DPC latency spikes). It costs battery life on laptops. Apply it alone, measure, keep it only if your numbers improve.

### Should I use `useplatformtick yes`?

Contested. It forces a fixed platform tick instead of the TSC-driven one; some systems report better frame pacing, others get **mouse stutter**. This is why the utility has no "apply all" button — try it alone and `-Undo` if it feels worse.

### Should HPET be on or off for gaming?

The old advice to **force** HPET (`bcdedit /set useplatformclock true`) is outdated and usually *increases* latency on modern systems — Windows picks the best clock source (TSC) on its own. If an old guide made you force it, the grid offers to remove it. Disabling the HPET *device* in Device Manager is a separate debate; this utility shows its state and touches nothing uninvited.

### How is this different from TimerResolution.exe / ISLC?

`TimerResolution.exe` (Lucas Hale) is a closed-source `.exe` from 2010-era forums that doesn't survive the Windows 11 per-process change on its own. ISLC holds resolution but is also closed-source and does memory-list cleaning you may not want. This is a readable script that does the same `NtSetTimerResolution` call, adds the Windows 11 registry piece, covers the bcdedit tweaks, measures the result, and writes an undo file first.

### How is this different from SetTimerResolution.exe / MeasureSleep.exe?

Those two binaries (bundled in valleyofdoom's TimerResolution and various tweak packs) split the job: `SetTimerResolution.exe` holds the resolution, `MeasureSleep.exe` verifies it. This script does both — the holder task makes the same `NtSetTimerResolution` call, and `-Measure` is the MeasureSleep equivalent — without shipping any `.exe`. On top of that it covers the `GlobalTimerResolutionRequests` registry value and the bcdedit tick tweaks, with an undo file for all of it.

### Is it safe?

Every change is opt-in, previous values go to `timer_undo_*.json`, and bcdedit changes are additionally preceded by a full BCD store export. Worst case: `-Undo`, reboot. The one genuinely contested tweak (`useplatformtick`) is labeled as such in the grid.

## Disclaimer

bcdedit edits modify the boot configuration. The utility backs up the BCD store before touching it and every change is reversible with `-Undo`, but as with any system tweak: use at your own risk.

## Related

- [MSI Mode Utility](https://github.com/vadyaravadim/msi-mode-utility) — enable MSI mode (Message Signaled Interrupts) for GPU, USB, network & audio devices to cut DPC latency and input lag
- [Interrupt Affinity Utility](https://github.com/vadyaravadim/interrupt-affinity-utility) — pin GPU, network, USB & audio interrupts to specific CPU cores (P/E-core aware) to tame DPC latency
- [CPU Parking Disabler](https://github.com/vadyaravadim/cpu-parking-disabler) — disable CPU core parking on Windows 10/11 to fix micro-stutters and input lag
- [GameDVR & FSO Disabler](https://github.com/vadyaravadim/gamedvr-fso-disabler) — disable Game DVR / Xbox Game Bar capture and Fullscreen Optimizations on Windows 10/11 to fix capture stutters and frame drops

Same idea across all five: one transparent PowerShell script, built-in rollback.

## License

[MIT](LICENSE) — use at your own risk.

---

<div align="center">

If this fixed your frame pacing, consider giving it a ⭐

[Report Issues](https://github.com/vadyaravadim/timer-resolution-utility/issues)

</div>
