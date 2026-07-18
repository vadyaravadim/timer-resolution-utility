<#
.SYNOPSIS
    Windows timer stack manager: timer resolution, dynamic tick, HPET.
.DESCRIPTION
    Shows the current state of the Windows timer stack (timer resolution,
    bcdedit timer tweaks, HPET, Windows 11 global resolution requests),
    measures real Sleep(1) precision, and applies the tweaks you select
    in a grid - each one opt-in, with a JSON undo file and a full BCD
    backup written before any change. Zero external dependencies.
.PARAMETER Status
    Show the timer status and exit (no tweak grid).
.PARAMETER Measure
    Benchmark Sleep(1) precision at the current and at the maximum timer
    resolution, then exit. Does not require Administrator.
.PARAMETER Samples
    Sample count for -Measure (default 30).
.PARAMETER Undo
    Revert the changes recorded in the newest timer_undo_*.json file.
.NOTES
    bcdedit and registry changes need a reboot; the holder task takes
    effect immediately.
    After several runs, undo files are per-run snapshots: apply them
    newest-to-oldest - only the oldest holds the original state.
#>
[CmdletBinding()]
param(
    [switch]$Status,
    [switch]$Measure,
    [int]$Samples = 30,
    [switch]$Undo,
    [switch]$Hold,      # internal: used by the scheduled task to keep max resolution requested
    [switch]$Elevated,  # internal: set by the self-elevation relaunch
    [string]$LogonUser  # internal: the pre-elevation user, for the holder task binding
)

$ErrorActionPreference = 'Stop'
$TaskName = 'timer-resolution-utility-holder'
$KernelKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel'
$GlobalValue = 'GlobalTimerResolutionRequests'
$IsWin11 = [Environment]::OSVersion.Version.Build -ge 22000

# Keep the self-elevated window open so the user can read the output.
function Wait-IfElevatedWindow {
    if ($Elevated) { Read-Host "Press Enter to close" | Out-Null }
}

# Without this, an unhandled error closes the self-elevated window before
# the user can read the message.
trap {
    Write-Host "ERROR: $_" -ForegroundColor Red
    Wait-IfElevatedWindow
    # Under `irm | iex` this runs inside the user's own session, where `exit`
    # would close their console - rethrow so only the piped script stops.
    if ($PSCommandPath) { exit 1 }
    break
}

# Mode switches forwarded on every relaunch (the irm|iex bootstrap rerun below
# and the self-elevation later) - one list so neither path can silently drop one.
function Get-ForwardedSwitchList {
    $a = @()
    if ($Status)  { $a += '-Status' }
    if ($Measure) { $a += '-Measure', '-Samples', $Samples }
    if ($Undo)    { $a += '-Undo' }
    $a
}

# Launched via `irm <url> | iex` - no file on disk. The undo/BCD-backup files
# are written next to the script and the holder task points at it, so a stable
# path is required: save the script to the user profile and rerun it from
# there (the rerun handles elevation).
if (-not $PSCommandPath) {
    # Persist the text that is actually executing, not a re-download: what the
    # user piped in - a fork, a branch, a local copy - is what must run.
    $body = $MyInvocation.MyCommand.Definition
    if (-not $body) { throw "Cannot recover the executing script text; save the script to a file and run it with -File." }
    $saved = Join-Path $env:USERPROFILE 'timer-resolution-utility.ps1'
    if ((Test-Path $saved) -and ([IO.File]::ReadAllText($saved) -cne $body)) {
        Copy-Item $saved "$saved.bak" -Force
        Write-Host "Existing $saved differs - previous copy kept as $saved.bak" -ForegroundColor Yellow
    }
    [IO.File]::WriteAllText($saved, $body, [Text.Encoding]::ASCII)
    Write-Host "Script saved to: $saved (undo and backup files will be written next to it)" -ForegroundColor Cyan
    $fwd = Get-ForwardedSwitchList
    powershell -NoProfile -ExecutionPolicy Bypass -File $saved @fwd
    # The rerun's exit code stays in $LASTEXITCODE for scripted callers.
    return
}

Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

