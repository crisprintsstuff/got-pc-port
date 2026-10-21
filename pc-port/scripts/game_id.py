# SPDX-License-Identifier: GPL-2.0-or-later
"""The one game build this port targets. Other builds are refused until reviewed."""
TITLE_ID = 'CUSA11456'
TITLE = 'Ghost of Tsushima'
# sha256 of the decrypted retail eboot.bin, patch 2.18.
EXPECTED_EBOOT = '4980b598c27f2782d02148152e28c5773159e4498fbd0743721d0392a791afbd'
# Ghost of Tsushima ships no sce_module/*.prx; libc comes from the runtime instead.
BUNDLED_MODULES = ()
