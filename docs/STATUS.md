# Status

Last updated 2026-10-28. Update this file whenever a run, a branch or a finding changes what the
next step is. Newest state first; keep the history short.

## Where the game stops

**Title screen reached** (2026-10-28, `skip-cs-diagnostic` with `ISS_SKIP_CS=b5500bd4`): the mask
title screen renders at ~13 FPS, no `DEVICE LOST`. So `b5500bd4` is confirmed as the GPU hang.
Its effect is missing while skipped. Second run: after the spinner, right after the first
`SKIP_CS` line and `Created native guest thread: GameState`, three threads (job workers, chain
`+0x8030bc +0x80306e +0x2a1e90 +0x2a162d`) fault at the same instruction, `+0xb64121`
(access violation, exit code 21; `rcx=0x3f000000` (0.5f), `r14=0x111c9270`, `r15=0x13ce4b20`,
`r13=0`). From the code dump: a loop over the 0x30-byte entries of the table at `[obj+0xf348]`
(`obj = [0x13ce4b20] = 0x13ba7280`, the `ProxySetSync` object) copies shader parameters; for type
`0x1b` it writes a dword (here 0.5f) to `[entry+0x28]+0x168`, and `[entry+0x28]` (`r9`) is bad.
`PROBE_EVENT` did not print `r9`; `probe-regs` adds `r8`-`r11`, the accessed address, and lets
only the first faulting thread report (simultaneous faults interleaved their lines).
Third run (same build): no fault, but frozen on the brightness screen. The DualSense was found
(`PAD selected name=DualSense`); the main thread spins at `+0x709942` (rdtsc wait, chain
`+0x8b9dd8 +0x89c145 +0x893d12`, `rbx=0x110ce4c4`, `r14=0x14117168`), GPU threads idle. Likely
waiting for something the skipped shader would have written.
Fourth run (`probe-regs`): the fault is a NULL write (`r9=0`, `accessed=0x168`); `[entry+0x28]`
is 0. Right after the first `SKIP_CS` both times, so most likely data the skipped shader writes
(on the PS4 the GPU can write pointers the CPU reads). The freeze loop (`+0x709900`) runs jobs
and spins until `[+0x285d8b4] == [+0x285d8b0]` (a completion count).
**New lead on the hang itself:** `b5500bd4` reads memory through pointers computed at run time
(22 dynamic `ReadConst`, `s_load` from a runtime address). With DMA off (default,
`BB_DIRECT_MEMORY_ACCESS`), `EmitReadConst` turns each into a load of flatbuf dword 0: the shader
runs on garbage. Test: `BB_DIRECT_MEMORY_ACCESS=1`, `BB_PIPELINE_CACHE=0` (the cache does not
key on DMA), no skip.
Fifth run (DMA on, cache off, no skip): black screen, then the same NULL fault at `+0xb64121`
(same table `r11=0x1003f20840`, entry 0), before `b5500bd4` was even compiled. So the fault is
**not** caused by the skip: it is a race that hits at different times (sometimes after the
brightness screen). The table lies in the first direct mapping (`0x1000000000`, physical 0); no
two direct mappings alias. `probe-regs` adds `ISS_WATCH=<addr>,...`: hardware write watchpoints
that log every write (`WATCH` lines) to `[entry+0x28]` of entries 0, 18 and 34
(`0x1003f20868,0x1003f20bc8,0x1003f20ec8`).
Sixth run (`ISS_WATCH` on those three): no fault this time (the watchpoints change the timing);
it reached `b5500bd4` and hung the GPU as before (DMA was off). The writes: job functions clear
`[entry+0x28]` (`+0xb61ac4`, also `+0xb6191a`) and then set it (`+0xb63726`), always the same
thread for one clear/set pair, from the job runner (`+0x8030bc`). The values alternate between
two buffers (`0x150340d410` / `0x150260d410`): double-buffered per-frame data in the
`0x1500000000` direct mapping. Pairs for alternate buffers come from different threads a few
log lines apart, so the next frame's set-up job runs while this frame's jobs still write
through the pointer (`+0xb64121`): frames overlap. Fits the sync node at `0x13bb64e0` being
over-signalled (count below 0 in the black-screen hangs) and so completing early. Next run
watches the node too: `ISS_WATCH=13bb64e0,1003f20868`.
Seventh run (that watch, DMA on, cache off): the NULL fault again, before `b5500bd4`. The node
(8 bytes: low dword state, high dword count) cycles, all on the main thread: arm (`+0x8b3e97`
count +1, `+0x8b4004` state 1), one signal from the frame job (`+0x803a22`/`+0x803a90` fire,
called from `+0x8b4217` on main or `+0x8030bc` on a worker), reset (`+0x8038f7`, writes 0).
`ProxySetSync` (`+0xb60768`) also signals it, 22 times in two bursts during loading, and every
one is surplus. Landing between fire and reset it is harmless (the reset clears it); landing
between reset and the next arm it pre-pays the next cycle: the arm finds count 0 and sets state
2 at once (`0x0` then `0x2`), the frame is released without waiting and the next frame's
set-up job clears `[entry+0x28]` while this frame's jobs use it. Right before the fault:
reset, `ProxySetSync` signal (`0xffffffff00000000`), arm completes at once, `+0xb61ac4` clears
the entry, fault. Open question: what the PS4 delivers on event 6 that wakes `ProxySetSync`
(every pipe 6 interrupt makes it signal once). Next: watch its target `obj+0x1f30`
(`0x13ba91b0`) with `-IrqLog`.

