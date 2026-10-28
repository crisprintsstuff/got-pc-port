# Status

Last updated 2026-10-28. Update this file whenever a run, a branch or a finding changes what the
next step is. Newest state first; keep the history short.

## Where the game stops

**Opening cutscene at 30 FPS.** On the test machine the game boots, shows its menus in English,
and plays the opening cutscene correctly at its 30 FPS cap (2026-10-28). **Right after the
cutscene** (first gameplay on the beach) only the sky, stars and a flat sea/ground plane are drawn,
no terrain detail, characters or objects, at about 1.3 FPS. Not analysed yet; one suspect is
`b5500bd4` (next step 2), if it is the GPU-driven culling that decides what gets drawn.

Test machine: Windows, NVIDIA RTX 3060 (32-lane subgroups), Ryzen 7, the author's patch 2.18
dump, repo at `C:\Users\cuboi\Documents\GOT-port\got-pc-port`.

How to run (both use the tested settings, see "Settings the game needs"):

- `pc-port\scripts\run_game.ps1 -HangReport 40` (or `Launch.cmd`): output in `run.log`,
  per-frame timings in `frames.csv` (`-Profile` adds GPU timestamps;
  `python pc-port/scripts/analyze_performance.py frames.csv`).
- The launcher: `python pc-port/scripts/build_launcher.py` builds
  `Ghost of Tsushima Launcher.exe` in the repo root; from a checkout it uses `pc-port\out`,
  the prepared image there and `game_dir.txt`. Logs in `user\logs\<time>\`.

## Settings the game needs

Defaults now (in the code or in `run_game.ps1` and the launcher's `kGameEnvironment`):

| Setting | Why |
| --- | --- |
| Compute RELEASE_MEM with `INT_SEL 3` raises no interrupt (`ISS_ASC_SEL3_IRQ=1` restores it) | The game's compute fences all use 3 (graphics EOPs use 0 or 2). Raising an interrupt woke `ProxySetSync` at every frame end; it signalled the frame countdown in frames where the main thread already had, the next frame was released early and cleared a pointer the current frame still used (exit code 21 at `+0xb64121`). |
| DMA on (`BB_DIRECT_MEMORY_ACCESS=0` turns it off), `ShaderBinaryVersion` 12 | Compute shader `b5500bd4` reads memory through pointers it computes (22 dynamic `ReadConst`). Without DMA each read became flatbuf dword 0 and the GPU hung (`DEVICE LOST`). DMA is not in the pipeline cache key: a cache made without it keeps the hang (hence the version bump). |
| `ISS_UNIFIED_MEMORY=1`, `ISS_UNIFIED_RANGE=0x1500000000:0x56e00000` | The 1.39 GB heap of per-frame data is shared with the GPU in place: no write tracking or readbacks. Opening cutscene 11.7 -> 30 FPS. |
| `ISS_FAULT_WINDOW_KB=64` | Fewer write faults: 7.2 -> 11.7 FPS before unified memory. |
| Interrupt merging (`ISS_ASC_IRQ_DELAY_US` 1000, `ISS_ASC_IRQ_MERGE_MAX_US` 8000) | A burst of compute interrupts wakes the waiter once, as on the PS4. |
| System language English (`ISS_LANGUAGE`, PS4 ids; the launcher's Language setting) | The default was 17 (Brazilian Portuguese) from the inFAMOUS port. |

Not used for this game: the inFAMOUS port's tuned launcher set (fast draw paths, native passes,
shader recipes, 240 Hz vblank, command processor pinned to CPU 14). None of it was tried here.

## Branches

Everything up to the 30 FPS cutscene is on `irq-burst-merge`, a stack on `main`:
`bc5-ubnorm-nz` (PR #13) -> `sharp-source-readfirstlane` -> `bitfield-insert64` ->
`skip-cs-diagnostic` -> `probe-regs` -> `irq-burst-merge`. One PR merges the whole stack.

| Change | Where |
| --- | --- |
| BC5 `UbnormNz` surface format (was an assertion) | `gpu/shim/video_core/amdgpu/pixel_format.h` |
| Sharp dwords through `ReadFirstLane`, unknown sources logged instead of asserting | `gpu/overrides/resource_discover_pass.cpp` |
| 64-bit `BitFieldInsert` as shifts and masks (invalid SPIR-V before) | `gpu/overrides/recompiler.cpp` |
| `ISS_SKIP_CS=<hash>[,...]` drops a compute shader's dispatches (diagnostic) | `gpu/overrides/vk_rasterizer.cpp` |
| `PROBE_EVENT` with `r8`-`r11` and the faulting address, one report per crash; `ISS_WATCH` hardware write watchpoints; hang-report dumps before the thread walk | `src/probe.c` |
| Interrupt burst merging; `INT_SEL 3` without interrupt | `gpu/overrides/gnmdriver.cpp`, `gpu/overrides/liverpool.cpp` |
| DMA on by default | `gpu/shim/core/emulator_settings.h`, `vk_pipeline_serialization.cpp` |
| Real unmap (texture streaming maps and unmaps 64 KiB blocks; a fixed remap failed, then exit 21) | `src/memory.c`, `gpu/bridge.cpp` (`iss_gpu_unmap`), test in `tests/runtime_test.c` |
| English by default | `src/services.c` |
| `run_game.ps1`: `frames.csv`, `-Profile`, tested settings; launcher: tested settings, works from a checkout | `pc-port/scripts/run_game.ps1`, `pc-port/launcher/launcher.cpp` |

Merged before: #1-#5 (launcher, CI, GPU protection across mappings), #8-#11 (wave32 lane reads,
inactive lanes, interrupt coalescing, RELEASE_MEM with DATA_SEL 0). `shader-dump` holds one
dumped SPIR-V file from 2026-10-20 and is not part of this work.

## Next step

1. The first gameplay scene draws only sky and a flat plane, 7-12 FPS. Profile there (30 s):
   143 ms/frame; **readback stalls 240 ms** (6.6 reads, only 8 KB, `readback_async_wait` 220 ms:
   the game's CPU reads small GPU-written data and waits for the GPU each time); GPU work 88 ms
   (1341 draws, 688 dispatches); command processor 123 ms; `UNIFIED_STATS cp_read_wait_ms` 40-60
   per frame (the command processor waits on GPU writes in the unified heap once per frame).
   No mapping failures. Buffers clamped to 0 or less than asked: `b5500bd4` (17990 -> 0),
   `bdfc491f` (4801 -> 0), `616789a5`, `d4f5d0b6`. Theory for the flat world: terrain and
   objects stream in, and streaming starves at this frame time (or reads the clamped buffers).
   That run (`ISS_GPU_PROFILE=2`, `ISS_TRACE_READBACK=1`): compute is not the GPU cost
   (gameplay: `735cf693` ~150 ms/s, `b5500bd4` ~30 ms/s, `bdfc491f` ~12 ms/s, the rest small).
   The readbacks are the game reading small GPU-written results in a double-buffered pair of
   blocks in the `0x1100000000` heap, `0x11001a2000` / `0x11013a2000` (offsets 0x000, 0x214,
   0xdd0-0xf60), from `+0x59f7d4` and from TLS-patched copies of game code (`0x23e65b...`).
   Labels in that heap are written when the command processor reads them, not when the GPU is
   done (`UNIFIED_STATS fences_outside` ~230/frame), so the game reads a buffer it believes is
   finished and the port has to wait for the GPU. Unified memory on that heap writes those
   labels at GPU completion (deferred fences), but it covers one range only and the per-frame
   heap at `0x1500000000` needs it too. Next: try unified on `0x1100000000:0x14c00000` in
   gameplay (test C crashed in the cutscene from the unmap bug, now fixed); the real fix is
   unified memory over several ranges (`gpu/unified_memory.*`, `BufferCache::EnableUnified`,
   `ObtainUnified`, the DMA page table).
   Unified on `0x1100000000` alone in gameplay: about 10 FPS (no better). On `gameplay-diag`:
   `ISS_UNIFIED_RANGE` takes several ranges (`base:size,base:size`, up to 4); each heap is
   imported on its own (`BufferCache::UnifiedHeap`), labels in any of them are written at GPU
   completion, and `run_game.ps1` and the launcher now use both heaps. Range 0 stays the one
   the inFAMOUS native paths know (`IsPrimaryUnified`). Not built yet.
2. `b5500bd4` still binds one buffer it picks at run time with 0 bytes
   (`BindBuffers: Clamped size ... to 0 for stage 0xb5500bd4`; its V# comes from a Phi,
   `Sharp dword N comes from Phi`). DMA fixed the hang, but whatever that buffer feeds may be
   wrong. A full fix resolves Phi-sourced sharps (bindless) in `ResourceDiscoverPass` /
   `FlattenExtendedUserdataPass` / `ResourcePatchingPass`.
3. Known tooling bug: the hang report's thread walk often stops partway (in `runtime_report_*`,
   `src/runtime.c`); it probably suspends a thread that holds a lock it then needs.

## Findings worth keeping

Addresses are image offsets in the patch 2.18 eboot (`+0x...` in hang reports).

### Frame countdown and `ProxySetSync`

- **Countdown** at `0x13bb64e0` (8 bytes: low dword state 0 reset / 1 armed / 2 done, high
  dword count). Arm `+0x8b3e90`: `lock inc` count; state 1, or 2 at once if the count is
  already <= 0 (pre-paid). Signal `0x803a00`: `lock dec`, fires only when it lands on 0 with
  state 1. Reset `+0x8038f7`: writes 0.
- `+0x8b4202`: the main thread signals the countdown itself when `[+0x3bb6570]` is 0; otherwise
  `ProxySetSync` does.
- **`ProxySetSync`** (`+0xb60730`, object `0x13ba7280`): waits on equeue event 6 (pipe 6
  interrupts); then spins until `table[obj+0x1f34]` (label; table pointer at `+0x16d3208`,
  8-byte entries) >= `obj+0x1f30` (a target the frame jobs advance at `+0x57ecb9`); then signals
  once. Every surplus wakeup is a surplus signal; landing after a reset it pre-pays the next
  frame. That caused both the black-screen deadlock (count below 0) and the exit code 21 race.
- Job-group wait on the main thread: `0x803570`-`0x8035eb` (`[r13+4]` jobs remaining).

### Wave32 on NVIDIA

`v_readlane` of lanes 32-63 and shuffles from inactive lanes are undefined on 32-lane
subgroups; `ClampReadLanesToSubgroup` and `GuardLaneReadsToActiveLanes` fix them outside compute
shaders (the loading spinner's `ps 361a48f5` hung the GPU). shadPS4's `LowerWave64BallotPass`
only handles compute shaders.

### Memory

- Direct mappings: `0x1000000000` (384 MB), `0x1100000000` (332 MB: command rings, labels),
  `0x1200000000` (1.1 GB), `0x1500000000` (1.39 GB, per-frame data, double-buffered),
  `0x2000000000`, `0x3000000000`, and 64 KiB texture-streaming blocks in `0x14xxxxxxxx`.
- Each arena mapping is its own `MapViewOfFile3` view; `VirtualProtect` cannot cross views
  (`memory_gpu_protect` protects region by region, #5). Unmap returns the view to a placeholder
  merged with its free neighbours.

## Diagnostics

- `-HangReport 40` rewrites `pc-port\out\hang-report.txt` every 40 s; copy it before Ctrl+C.
- `-Dump "+<image offset>:<bytes>,<address>:<bytes>,*<address>:<bytes>"` (`*` follows a
  pointer); `-DumpReg "<thread>:<reg>:<bytes>"`. The dumps come first in the report. Code
  disassembles with `objdump -D -b binary -mi386:x86-64 --adjust-vma=<offset>`.
- `ISS_WATCH=<addr>[,...]` (up to 4, 8-byte aligned): a `WATCH` line in `run.log` for every
  write, with the writer and its call chain. It changes timing.
- `PROBE_EVENT` (exit code 21) carries the faulting address and registers; `-IrqLog` logs
  interrupts and compute fences (`GNM_IRQ`, `ASC_RELEASE_MEM`, `GFX_EOP`).
- `ISS_SKIP_CS=<hash>` drops a compute shader to test whether it causes a hang.
- `run.log` is written while the game runs; take it after the game exits. `gpu-crash.txt`
  is only rewritten by a new GPU crash: check its time.
- `BB_DUMP_SHADERS=1` dumps shaders when they compile; cached ones are in
  `pc-port\out\user\gpu-14\CUSA11456\<hash>_0.spv`. After a `ShaderBinaryVersion` bump the
  first run recompiles everything (minutes of black screen); judge on the second run.