public static class TimerNative {
    [DllImport("ntdll.dll")]
    public static extern int NtQueryTimerResolution(out uint min, out uint max, out uint cur);
    [DllImport("ntdll.dll")]
    public static extern int NtSetTimerResolution(uint desired, bool set, out uint cur);

    // Measured in C#, not PowerShell: the interpreter adds jitter comparable
    // to the sub-millisecond differences we are trying to show.
    public static double[] MeasureSleep(int samples) {
        Thread.Sleep(1);                       // warm-up: JIT + first-timer alignment
        double[] r = new double[samples];
        Stopwatch sw = new Stopwatch();
        for (int i = 0; i < samples; i++) {
            sw.Restart();
            Thread.Sleep(1);
            sw.Stop();
            r[i] = sw.Elapsed.TotalMilliseconds;
        }
        return r;
    }
}
"@

function Get-TimerResolution {
    $min = 0; $max = 0; $cur = 0
    [void][TimerNative]::NtQueryTimerResolution([ref]$min, [ref]$max, [ref]$cur)
    # Units are 100 ns; min = coarsest (default 15.625 ms), max = finest (usually 0.5 ms).
    [PSCustomObject]@{ DefaultMs = $min / 10000; FinestMs = $max / 10000; CurrentMs = $cur / 10000 }
}

function Get-SleepStats([int]$Count) {
    $d = [TimerNative]::MeasureSleep($Count)
    $avg = ($d | Measure-Object -Average).Average
    $var = ($d | ForEach-Object { [math]::Pow($_ - $avg, 2) } | Measure-Object -Average).Average
    [PSCustomObject]@{
        Avg = $avg; StDev = [math]::Sqrt($var)
        Min = ($d | Measure-Object -Minimum).Minimum
        Max = ($d | Measure-Object -Maximum).Maximum
    }
}

# ---- Hold mode: run by the scheduled task, keeps max resolution requested ----
# The request only lives as long as the requesting process, hence the loop.
if ($Hold) {
    $res = Get-TimerResolution
    $desired = [uint32]($res.FinestMs * 10000)
    $cur = 0
    # Re-assert every hour: Win11 can coalesce/ignore requests from background
    # processes, and a periodic re-request costs nothing.
    while ($true) {
        [void][TimerNative]::NtSetTimerResolution($desired, $true, [ref]$cur)
        Start-Sleep -Seconds 3600
    }
}

