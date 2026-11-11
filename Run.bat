@echo off
REM Double-click launcher. Runs the PowerShell script next to this file with
REM ExecutionPolicy bypassed (so a downloaded script isn't blocked). The script
REM elevates itself to Administrator via UAC. %* forwards -Status / -Measure [-Samples N] / -Undo / -Reset.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0timer-resolution-utility.ps1" %*
pause