Previous runs (`bitfield-insert64`, 2026-10-28): the GPU still hangs (`DEVICE LOST`, ~9 s) after
compute shader `b5500bd4` starts running, though its SPIR-V now validates. Its waterfall loop
terminates (it clears the lowest set bit of a 64-bit mask each pass) and its barriers sit in
loops with uniform trip counts. The new clue: every dispatch logs
`BindBuffers: Clamped size from 583 to 0 for stage 0xb5500bd4`, so a buffer is bound with 0 bytes
at an address with no mapping. Its descriptors are chosen at run time from a table inside the
loop (bindless: `Sharp dword N comes from Phi`), which the recompiler cannot resolve statically.
Reads from the 0-byte buffer return nothing, and loops counting on that data likely never end.
Real fix: bindless descriptor support for Phi-sourced sharps in the recompiler (large). **Now:**
`skip-cs-diagnostic` adds `ISS_SKIP_CS=<hash>` to drop that shader's dispatches, to confirm it
is the culprit and see what comes after. Nothing playable is drawn yet.

Test machine: Windows, NVIDIA GPU (32-lane subgroups), the author's patch 2.18 dump, repo at
`C:\Users\cuboi\Documents\GOT-port\got-pc-port`.

## Open branches

| Branch | Fix | State |
| --- | --- | --- |
| `probe-regs` (on `skip-cs-diagnostic`) | `PROBE_EVENT` prints `r8`-`r11` and the accessed address; only the first faulting thread reports; `ISS_WATCH` write watchpoints (`src/probe.c`) | Register part built and run; `ISS_WATCH` pushed, not built yet |
| `skip-cs-diagnostic` (on `bitfield-insert64`) | Diagnostic `ISS_SKIP_CS=<hex hash>[,...]`: drops compute dispatches of those shaders (both dispatch paths in `gpu/overrides/vk_rasterizer.cpp`), logs `SKIP_CS <hash>` once | Built and run: **confirmed**, title screen reached with `b5500bd4` skipped |
| `bitfield-insert64` (on `sharp-source-readfirstlane`) | Invalid 64-bit `OpBitFieldInsert` in `b5500bd4`: `BitFieldInsert64` rebuilt from 64-bit shifts, AND and OR (`gpu/overrides/recompiler.cpp`, `LowerBitFieldInsert64`); `ShaderBinaryVersion` 11 | Built and run: SPIR-V validates now, but the GPU still hangs (see above) |
| `sharp-source-readfirstlane` (on `bc5-ubnorm-nz`) | `IsSharpSource` assertion in `ResourceDiscoverPass`: T#/S# dwords read through `ReadFirstLane` are taken from its source, as V# dwords already were; any other unknown source is logged (`Sharp dword N comes from <opcode>`) and skipped instead of aborting. New override `gpu/overrides/resource_discover_pass.cpp` | Built and run: no abort, but the sources are Phi (not `ReadFirstLane`); the shader then likely hung the GPU |
| `bc5-ubnorm-nz` (from `main`, PR #13) | `SurfaceFormat` assertion (data_format=39 BC5, num_format=11 `UbnormNz`): `UbnormNz` remapped to `Unorm` with the `UnormToUbnorm` conversion, like `Ubnorm`, in a shim copy of `video_core/amdgpu/pixel_format.h` (`gpu/shim` shadows shadPS4 headers) | Built and run: **fixed** (world tiles load) |

Merged 2026-10-28 (#8-#11, in this order of the stack):

| Branch | Fix | State |
| --- | --- | --- |
| `release-mem-irq-only` | Abort while loading the world (`pm4_cmds.h:1075` UNREACHABLE): compute RELEASE_MEM with DATA_SEL 0 (interrupt only, no write) raises the interrupt (`gpu/overrides/liverpool.cpp`, both RELEASE_MEM paths) | Built and run: **fixed** (next stop is the surface format) |
| `wave32-inactive-lanes` | GPU hang on `ps 361a48f5`, second cause: shuffles and lane reads of inactive lanes outside compute shaders fall back to the lane's own value / the first active lane's (`GuardLaneReadsToActiveLanes`); `ShaderBinaryVersion` 10 | Built and run: **fixed** (no `DEVICE LOST`; the SPIR-V shows both guards and validates) |
| `asc-irq-coalesce` | Black-screen deadlock: merge a delayed compute interrupt into one already pending for the same equeue event (`gpu/overrides/gnmdriver.cpp`, `IrqDelayer::Push`) | Built and run: **fixed** (spinner reached, main thread no longer stuck) |
| `wave32-readlane` | GPU hang on NVIDIA, first cause: `v_readlane` of lanes 32-63 outside compute shaders reads the same lane within the host subgroup (`gpu/overrides/recompiler.cpp`, `ClampReadLanesToSubgroup`); `ShaderBinaryVersion` 9 | Built and run: needed but **not enough**, same draw still hangs |

Merged: #1 launcher text and `.pkg` message, #2 launcher CI, #3 launcher warnings, #4 CI action
versions and fonts, #5 GPU protection across neighbouring mappings (fixed the
"GPU protection failed" crash).

`shader-dump` holds one dumped SPIR-V file from 2026-10-20 and is not part of this work.

## Next step

1. Run without the skip, with `BB_DIRECT_MEMORY_ACCESS=1` and `BB_PIPELINE_CACHE=0`. If the
   GPU no longer hangs, make DMA the default for this game and bump `ShaderBinaryVersion`.
2. If it still hangs, the real fix for `b5500bd4`: resolve Phi-sourced sharps (bindless T#/V# from a descriptor table) in
  `ResourceDiscoverPass` / `FlattenExtendedUserdataPass` / `ResourcePatchingPass`, e.g. by
  binding the descriptor table as a buffer and building the descriptor in the shader.

## Findings

### Black screen: frame job never released (intermittent)

Addresses are image offsets in the patch 2.18 eboot (`+0x...` in hang reports).

- **Main thread** spins at `+0x8035d2` (chain `+0x8b9dd8 +0x89c145 +0x893d12`). It is a job-group
  wait (`0x803570`-`0x8035eb`): it runs a job itself when it can take one, otherwise it spins
  about 1 µs on `rdtsc`, and it leaves when `[r13+4]` (jobs remaining, `r13 = 0x13bb6590`)
  reaches 0. In the hangs it stays at 1. All `JobWorker` threads are idle.
- **Sync node** at `0x13bb64e0`: `+0` state (0 reset, 1 armed, 2 done), `+4` count, `+0x10`
  mutex, `+0x20` callback, `+0x30/+0x38` children. In the hangs: state 1, count -2 to -5.
  In the run that reached the spinner: 0/0.
  - `0x803a00` **signal**: `lock dec [node+4]`; it fires (state 2, callback, children) only when
    the count lands exactly on 0 with state 1. Past 0 it can never fire.
  - `0x803870` **reset**: clears state and count (`movq $0,(node)`) and the child list.
  - The arm site is not found yet.
- **`ProxySetSync`** thread, object `0x13ba7280` (node = object + `0xf260`), loop at
  `0xb60730`-`0xb6081c`:

      again: signal(node)
             sceKernelWaitEqueue(eq = [obj+0xf420])          ; pipe 6 interrupts (event id 0x6)
      check: if obj[0x1f30] (=3) <= table[obj[0x1f34] (=0x17)] goto again   ; table ptr at +0x16d3208
             spin 20 µs; goto check

  It signals exactly once per wakeup, and `obj[0x1f30]` is never advanced in the loop.
- **Interrupts:** every pipe 6 RELEASE_MEM uses `int_sel=3` (undocumented; shadPS4 raises an
  interrupt for it, as for 2), about 10 in a burst to slots 0x110 apart. `IrqDelayer`
  (default `ISS_ASC_IRQ_DELAY_US=1000`) delivered each one separately, so one burst woke
  `ProxySetSync` several times and over-signalled the node. With the delay at 5000 the count
  went further below zero (-5), which fits leaked interrupts more than late arming.
  The equeue itself already merges triggers (`EqueueEvent::Trigger` only sets `is_triggered`);
  the delayer is where they were kept apart. Hence `asc-irq-coalesce`.
- The comment above `IrqDelayer` (written before this analysis) explains why the delay exists:
  with immediate delivery the node was signalled before it was armed.

### GPU hang at the loading spinner (fix on `wave32-readlane`)

`GPU_BLACKBOX DEVICE LOST` on draw `vs 9911cadd ps 361a48f5`, 513x513, rendering into an image it
also samples. The pixel shader's only loop takes a wave minimum with `ShuffleXor` 16/8/4/2/1 and
`OpGroupNonUniformBroadcast` of lanes 31 and 63, and exits when the minimum reaches 255. Lane 63
does not exist in a 32-lane subgroup, so the loop never ended. shadPS4's `LowerWave64BallotPass`
only rewrites compute shaders. With that fixed (lane 31), the same draw still hung after 40 s
(2026-10-28 run). Second cause: along the odd 513-pixel edge, partial quads and warps leave
source lanes inactive, and Vulkan leaves shuffles and broadcasts from them undefined; a stale
value below 255 keeps the minimum there. On the PS4 the game's code can mask those lanes off,
which shadPS4's translation cannot express. Fixed on `wave32-inactive-lanes` (confirmed: the run
went on to load the world).

### Crash "GPU protection failed" (fixed, #5)

Since the guest address arena, each mapping is its own `MapViewOfFile3` view and neighbouring
mappings are adjacent; `VirtualProtect` cannot cross views. `memory_gpu_protect` now protects
region by region.

## Reading hang reports

- Known bug (2026-10-28): after the GPU hung, two reports in a row stopped after 7 lines,
  while sampling `AK::LibAudioOut` inside `SDL3.dll`. The writer probably suspends a thread that
  holds a lock it then needs (heap or loader lock). Fix in `runtime_report_*` (`src/runtime.c`):
  avoid allocating or resolving modules while a thread is suspended.
- `-HangReport 40` rewrites `pc-port\out\hang-report.txt` every 40 s. Copy it before Ctrl+C, or
  the report can be cut off mid-write.
- `-Dump "+<image offset>:<bytes>,<address>:<bytes>,*<address>:<bytes>"` (`*` follows a pointer);
  `-DumpReg "<thread>:<reg>:<bytes>"`. Code dumps disassemble with
  `objdump -D -b binary -mi386:x86-64 --adjust-vma=<offset>`.
- `run.log` (repo root) is still being written while the game runs; take it after the game exits.
- `BB_DUMP_SHADERS=1` dumps shaders only when they compile. Cached ones are in
  `pc-port\out\user\gpu-14\CUSA11456\<hash>_0.spv`.
- After a `ShaderBinaryVersion` bump the first run recompiles everything (hundreds of compiles,
  black screen for minutes). Judge a fix on the second run.
