# Status

Last updated 2026-10-28. Update this file whenever a run, a branch or a finding changes what the
next step is. Newest state first; keep the history short.

## Where the game stops

The game boots, shows the loading spinner and starts loading the world (`tsu_2_-10_-14.xpps`
and other terrain tiles). With all four fix branches (latest run, 2026-10-28) it gets further into the
world load and stops at an assertion in the renderer:

    liverpool_to_vk.cpp:788 SurfaceFormat: Assertion Failed!
    Unknown data_format=39 and num_format=11

(while loading `tsu_0_-8_-15.xpps`). Format 39 is BC5 and number format 11 is `UbnormNz`, which
shadPS4's `RemapNumberFormat` does not turn into `Unorm` as it does `Ubnorm`. Fix on
`bc5-ubnorm-nz`, **not built or run yet**. Nothing playable is drawn yet.

Test machine: Windows, NVIDIA GPU (32-lane subgroups), the author's patch 2.18 dump, repo at
`C:\Users\cuboi\Documents\GOT-port\got-pc-port`.

## Open branches

| Branch | Fix | State |
| --- | --- | --- |
| `bc5-ubnorm-nz` (from `main`) | `UbnormNz` remapped to `Unorm` with the `UnormToUbnorm` conversion, like `Ubnorm`, in a shim copy of `video_core/amdgpu/pixel_format.h` (`gpu/shim` shadows shadPS4 headers) | Pushed, **not built or run yet** |

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

Build `bc5-ubnorm-nz` (`python pc-port/scripts/build_gpu.py --jobs 12`; the conversion is part of
each shader's specialization key, so no `ShaderBinaryVersion` bump and no full recompile) and run:

    .\pc-port\scripts\run_game.ps1 -HangReport 40

and send the end of `run.log`. A crash in a missing shadPS4 case is the likely next stop: each
fix so far has moved the game further into the world load.
If the black screen comes back, the deadlock is intermittent: read the node dump
(`-Dump "+0x3bb64e0:0x20"`) and `GNM_IRQ_MERGED` in an `-IrqLog` run.

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
