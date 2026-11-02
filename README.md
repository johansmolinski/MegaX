MegaX - Sharp X68000 for MEGA65
===============================

A port of the [MiSTer Sharp X68000 core](https://github.com/MiSTer-devel/X68000_MiSTer)
(Puu-san's X68000 core) to the [MEGA65](https://mega65.org), built on the
MiSTer2MEGA65 framework as modified by
[Megamiga](https://github.com/johansmolinski/Megamiga).

**Work in progress, no release yet.** MEGA65 R6 only. See `doc/plan.md` for
the plan and `doc/history.md` for the details.

Status (2026-11-02)
-------------------

Tested on the hardware:

* Sharp's IPL boots a floppy image from the SD card; the main RAM passes a
  memory test.
* HDMI and VGA output; the X68000's four video oscillators: the 15, 24 and
  31 kHz modes, 640x480 and 1024x848 interlaced all show.

Built, so far tested only in simulation or not yet at all:

* The keyboard in MiSTer's layout (the core's help page lists the keys).
* D88 floppies with write-back, SASI (.HDF) and SxSI (.HDS) hard disk
  images, the SRAM image; the mounted images are remembered across
  power-off.

The hardware tests used small test boot sectors of our own; Human68k has not
been tried yet.

Not done yet: mouse, joysticks, turbo, the OPM choice, MIDI, menu polish and
release packaging. Known issues: some first loads end in the ROM debugger
instead of the boot; the scaler shows noise for ~2 s at power-up.

Getting started
---------------

Put MiSTer's `boot.rom` (1 MB: Sharp's IPL and CGROM, not part of MegaX) in
`/megax` on the SD card, together with the disk images. The core loads it at
start-up; the menu (HELP key) mounts the images.

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
