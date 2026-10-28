# Status

Last updated 2026-10-28. Update this file whenever a run, a branch or a finding changes what the
next step is. Newest state first; keep the history short.

## Where the game stops

The game boots, presents frames and loads its title data (`ghost_title.xpps`, `game.sprig.xpps`).
It then usually stops on a black screen. One run got past that to the loading spinner, then hit a
GPU hang. Nothing playable is drawn yet.

Test machine: Windows, NVIDIA GPU (32-lane subgroups), the author's patch 2.18 dump, repo at
`C:\Users\cuboi\Documents\GOT-port\got-pc-port`.

## Open branches, in order of the fix stack

Each branch contains the one before it. Test the top one.

| Branch | Fix | State |
| --- | --- | --- |
| `asc-irq-coalesce` | Black-screen deadlock: merge a delayed compute interrupt into one already pending for the same equeue event (`gpu/overrides/gnmdriver.cpp`, `IrqDelayer::Push`) | Pushed, **not built or run yet** |
| `wave32-readlane` | GPU hang on NVIDIA: `v_readlane` of lanes 32-63 outside compute shaders reads the same lane within the host subgroup (`gpu/overrides/recompiler.cpp`, `ClampReadLanesToSubgroup`); `ShaderBinaryVersion` 9 | Pushed, built; **not yet exercised** (no run has reached the shader since) |

Merged: #1 launcher text and `.pkg` message, #2 launcher CI, #3 launcher warnings, #4 CI action
versions and fonts, #5 GPU protection across neighbouring mappings (fixed the
"GPU protection failed" crash).

`shader-dump` holds one dumped SPIR-V file from 2026-10-20 and is not part of this work.

## Next step

Build `asc-irq-coalesce` (`python pc-port/scripts/build_gpu.py --jobs 12`), then run 2-3 times,
since the deadlock was intermittent:

    .\pc-port\scripts\run_game.ps1 -HangReport 40 -IrqLog -Dump "+0x3bb64e0:0x20"

- **Past the black screen:** the deadlock is fixed. Watch the loading spinner: that is where the
  readlane fix gets tested (draw `ps 361a48f5`). Open PRs for both branches.
- **Still black:** read the node dump (`+0x3bb64e0`, see below) and the `GNM_IRQ_MERGED` lines
  in `run.log`.

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
only rewrites compute shaders. If the hang returns on the same draw, the next suspect is lanes
the GPU did not launch (inactive lanes read by the shuffles).

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