# ---- Measure mode: no Administrator needed ----
if ($Measure) {
    $res = Get-TimerResolution
    Write-Host ("Timer resolution: current {0:0.###} ms, finest supported {1:0.###} ms, OS default {2:0.###} ms" -f `
        $res.CurrentMs, $res.FinestMs, $res.DefaultMs) -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Sleep(1) at the CURRENT resolution ($Samples samples):"
    $before = Get-SleepStats $Samples
    Write-Host ("  avg {0:0.000} ms | stdev {1:0.000} | min {2:0.000} | max {3:0.000}" -f `
        $before.Avg, $before.StDev, $before.Min, $before.Max) -ForegroundColor Yellow

    $cur = 0
    [void][TimerNative]::NtSetTimerResolution([uint32]($res.FinestMs * 10000), $true, [ref]$cur)
    Write-Host "Sleep(1) after requesting the FINEST resolution for this process:"
    $after = Get-SleepStats $Samples
    Write-Host ("  avg {0:0.000} ms | stdev {1:0.000} | min {2:0.000} | max {3:0.000}" -f `
        $after.Avg, $after.StDev, $after.Min, $after.Max) -ForegroundColor Green
    [void][TimerNative]::NtSetTimerResolution([uint32]($res.FinestMs * 10000), $false, [ref]$cur)

    if ($IsWin11) {
        $g = (Get-ItemProperty -Path $KernelKey -Name $GlobalValue -ErrorAction SilentlyContinue).$GlobalValue
        if ($g -ne 1) {
            Write-Host ""
            Write-Host "Note: since Windows 10 2004 a resolution request only affects the requesting process. To make requests system-wide again, apply the GlobalTimerResolutionRequests tweak (run without -Measure)." -ForegroundColor DarkGray
        }
    }
    Wait-IfElevatedWindow
    return
}

# ---- Everything below reads bcdedit / writes system state: Administrator required ----
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Not running as Administrator. Requesting elevation..." -ForegroundColor Yellow
    try {
        # Forward the current user: under elevation with a different admin
        # account $env:USERNAME changes, and the holder task would bind to it.
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass',
                     '-File', "`"$PSCommandPath`"", '-Elevated',
                     '-LogonUser', "`"$env:USERDOMAIN\$env:USERNAME`"") + (Get-ForwardedSwitchList)
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
    } catch {
        Write-Host "ERROR: elevation was refused. Run this script as Administrator." -ForegroundColor Red
    }
    return
}

# ---- Gather current state ----
# Parsed by element NAME (locale-invariant); the Yes/No value column is
# matched loosely because some localized builds translate it.
function Get-BcdValue([string]$Name) {
    if (-not $bcdOk) { return $null }
    foreach ($line in $bcdRaw) {
        if ($line -match ('^\s*{0}\s+(\S+)\s*$' -f [regex]::Escape($Name))) { return $Matches[1] }
    }
    return $null
}
# Localized letters are \uXXXX regex escapes so the file stays pure ASCII:
# a BOM breaks `irm | iex` (the parser chokes on a leading U+FEFF), and
# non-ASCII literals in a BOM-less file break -File runs under PS 5.1.
function Test-BcdOn($Value) { $Value -match '^(yes|\u0434\u0430|oui|ja|s[i\u00ed]|sim|tak|evet)$' }
# bcdedit /set only accepts invariant tokens, so undo must not replay a
# localized Yes/No captured from /enum output - canonicalize when recognized.
function ConvertTo-BcdBool($Value) {
    if ($null -eq $Value) { $null }
    elseif (Test-BcdOn $Value) { 'yes' }
    elseif ($Value -match '^(no|\u043d\u0435\u0442|non|nein|n[a\u00e3]o|nie|hay[\u0131i]r)$') { 'no' }
    else { $Value }
}
function Invoke-Bcdedit {
    # bcdedit reports failure via exit code only - PowerShell never turns a
    # native command's nonzero exit into an exception, so without this check
    # a failed change would be reported as [OK].
    $out = & bcdedit @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "bcdedit $($args -join ' '): $out" }
    $out
}
function Read-TimerTweakState {
    $script:bcdRaw = @(bcdedit /enum "{current}" 2>&1)
    $script:bcdOk = ($LASTEXITCODE -eq 0)
    $script:dynTick    = Get-BcdValue 'disabledynamictick'
    $script:platTick   = Get-BcdValue 'useplatformtick'
    $script:platClock  = Get-BcdValue 'useplatformclock'
    $script:globalReq  = (Get-ItemProperty -Path $KernelKey -Name $GlobalValue -ErrorAction SilentlyContinue).$GlobalValue
    $script:holderTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}
Read-TimerTweakState
# HPET exposes ACPI ID PNP0103; absence just means the board doesn't expose it.
$hpet = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'ACPI\PNP0103*' } | Select-Object -First 1
$res = Get-TimerResolution
$quick = Get-SleepStats 10

function Format-BcdState($Value, [string]$OnText, [string]$OffText) {
    if ($null -eq $Value) { $OffText }
    elseif (Test-BcdOn $Value) { $OnText }
    else { "set to '$Value'" }
}

Write-Host ""
Write-Host "=== Windows timer status ===" -ForegroundColor Cyan
Write-Host ("Timer resolution   : current {0:0.###} ms | finest {1:0.###} ms | OS default {2:0.###} ms" -f `
    $res.CurrentMs, $res.FinestMs, $res.DefaultMs)
Write-Host ("Sleep(1) actually  : avg {0:0.000} ms (10 samples; run -Measure for a full benchmark)" -f $quick.Avg)
if (-not $bcdOk) {
    Write-Host "bcdedit values     : could not read BCD store" -ForegroundColor Yellow
} else {
    Write-Host ("Dynamic tick       : {0}" -f (Format-BcdState $dynTick 'DISABLED (disabledynamictick yes)' 'default (enabled)'))
    Write-Host ("Platform tick      : {0}" -f (Format-BcdState $platTick 'FORCED (useplatformtick yes)' 'default (not forced)'))
    Write-Host ("Forced HPET clock  : {0}" -f (Format-BcdState $platClock 'FORCED (useplatformclock yes) - outdated tweak, consider removing' 'not forced (good)'))
}
if ($hpet) { Write-Host ("HPET device        : present ({0})" -f $hpet.Status) }
else       { Write-Host  "HPET device        : not exposed by this system" }
if ($IsWin11) {
    $gState = if ($globalReq -eq 1) { 'system-wide (1)' } else { 'not set - resolution requests are per-process (Win10 2004+ default)' }
    Write-Host ("Global timer res   : {0}" -f $gState)
}
$holderState = if ($holderTask) { "installed ($($holderTask.State))" } else { 'not installed' }
if ($holderTask -and $IsWin11 -and $globalReq -ne 1) {
    $holderState += ' - Win11: no system-wide effect until the global requests tweak is applied'
}
Write-Host ("Holder task        : {0}" -f $holderState)
Write-Host ""

if ($Status) { Wait-IfElevatedWindow; return }

# ---- Undo mode ----
if ($Undo) {
    # -Filter also matches renamed *.applied.json files, so exclude them, and
    # sort by the name stamp - LastWriteTime survives renames and can mislead.
    $undoFile = Get-ChildItem -Path $PSScriptRoot -Filter 'timer_undo_*.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '\.applied\.json$' } |
        Sort-Object Name | Select-Object -Last 1
    if (-not $undoFile) {
        Write-Host "No timer_undo_*.json found next to the script - nothing to undo." -ForegroundColor Yellow
        Wait-IfElevatedWindow; return
    }
    Write-Host "Reverting: $($undoFile.Name)" -ForegroundColor Cyan
    foreach ($item in (Get-Content $undoFile.FullName -Raw | ConvertFrom-Json)) {
        switch ($item.Kind) {
            'bcd' {
                if ($null -ne $item.Previous) { Invoke-Bcdedit /set $item.Name $item.Previous | Out-Null }
                else { Invoke-Bcdedit /deletevalue $item.Name | Out-Null }
                Write-Host "  [bcd ] $($item.Name) -> $(if ($null -ne $item.Previous) { $item.Previous } else { 'removed (default)' })" -ForegroundColor Green
            }
            'reg' {
                if ($null -ne $item.Previous) {
                    New-ItemProperty -Path $item.Path -Name $item.Value -Value $item.Previous -PropertyType DWord -Force | Out-Null
                } else {
                    Remove-ItemProperty -Path $item.Path -Name $item.Value -ErrorAction SilentlyContinue
                }
                Write-Host "  [reg ] $($item.Value) -> $(if ($null -ne $item.Previous) { $item.Previous } else { 'removed (default)' })" -ForegroundColor Green
            }
            'task' {
                if ($item.Xml) {
                    Register-ScheduledTask -TaskName $item.Name -Xml $item.Xml -Force | Out-Null
                    Write-Host "  [task] $($item.Name) restored to previous definition" -ForegroundColor Green
                } else {
                    Unregister-ScheduledTask -TaskName $item.Name -Confirm:$false -ErrorAction SilentlyContinue
                    Write-Host "  [task] $($item.Name) removed" -ForegroundColor Green
                }
            }
        }
    }
    Rename-Item $undoFile.FullName ($undoFile.FullName -replace '\.json$', '.applied.json')
    $remaining = @(Get-ChildItem -Path $PSScriptRoot -Filter 'timer_undo_*.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '\.applied\.json$' })
    if ($remaining.Count) {
        Write-Host "$($remaining.Count) older undo file(s) remain - run -Undo again to revert earlier runs." -ForegroundColor Yellow
    }
    Write-Host "Done. Reboot for bcdedit/registry reverts to take effect." -ForegroundColor Green
    Wait-IfElevatedWindow; return
}

# ---- Build the tweak grid: each row is one opt-in change ----
if (-not (Get-Command Out-GridView -ErrorAction SilentlyContinue)) {
    Write-Host "Out-GridView is not available in this PowerShell. Run the script with Windows PowerShell (powershell.exe), or install the Microsoft.PowerShell.GraphicalTools module." -ForegroundColor Red
    Wait-IfElevatedWindow
    return
}

$rows = New-Object System.Collections.Generic.List[object]
if ($IsWin11) {
    $rows.Add([PSCustomObject]@{
        Id = 'global-reg'; Tweak = 'System-wide timer resolution requests'
        Current = $(if ($globalReq -eq 1) { 'already 1' } else { 'not set (per-process)' })
        Change = "$GlobalValue = 1"
        Notes = 'Win11: makes 0.5 ms requests from any process (games, the holder task) apply system-wide, like before Win10 2004'
    })
}
$rows.Add([PSCustomObject]@{
    Id = 'holder-task'; Tweak = 'Hold finest timer resolution at logon'
    Current = $(if ($holderTask) { 'installed' } else { 'not installed' })
    Change = 'scheduled task (hidden, current user)'
    Notes = "Open-source stand-in for TimerResolution.exe / ISLC$(if ($IsWin11) { '; on Win11 only matters together with the system-wide tweak' })"
})
if ($bcdOk) {
    $rows.Add([PSCustomObject]@{
        Id = 'dynamic-tick'; Tweak = 'Disable dynamic tick'
        Current = $(if (Test-BcdOn $dynTick) { 'already disabled' } elseif ($null -ne $dynTick) { "set to '$dynTick'" } else { 'default (enabled)' })
        Change = 'bcdedit /set disabledynamictick yes'
        Notes = 'The most commonly beneficial bcdedit timer tweak; verify with -Measure before/after'
    })
    $rows.Add([PSCustomObject]@{
        Id = 'platform-tick'; Tweak = 'Force fixed platform tick'
        Current = $(if (Test-BcdOn $platTick) { 'already forced' } elseif ($null -ne $platTick) { "set to '$platTick'" } else { 'default' })
        Change = 'bcdedit /set useplatformtick yes'
        Notes = 'CONTESTED: helps some systems, causes mouse issues on others - measure, and undo if it feels worse'
    })
    if ($null -ne $platClock) {
        $rows.Add([PSCustomObject]@{
            Id = 'remove-platform-clock'; Tweak = 'Remove forced HPET clock'
            Current = "useplatformclock set ('$platClock')"
            Change = 'bcdedit /deletevalue useplatformclock'
            Notes = 'Forcing HPET is outdated advice that increases latency on modern systems'
        })
    }
}

$selected = $rows | Out-GridView -Title 'Select timer tweaks to apply (Ctrl-click for multiple, Cancel = no changes)' -PassThru
if (-not $selected) {
    Write-Host "No tweaks selected. No changes made." -ForegroundColor Yellow
    Wait-IfElevatedWindow
    return
}

# One definition per tweak id: backup kind, undo record, and apply step live
# together so a new tweak cannot desync them.
$tweakDefs = @{
    'global-reg' = @{
        Kind = 'reg'
        UndoEntry = { @{ Kind='reg'; Path=$KernelKey; Value=$GlobalValue; Previous=$globalReq } }
        Apply = { New-ItemProperty -Path $KernelKey -Name $GlobalValue -Value 1 -PropertyType DWord -Force | Out-Null }
    }
    'holder-task' = @{
        Kind = 'task'
        # Xml of a pre-existing task lets -Undo restore it instead of losing it
        # to Register-ScheduledTask -Force.
        UndoEntry = { @{ Kind='task'; Name=$TaskName; Xml=$(if ($holderTask) { Export-ScheduledTask -TaskName $TaskName } else { $null }) } }
        Apply = {
            $taskUser = if ($LogonUser) { $LogonUser } else { "$env:USERDOMAIN\$env:USERNAME" }
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
                -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Hold"
            $trigger = New-ScheduledTaskTrigger -AtLogOn -User $taskUser
            $principal = New-ScheduledTaskPrincipal -UserId $taskUser -LogonType Interactive
            # No time limit: the holder must live for the whole session, or the
            # resolution request dies with it.
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
            Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
                -Principal $principal -Settings $settings -Force | Out-Null
            Start-ScheduledTask -TaskName $TaskName
        }
    }
    'dynamic-tick' = @{
        Kind = 'bcd'
        UndoEntry = { @{ Kind='bcd'; Name='disabledynamictick'; Previous=(ConvertTo-BcdBool $dynTick) } }
        Apply = { Invoke-Bcdedit /set disabledynamictick yes | Out-Null }
    }
    'platform-tick' = @{
        Kind = 'bcd'
        UndoEntry = { @{ Kind='bcd'; Name='useplatformtick'; Previous=(ConvertTo-BcdBool $platTick) } }
        Apply = { Invoke-Bcdedit /set useplatformtick yes | Out-Null }
    }
    'remove-platform-clock' = @{
        Kind = 'bcd'
        UndoEntry = { @{ Kind='bcd'; Name='useplatformclock'; Previous=(ConvertTo-BcdBool $platClock) } }
        Apply = { Invoke-Bcdedit /deletevalue useplatformclock | Out-Null }
    }
}

# ---- Backups BEFORE changing anything ----
# The user may have sat in the grid for a while - re-read state so the undo
# file records the actual pre-change values, not the ones from script start.
Read-TimerTweakState
# The suffix loop keeps two runs within the same second from clobbering the
# previous run's undo/backup files; the json and BCD backup share one stamp.
$base = Get-Date -Format 'yyyyMMdd_HHmmss'
$stamp = $base
$n = 1
while ((Test-Path (Join-Path $PSScriptRoot "timer_undo_$stamp.json")) -or
       (Test-Path (Join-Path $PSScriptRoot "bcd_backup_$stamp"))) {
    $stamp = '{0}_{1}' -f $base, $n++
}
$undoState = New-Object System.Collections.Generic.List[object]
if ($selected | Where-Object { $tweakDefs[$_.Id].Kind -eq 'bcd' }) {
    # Full BCD store export: last-resort rollback (bcdedit /import <file>) even
    # if the undo JSON is lost.
    $bcdBackup = Join-Path $PSScriptRoot "bcd_backup_$stamp"
    Invoke-Bcdedit /export $bcdBackup | Out-Null
    Write-Host "BCD store backed up: $bcdBackup" -ForegroundColor Cyan
}

foreach ($t in $selected) { $undoState.Add((& $tweakDefs[$t.Id].UndoEntry)) }
$undoFile = Join-Path $PSScriptRoot "timer_undo_$stamp.json"
ConvertTo-Json $undoState -Depth 4 | Set-Content -Path $undoFile -Encoding UTF8
Write-Host "Undo file saved: $undoFile (revert with -Undo)" -ForegroundColor Cyan
Write-Host ""

# ---- Apply ----
$needReboot = $false
foreach ($t in $selected) {
    $def = $tweakDefs[$t.Id]
    try {
        & $def.Apply
        if ($def.Kind -ne 'task') { $needReboot = $true }
        Write-Host ("  [OK ] {0}" -f $t.Tweak) -ForegroundColor Green
    } catch {
        Write-Host ("  [ERR] {0}: {1}" -f $t.Tweak, $_) -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "Done. Revert any time with: .\timer-resolution-utility.ps1 -Undo" -ForegroundColor Green
if ($needReboot) { Write-Host "REBOOT REQUIRED for bcdedit/registry changes to take effect." -ForegroundColor Green }
Wait-IfElevatedWindow
