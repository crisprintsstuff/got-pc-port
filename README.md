# Ghost of Tsushima PC port (CUSA11456)

A native Windows runtime for the PS4 version of Ghost of Tsushima, forked from
[Castlesea/infamous-second-son-pc-port](https://github.com/Castlesea/infamous-second-son-pc-port).
The game's own x86-64 code runs directly on the host CPU; a custom runtime replaces the PS4
system libraries, and graphics go through a Vulkan renderer derived from shadPS4.

**Status: not playable.** The executable parses and links offline (591 imports). libc and many
services are still missing from the runtime. Nothing has been built or run on Windows.

No game files, keys or copyrighted assets are part of this repository. You need a decrypted
dump of your own copy: the retail eboot.bin from patch 2.18 (sha256 `4980b598…91afbd`).
The game identity lives in `pc-port/scripts/game_id.py` and `pc-port/src/game.h`.

## Differences from the inFAMOUS port

- libc: like inFAMOUS, the game's own `sce_module/libc.prx` and `libSceFios2.prx` are linked
  when the dump has them. Without them the runtime's libc stands in for all 120 libc imports:
  `libc.c` (host CRT wrappers), `libc_format.c` + `libc_varargs.S` (printf/scanf over SysV
  argument lists) and `libc_mspace.c` (sceLibcMspace allocators inside the game's memory ranges).
  `tests/libc_portable_test.c` also runs on Linux. `libSceNpToolkit2.prx` is never linked.
- PSN, voice chat, sharing, streaming, crash dumps and sockets behave as on a console that is
  signed out with no network (`offline.c`); each logs `OFFLINE <api>` on its first call.
- The inFAMOUS native hooks (`pc-port/native/`, and the eboot patches in `gpu/bridge.cpp`) patch
  inFAMOUS code addresses and are not installed.
- The inFAMOUS shader packs, recipes and profiling scripts are kept for reference but do not apply.

## Roadmap

1. ~~Retarget identity checks, launcher and save paths~~
2. ~~libc replacement and offline stubs~~ (`pc-port/src/libc*.c`, `pc-port/src/offline.c`; untested on Windows)
3. Build on Windows; run to the first unimplemented call
4. The remaining imports: 55 of the eboot (Audio3d, Rtc, save data memory, trophy info, kernel event
   queues and memory) and 57 of libc.prx/Fios2 (kernel: flexible memory, rwlocks, atexit, time)
5. Renderer bring-up

## Preparing (any OS with Python 3)

    python pc-port/scripts/prepare.py --game "<game folder>" --out pc-port/out/got
    python pc-port/scripts/link_modules.py --game "<game folder>" --out pc-port/out/got

Build steps (Windows 11, clang-cl, CMake, a shadPS4-perf checkout) are unchanged from upstream;
see `docs/UPSTREAM-INFAMOUS-README.md`. Any Visual Studio 2022 or later with "Desktop development
with C++" provides the Windows SDK; the scripts find it with vswhere (or set `VCVARS64`).

## Renderer sources

The renderer builds from shadPS4-perf at `584374867d6a`, a commit no longer on any branch upstream.
A private mirror keeps it (branch `port-base`):

    git clone -b port-base https://github.com/crisprintsstuff/shadPS4-perf research/shadPS4-perf
    cd research/shadPS4-perf
    git submodule update --init --recursive
    git apply ../../pc-port/third_party/shadPS4-perf-local.patch

Then `pc-port\scripts\build_deps.cmd` configures and builds `build-opt` (shadPS4-perf with
clang-cl: the renderer's flags and libraries) and `build-sdl` (SDL3).

## License

GPL-2.0-or-later, as upstream. See `pc-port/LICENSE` and `pc-port/THIRD_PARTY.md`.
Ghost of Tsushima is a trademark of Sony Interactive Entertainment. This project is not
affiliated with Sony or Sucker Punch Productions.
