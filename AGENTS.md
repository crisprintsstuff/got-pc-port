# Agents

Instructions for any coding agent (or person) working in this repository. Read
[`docs/STATUS.md`](docs/STATUS.md) first: it says where the game stops, which branches are open
and what to do next. Update it before you stop.

## The project

A native Windows runtime for the PS4 Ghost of Tsushima (CUSA11456, patch 2.18 eboot only). The
game's own x86-64 code runs on the host CPU, `pc-port/src` replaces the PS4 system libraries, and
`pc-port/gpu` builds `iss-gpu.dll`, a Vulkan renderer from shadPS4-perf. Forked from the
inFAMOUS Second Son port; `ISS_*` names, many scripts and `pc-port/ARCHITECTURE.md` (Portuguese)
come from it.

- **No game files in the repo.** No eboot, modules, `.pkg`, keys, dumped shaders or assets,
  and none in commits. The user supplies a decrypted dump of their own copy. Retail `.pkg` files
  cannot be used (they stay encrypted). Do not add decryption.
- Hang reports quote small dumps of the game's code and memory from the user's own runs. They
  are for analysis only; don't commit them.

## Layout

- `pc-port/src`: runtime (loader, libc, kernel, memory, threads, sync, offline PSN). C, Win32.
- `pc-port/gpu`: `bridge.cpp` (shadPS4 glue), `overrides/` (port versions of shadPS4 files,
  mapped in `scripts/build_gpu.py`), `shim/`.
- `pc-port/launcher`: native launcher (`launcher.cpp`, `prepare_game.cpp`).
- `pc-port/scripts`: `prepare.py`, `link_modules.py`, `build.py` (runtime + its tests),
  `build_gpu.py` (renderer), `build_launcher.py`, `run_game.ps1`.
- `pc-port/tests`: C/C++ tests that `build.py` runs; `libc_portable_test.c` and the Python
  tests also run on Linux.
- shadPS4 sources: `research/shadPS4-perf`, branch `port-base` of
  `crisprintsstuff/shadPS4-perf` (private), plus `pc-port/third_party/shadPS4-perf-local.patch`.

## Building and running

Everything but the Python tools needs Windows (clang-cl in `tools/llvm`, Visual Studio, CMake).
A Linux or cloud agent cannot build the runtime or the renderer: say so and ask the user to
build. The launcher builds in GitHub Actions (`.github/workflows/launcher.yml`).

    pc-port\scripts\build_deps.cmd             (once)
    python pc-port/scripts/build.py            iss-probe.exe, runs the runtime tests
    python pc-port/scripts/build_gpu.py --jobs 12
    .\pc-port\scripts\run_game.ps1 -HangReport 40 [-IrqLog] [-Dump ...] [-DumpReg ...]

The game folder is the first line of `pc-port\out\game_dir.txt`. Output goes to `run.log` in the
repo root. See `docs/STATUS.md` for reading hang reports.

## Conventions

- Branch per fix from `main`, or stacked on the branch it needs (say so in the PR). Never rewrite
  pushed history; never push to `main` directly. Open PRs when the user asks.
- Commit subject: imperative, names the area (`memory: ...`, `GPU DLL: ...`,
  `Shader recompiler: ...`). Body: what was wrong (with the evidence) and what changed.
- Comments in the code say why, with the evidence that forced the change (see `IrqDelayer` in
  `gpu/overrides/gnmdriver.cpp`). Match the surrounding style: dense C in `src/`, shadPS4 style
  in `gpu/overrides/`.
- A change to the shader recompiler's output bumps `ShaderBinaryVersion` in
  `gpu/overrides/vk_pipeline_serialization.cpp`, with a line in its comment.
- New diagnostics go behind an `ISS_*` environment variable and print one greppable tag
  (`GNM_IRQ`, `ASC_RELEASE_MEM`, ...).
- Add a test in `pc-port/tests` when the code can run there.
- Don't put model names in commits, comments or docs.
