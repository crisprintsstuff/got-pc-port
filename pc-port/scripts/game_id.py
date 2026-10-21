# SPDX-License-Identifier: GPL-2.0-or-later
"""The one game build this port targets. Other builds are refused until reviewed."""
TITLE_ID = 'CUSA11456'
TITLE = 'Ghost of Tsushima'
# sha256 of the decrypted retail eboot.bin, patch 2.18.
EXPECTED_EBOOT = '4980b598c27f2782d02148152e28c5773159e4498fbd0743721d0392a791afbd'
# The game's own libc and the Fios2 it imports, linked when the dump has them; otherwise the
# runtime's libc (src/libc*.c) stands in. libSceNpToolkit2.prx is never linked: it needs ~250 more
# PSN imports, and the offline Toolkit2 stubs (src/offline.c) stand in for it.
BUNDLED_MODULES = ('libc.prx', 'libSceFios2.prx')


def bundled_modules(game):
    present = [name for name in BUNDLED_MODULES if (game / 'sce_module' / name).is_file()]
    if present and len(present) != len(BUNDLED_MODULES):
        raise ValueError('sce_module has only part of ' + ', '.join(BUNDLED_MODULES))
    return present
