MegaX - Sharp X68000 for MEGA65
===============================

A port of the [MiSTer Sharp X68000 core](https://github.com/MiSTer-devel/X68000_MiSTer)
(Puu-san's X68000 core) to the [MEGA65](https://mega65.org), built on the
MiSTer2MEGA65 framework as modified by
[Megamiga](https://github.com/johansmolinski/Megamiga).

**Version 0.1, the first release.** MEGA65 R6 only (an R3 port is planned,
`doc/plan.md`). See `doc/history.md` for the details of every step.

Status (0.1, 2026-11-03)
------------------------

Tested on the hardware:

* Human68k 3.02 boots from a DIM floppy image, a SASI hard disk image and
  SxSI hard disk images; games run (TwinBee, Dracula, Super Street
  Fighter II among others).
* Floppies: XDF/DIM/HDM images in two drives.
* Hard disks: one SASI image (`.HDF`) and up to four SxSI images (`.HDS`,
  tested up to 2 GB each; a 2 GB image mounts in about 2 s). The X68000 is
  held in reset until every remembered image is mounted, and is reset when
  the menu closes after a hard disk image was mounted or ejected (its drivers
  look for the drives only at boot).
* The mounted images and the menu settings are remembered across power-off
  (`/megax/megaxcfg`, created by the core on the first start).
* The keyboard in MiSTer's layout (the core's help page lists the keys).
* An Amiga mouse in port 1, an Atari-style joystick in port 2 (or two
  joysticks: menu "Mouse in port 1" off). The second buttons (right mouse
  button, joystick button B) need an active adapter on pin 9, a passive
  second button is not seen.
* HDMI (720p 60 or 50 Hz) and VGA; the X68000's four video oscillators: the
  15, 24 and 31 kHz modes, 640x480 and 1024x848 interlaced.
* Sound: the YM2151 (OPM) and the ADPCM.
* The 68000 at 10 or 20 MHz (menu).

Built, but not yet tested on the hardware: D88 images (with the changes
saved back on request), loading and saving the SRAM image.

Not in 0.1: MIDI, the "Visible Memory" option (the core has 12 MB), a
keyboard fallback for the second fire buttons. Known issue: early builds
sometimes started in the ROM debugger instead of booting (not seen lately).

Getting started
---------------

1. Install the core: copy `MegaX-0.1-R6.cor` to the SD card and flash it into
   a core slot (hold No Scroll while switching the MEGA65 on), or load
   `MegaX-0.1-R6.bit` through JTAG.
2. Make a folder `/megax` on the SD card and put MiSTer's `boot.rom` in it
   (1 MB: Sharp's IPL and CGROM, not part of MegaX), together with your disk
   images.
3. Start the core. The menu (HELP key) mounts the images; SPACE on a disk
   line ejects it. The settings file `/megax/megaxcfg` is created on the
   first start and remembers the images and the settings.

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
