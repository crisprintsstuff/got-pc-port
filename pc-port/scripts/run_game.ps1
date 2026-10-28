# Runs the game from the repo root with the settings the port needs:
#   .\pc-port\scripts\run_game.ps1 [-HangReport 40] [-Dump "+0x287f950:0x700"] [-DumpReg "main:r13:0x200"] [-TraceMspace] [-IrqLog] [-Profile]
# The game folder comes from pc-port\out\game_dir.txt. Output goes to run.log in the repo root.
# Every run writes frames.csv (per-frame CPU and GPU counters) to the repo root; -Profile adds GPU
# timestamps. Summarize the last 30 s with: python pc-port/scripts/analyze_performance.py frames.csv
param([int]$HangReport = 0, [string]$Dump = "", [string]$DumpReg = "", [switch]$TraceMspace, [switch]$IrqLog, [switch]$Profile)
$root = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$out = Join-Path $root "pc-port\out"
$env:ISS_GAME_DIR = (Get-Content (Join-Path $out "game_dir.txt") -TotalCount 1).Trim()
$env:ISS_GPU = "1"
# TLS reads patched at their first fault instead of faulting every time (upstream default).
$env:ISS_TLS_PATCH = "1"
# Unprotect the clean pages around a write fault with it (as the launcher does): fewer write
# faults; 7.2 -> 11.7 FPS in the opening cutscene (2026-10-28). An existing value is kept.
if (-not $env:ISS_FAULT_WINDOW_KB) { $env:ISS_FAULT_WINDOW_KB = "64" }
# Unified memory on the 1.39 GB heap the game maps at 0x1500000000 (per-frame data): the GPU uses
# the guest's bytes in place, with no write tracking or readbacks (gpu/unified_memory.h). The
# opening cutscene went from 11.7 to 30 FPS (the game's cap). Existing values are kept.
if (-not $env:ISS_UNIFIED_MEMORY) { $env:ISS_UNIFIED_MEMORY = "1" }
if (-not $env:ISS_UNIFIED_RANGE) { $env:ISS_UNIFIED_RANGE = "0x1500000000:0x56e00000" }
$env:ISS_HANG_REPORT = if ($HangReport -gt 0) { "$HangReport" } else { "" }
$env:ISS_HANG_DUMP = $Dump
$env:ISS_HANG_DUMP_REG = $DumpReg
$env:ISS_TRACE_MSPACE = if ($TraceMspace) { "1" } else { "" }
$env:ISS_IRQ_LOG = if ($IrqLog) { "1" } else { "" }
$env:SHADPS4_FRAME_CSV = Join-Path $root "frames.csv"
# -Profile: GPU timestamps; ISS_GPU_PROFILE=2 set beforehand also times each compute shader
# ("Perf GPU compute shader" lines in run.log every 5 s).
$env:ISS_GPU_PROFILE = if ($Profile) { if ($env:ISS_GPU_PROFILE -eq "2") { "2" } else { "1" } } else { "" }
Get-Process iss-probe -ErrorAction SilentlyContinue | Stop-Process
if ($HangReport -gt 0) { Remove-Item (Join-Path $out "hang-report.txt") -ErrorAction SilentlyContinue }
Write-Host "Game folder: $env:ISS_GAME_DIR"
& (Join-Path $out "iss-probe.exe") (Join-Path $out "boot-linked.bin") --entry *> (Join-Path $root "run.log")
Write-Host "Exited with code $LASTEXITCODE; log in run.log"
