MegaX - Sharp X68000 for MEGA65
===============================

A port of the [MiSTer Sharp X68000 core](https://github.com/MiSTer-devel/X68000_MiSTer)
(Puu-san's X68000 core) to the [MEGA65](https://mega65.org), built on the
MiSTer2MEGA65 framework as modified by
[Megamiga](https://github.com/johansmolinski/Megamiga).

**Work in progress - nothing runs yet.** See `doc/plan.md`.

Licence
-------

GNU General Public License version 3 (`LICENSE`). Puu-san allowed the
redistribution of the X68000 RTL under GPLv3 on 2026-10-29
([blog reply](https://fpga8801.seesaa.net/article/519747422.html)); fx68k
and jt51 are GPL-3+, MiSTer2MEGA65 is GPL-3. The Sharp ROMs (IPL, CGROM) are
not part of MegaX: the core loads `boot.rom` from the SD card.

Credits
-------

* The X68000 core is by **Puu-san** (プー), ported to the MiSTer and
  developed further by the MiSTer-devel contributors (Sorgelig, Wark,
  Jamie Blanks, albconde, odiaboeeu and others).
* The 68000 is [fx68k](https://github.com/ijor/fx68k) by Jorge Cwik; the
  YM2151 is [jt51](https://github.com/jotego/jt51) by Jose Tejada Gomez or
  [IKAOPM](https://github.com/ika-musume/IKAOPM) by ika-musume.
* [MiSTer2MEGA65](https://github.com/sy2002/MiSTer2MEGA65) by sy2002 and
  MJoergen, [QNICE-FPGA](https://github.com/sy2002/QNICE-FPGA) by sy2002.
