# MegaX - engineering history

One entry per increment: what, why, test numbers, build names.

## 2026-10-26 - Bootstrap

- Repository `~/git/my/x68000`, GitHub johansmolinski/MegaX (branch
  `main`); no licence file until the upstream licence ticket is answered
  (the user's decision). Name MegaX, SD folder `/megax`, TVRAM in block RAM
  if it fits (the user, 2026-10-26)..
- Fork johansmolinski/X68000_MiSTerMEGA65 of MiSTer-devel/X68000_MiSTer
  (created 2026-10-26 with the user's go-ahead); branches `MiSTer`, `develop`
  and `master` all at upstream `bb4368b` (#72, 2026-10-10). Submodule
  `CORE/X68000_MiSTerMEGA65` tracks `develop`; remote `upstream` in it.
- `M2M/` vendored from Megamiga `main` `4dac552`, `M2M/QNICE` at
  `fat32-fastseek` `78aeaac` (doc/m2m-provenance.md).
- Porting inventory (`doc/inventory.md`) and plan (`doc/plan.md`). Key
  findings: TVRAM is the only DDR3 user (512 KB); firm block RAM of the core
  without TVRAM about 120 tiles; the video uses a run-time retuned PLL with
  four oscillator frequencies (#72); Puu-san's RTL has no licence file.

## 2026-10-26 - Phase 1 started: the machine in simulation

- Fork `develop` (`e42bd77`, `6bf6bfd`): the 17 Quartus altsyncram wrappers as
  inferred RAMs under their own names (`rtl/mega65/x68k_rams.vhd`, init files
  converted by `rtl/mega65/init/convert.py`); `rtl/mega65/legalize.py` renames
  `context`, `vmode`, `VMODE` (VHDL-2008 / PSL keywords: Vivado's
  `check_syntax` rejects `vmode` too) and ramreg's `reg` port (crashes ghdl
  5.0.1's Verilog writer: several instances driving a port named after a
  Verilog keyword); four one-line fixes (cachecont `3downto`, seekcont `when
  others`, FDCs `usel` driven twice, FDCs `bitwidth` range); fx68k ROM paths.
- MegaX: `CORE/vhdl/x68_system.vhd` (X68K_top + clock enables, reset, loader
  handshake as X68000.sv), `CORE/vhdl/tvram_bram.vhd` (the text VRAM: a 64K x
  64 block RAM answering `tvram_ddr.sv`'s DDR3 requests, so that file stays
  upstream's), `CORE/sources.txt` (one file list for simulation and Vivado).
- `tb/sim` (doc/sim.md): ghdl --synth to Verilog + Verilator, SDRAM model with
  timing/refresh checks, simulation copy of SDRAMC (ghdl cannot carry the inout
  bus through the hierarchy), `fix_dups.py` (ghdl 5.0.1 name collisions; 5.1.1
  on Fedora has none), boot ROM preloaded into the SDRAM model.
- Heavy work runs on Fedora (the user): `tools/remote/rsim.sh`.
- Debugging notes: the first full ghdl run grew to 23 GB because an init file
  path did not resolve from that working directory and ghdl's synthesis does not
  stop at the failed assert (the loader now returns at once).
- First run (`ipl-b`, Fedora, 4 threads): SDRAM initialised (MRS CL2 full page
  at 2.7 us), the core asks for its first video clock (mode 0, 38.864 MHz),
  52 s wall per simulated ms. Findings to follow up: the controller issues a
  command right after power-up and waits only ~14.5 us (datasheet: 100 us) - the
  shell must hold it in reset long enough; bursts step from column 511 to 512
  (the MiSTer's chip has 512 columns).
- Later the same day, the IPL in simulation (runs `ipl-c` .. `ipl-k`):
  - **Single-threaded Verilator** is 100x faster on the shared Fedora host
    (0.56 vs 52 s per simulated ms); THREADS=1 is the default.
  - **SDRAM read timing:** the 68000's reset vectors came back one word off.
    SDRAMC takes the first read word three clocks after READ; a CL2 chip on the
    inverted clock only holds it until ~2.5 clocks, so the controller depends on
    the MiSTer board's delay. The model delays read data by one falling edge
    (`+sdram_rd_delay`). **For the MEGA65 shell:** the SDRAM clock phase must put
    the data there (or the read register must move) - check in phase 2.
  - **`plllock` resets the memory system** (`mem_rstn <= plllock` in X68K_top):
    tied to '1' in x68_system, the cache controller kept its power-up tags (all
    "block 0") and the first write to address 0 never got DTACK. x68_system now
    has a `locked` input (the MMCM's lock on the MEGA65).
  - **ghdl and registered 'Z':** SDRAMC's MDATA (`(others=>'Z')` default) came
    out of ghdl's synthesis as logic that kept the first word of a write burst;
    the simulation copy uses '0' (Vivado maps the original to an I/O tristate).
  - Result: the IPL runs: clears and tests memory, programs the CRTC at 182 ms
    (R20 = 0x315: 31 kHz, 512x512; the scan clock switches to 69.552 MHz), black
    512x512 frames at 55.5 Hz from 200 ms (text palette all 0 at that point, by
    the IPL), clears the text VRAM (~5.4 us per CLR.L through tvram_ddr's
    handshake), sends the TV-control codes (E8E003, pulse-width bit-banging).
    Black until at least 1.2 s; longer runs next.
  - 3 s run (`ipl-l`, 0.69 s wall per simulated ms): after the text VRAM clear
    (~430 ms) the IPL sets up MFP, SCC, SPC and the system port, the MFP timer
    interrupt runs at 100 Hz (counter `$9CC` from 5999 down), and the IPL boots
    "standard": FF0D3C waits 1 s, then IOCS `$43` per floppy unit, retrying while
    a drive answers status 4 and less than 30 s have passed (`$9CC` >= 3000).
    No palette or VRAM drawing until 3 s: the screen stays black. Next: give it a
    disk - a MiSTer-style sector service in the testbench (the same protocol the
    MEGA65 shell has to serve to X68K_top's mist_* ports) and a small boot sector
    of our own that sets the text palette and draws, so the whole path (FDC
    emulation, CPU, text VRAM, video) shows up in a frame without Sharp's IPL
    screen or any copyrighted disk.

## 2026-10-27 - Disks in simulation, a boot sector of our own

- `x68_system` carries MiSTer's hps_io sector interface (`img_*`, `sd_*`) and
  X68000.sv's mount glue (mount pulse stretching, eject, re-announce after
  reset, reset after a SASI mount, D88/XDF selection and `sd_ack` mapping; the
  1-bit `img_readonly` reaches only bit 0 of `mist_readonly`, as on MiSTer).
  The testbench serves it (`--fd0`, `--fd1`); the MEGA65 shell will serve the
  same ports from the SD card.
- Test boot disk (`tb/sim/bootdisk`): a 2HD XDF with our own boot sector (IOCS
  _CRTMOD 16, _B_PRINT, colour bars in the text VRAM). Run `disk-b` (3 s): the
  FDD status port reports the disk in unit 0 (E94005 = 0x80), the IPL reads
  blocks 0 and 1 at 1.775 s - then rejects the sector: its floppy boot (FF029C)
  reads 1024 bytes to $2000 with IOCS $46 and jumps there only if the first
  byte is $60 (`cmpi.b #$60,(a1)` at FF02BE). It went on to ROM boot (the
  address in SRAM ED000C, 0), executed the vector table and stopped in its
  exception handler with 「エラーが発生しました。リセットしてください。」 (in
  black: the text palette is still 0). The boot sector now starts with a BRA.
- Checkpoints (`--savable`; `--save <f> --save-at <ms>`, `--restore <f>`): the
  IPL needs 1.77 s of machine time (~33 min) before it reads a boot sector.
- rsim.sh: rsync into a base copy on the host (an update takes < 1 s instead of
  minutes), `setsid` as the background job (the old form kept the ssh session
  open and `stop` missed the process group).
- **First picture (run `disk-f`, 2026-10-27):** the IPL loads our boot sector
  at 1.775 s and jumps to it; IOCS `_CRTMOD 16` switches to 768x512 (the core
  switches the scan clock), `_B_PRINT` draws "MegaX - X68000 for MEGA65 - boot
  sector test" with the CGROM font, the colour bars land at line 400. Two
  things kept the screen black: `_CRTMOD` leaves the text palette all 0, and the
  IPL leaves the **contrast** (E8E001) at 0; the boot sector now sets both.
  The whole path works in simulation: SDRAM controller and model, cache, IPL,
  MFP timer interrupts, floppy controller + XDF emulator + sector interface,
  text VRAM in block RAM behind tvram_ddr.sv, palette, compositor, contrast,
  native-clock scanout.
- Checkpoints work (`--structs-packed` needed: Verilator's `--savable` cannot
  serialise fx68k's unpacked structs): `ckpt-1770.bin` (68 MB, just before the
  boot sector read); `rsim.sh from <run> <name>` reuses a run's build and
  checkpoints, so a boot sector change is tested in minutes, not 35.
  Frame 45 of run `disk-g` (2.59 s, contrast still rising):
  `doc/img/sim-first-picture.png`.

## 2026-10-27 - Phase 2: the MEGA65 shell

The shell after PC10-III's (same Megamiga M2M; its `MEGA65_Core` entity matches
our vendored framework port for port), in `CORE/vhdl`:

- `clk.vhd`: MMCM 1 (VCO 800 MHz) gives clk_ram 80, clk_sys 40 (= M2M's main
  clock) and the SDRAM chip's clock (80 MHz at 180 degrees, forwarded by an ODDR
  in `main.vhd`); MMCM 2 gives clk_scan = 100 / 5 x 58.25 / 16.75 = 69.552239 MHz
  (+3.6 ppm), the 31 kHz oscillator. Phase 2 has no oscillator switching:
  `main.vhd` answers the core's scan-clock request like `x68k_video_clock.sv`
  but grants `scan_ready` only for the 31 kHz modes (family 0); 15 kHz and the
  VGA-dot modes stay dark until phase 4. (The plan's fallback, mister_sync's
  fractional pixel enable, would have meant changing #72's CRTC.)
- `x68_boot.vhd`: QNICE device for `/megax/boot.rom` (mandatory auto-load ROM):
  every byte the Shell writes goes through an async FIFO (`qnice_wait_o` while
  full) to x68_system's loader port, one strobe per byte, waiting for the core's
  acknowledge. PREP_START (`m2m-rom.asm`) checks that exactly 1 MB arrived, ends
  the load and waits for the core to have taken the last byte. The Shell holds
  the core in reset while it auto-loads ROMs, but the X68000's memory controller
  has to run then (it writes the ROM into the SDRAM): `mega65.vhd` passes the M2M
  resets on only once the load has ended.
- `keyboard.vhd`: the MiSTer's PS/2 path is kept (KBCONV, MiSTer layout, no fork
  change): the MEGA65 matrix becomes PS/2 set-2 codes, and a PS/2 keyboard
  device after hps_io's `ps2_device` answers KBCONV's start-up dialogue (FF ->
  FA AA, F2 -> FA AB 83, ED/F3 + argument -> FA). Typematic repeat as on a PS/2
  keyboard (F3's rate/delay). The MEGA key is the Windows key, which KBCONV's
  MiSTer layout uses for HELP, OPT.1/2, XF1-5 and the kana keys; MEGA + 8/9/0 =
  F8-F10, RUN/STOP = BREAK (sent as the Pause key's bytes).
- `main.vhd`: x68_system, keyboard, SDRAM pins, video handoff (blanks widened to
  cover the syncs), audio. `locked` follows the MMCM lock by 205 us: SDRAMC
  starts its init sequence right away and the chip wants 100 us of clock first.
- `mega65.vhd`, `config.vhd` (15-line menu: HDMI 720p 60/50 Hz, 68000 at 20 MHz,
  help with the key map, reset), `globals.vhd` (OSM canvas 768 x 512, ascal
  buffer 2 MB), `m2m-rom.asm` (31373 of 32768 ROM words).
- `CORE.xdc`: X68000.sdc's exceptions in Vivado form (80 <-> 40 MHz paths over a
  whole clk_sys period, fx68k and DMA multicycle 2, the scan clock asynchronous)
  and SDRAM I/O constraints from the datasheet: commands sampled half a period
  after launch; read data captured two clk_ram clocks after the launching chip
  edge (CL2 window: tAC 6.0 ns after the second edge to tOH 2.5 ns after the
  third). Vivado checks what the simulation models with `sdram_rd_delay`.
- `CORE-R6.xpr` from Megamiga's by `tools/gen_xpr.py` (its M2M files plus
  `CORE/sources.txt` plus the shell); `build_all.sh`, `build_bitstream.tcl`
  (gates: clock periods, 128 RAMB36 of text VRAM, the SDRAM pin clock),
  `tools/remote/rbuild.sh` (fedora:~/megax-builds).
- Tests (ghdl, on Fedora), `tb/shell`: `check.sh` analyses and elaborates the
  whole design against UNISIM/XPM stand-ins in 8 s; `tb_keyboard` runs
  keyboard.vhd against the core's own KBCONV + PS2IF + layout ROMs: PASS (A, MEGA
  + 8 = F8, RUN/STOP = BREAK and an E0 key after it, cursor up, MEGA + H = HELP,
  Q held 900 ms = 5 repeats). Found on the way: a bare `E1 14` leaves KBCONV's E1
  flag set and the next E0 key is lost (hence the Pause key's trailing 77); KBCONV's
  `KBWAIT_CMD` has no reset (0 in the FPGA; the test uses a copy with that power-up
  value); PS2IF decrements a counter below its range once (wraps in hardware).
  `tb_boot`: x68_boot with x68_system's loader glue and a core acknowledging after
  3..40 clocks: PASS, 9000 bytes in order.
- Builds: `megax-a` and `megax-b` stop in synthesis right after RTL optimization
  phase 1 with Vivado's internal `basic_string::_M_construct null not valid`.
  Bisected with out-of-context syntheses (`tools/synth/ooc.tcl`, one Vivado run
  per variant on Fedora, ~1 min each): x68_system alone passes; any design that
  also uses XPM (`clk.vhd`'s reset synchronizer, `x68_boot.vhd`'s FIFO, even a
  single xpm_cdc_single in a dummy file) fails; the failing core blocks (memcont,
  diskemu, the XDF emulator, sprram, sprregs, grpal, gvram_ctrl) are exactly the
  ones with a fork RAM template `m65_tdp_ram` **without init file**, whose
  generic was `INIT : string := ""`. **Vivado 2022.2 crashes on an empty string
  generic once XPM is in the design.** Fork develop `06592ef`: the no-file value
  is "none". (The valueless Quartus `preserve` on the #72 synchronizers was the
  first suspect; they are ASYNC_REG now, `4ac6d27`, which is right for Xilinx
  anyway.) Out of context, x68_system takes 32.4k LUTs, 17.4k registers, 267
  block RAM tiles (208 RAMB36 + 118 RAMB18), 3 DSPs.

## 2026-10-27 - Floppy images from the SD card (phase 3 begins)

With no disk the X68000 shows nothing (the IPL leaves contrast and palette at 0 and
waits for a disk), so a floppy is what makes the hardware visibly testable.

- `x68_sd.vhd`: PC10-III's `pc_fdd_sd` engine (extent map -> SD block, single-block
  transfers through the SD host's engine port, retries, a toggle handshake between the
  QNICE and main clocks) generalised to MiSTer's eight hps_io slots with 32-bit LBAs and
  127 extents per slot (two RAMB36 of maps for all eight), and with MiSTer's interface on
  the core side: `img_mounted` per MODE write with the exact file size (D88 files are not
  whole sectors), `img_xdf`, `img_readonly`; a read streams 512 bytes with a
  `sd_buff_wr` every fourth clock between `sd_ack` rising and falling (the pacing of the
  testbench's server, which the core has run against since phase 1); a write collects
  the core's bytes (`sd_buff_din` two clocks after `sd_buff_addr`) and keeps `sd_ack` up
  until the block is on the card. The core's protocol has no error path (neither has
  hps_io): a failed or out-of-range read delivers zeros.
- Menu lines FDD0 and FDD1 (manual "ROM" loads into `C_DEV_X68_FDD0/1`); the firmware's
  PREP_LOAD_IMAGE hands the file over with PC10-III's FD_SETUP and tells the core D88 by
  the extension `.D88`, a sector image (XDF/DIM/HDM) otherwise, as MiSTer does by file
  type. Menu signature 2 (18 lines).
- The drive LED is the X68000's floppy motor (MiSTer's user LED).
- `tb/shell/tb_sd`: PASS.

## 2026-10-27 - First bitstream that meets timing: megax-f

- `megax-c`/`-d`: hold -11.2 ns on clk_ram -> fx68k: my translation of X68000.sdc mixed a
  `-end` setup multicycle (the "to the 68000" rule) with a `-start` hold one on an 80 -> 40 MHz
  path. Now every cell-based multicycle counts in destination clocks for setup and hold, and
  "into the 68000" applies only from main_clk (`b928263`).
- `megax-e`: setup met (WNS +0.004 ns, the SDRAM address pins, 3 ns of routing between
  register and pad), hold -0.556 ns on cacheext's `srclk` (it samples clk_sys as data):
  X68000.sdc's false path was missing (`3675ddf`, with IOB TRUE on the SDRAM pins).
- **`megax-f`: RESULT OK, WNS +0.157 ns, WHS +0.036 ns.** SDRAM: read capture setup +6.66 /
  hold +9.93 ns, command/address/data out setup +0.29 / hold +4.78 ns against the
  datasheet (tAC 6.0, tOH 2.5, tIS 1.5, tIH 0.8 ns) and 0.1-0.5 ns traces. The DQ pins stay
  out of the IOBs (SDRAMC drives all 16 output enables from one register). 54.1k LUTs
  (40 %), 313 / 365 block RAM tiles. `tools/make_cor.sh` -> `MegaX-0.1-f-R6.cor`. Not yet
  tried on the hardware.

## 2026-10-27 - Phase 3: hard disks, SRAM, eject, D88 write-back

- The menu (signature 3) has image lines for MiSTer's slots: FDD0, FDD1, SASI (.HDF),
  SxSI 1 and 2 (.HDS), SRAM (16 KB), one QNICE device per slot (0x0101 + slot), all
  through x68_sd.vhd. The firmware checks the size per kind and refuses an image with
  more than 127 extents (the map size; hard disk images should be contiguous).
- SPACE on a mounted image line ejects it (PC10-III's HANDLE_CORE_IO): the slot off, which
  x68_sd.vhd turns into hps_io's unmount (img_mounted with size 0).
- A "Disks and SRAM" submenu with MiSTer's momentary options: Save FDD0/FDD1 changes (D88,
  `fd_sync`), Load/Save SRAM (`pSramld/pSramst`), Inject SxSI driver (`sxsi_inject`) -
  held for ~10 ms by the firmware, the core samples them as levels like MiSTer's "R"
  options - and "SxSI driver at power-on" (one pulse once the boot ROM is in, MiSTer's
  sxsi_boot_pulse).
- Firmware: 32057 of 32768 ROM words; persistence of the mounted images (as PC10-III's
  hard disk) will need code banks.
- The Fedora host's /home was full (727 of 730 GB, nearly all outside MegaX): a Verilator
  build failed with "No space left on device". Obsolete runs and builds deleted (2.2 GB
  free); `megax-f` and the phase 1 checkpoint (`disk-e`) kept.

## 2026-10-27 - Code banks; the images across power-off

- Firmware ROM: Megamiga's code banks (the user: "expand the ROM size like Megamiga has
  done it"): `QNICE_CODE_BANKS` = `m2m-banks.rom` (8 x 4K words behind 0x9000-0x9FFF, 16
  RAMB36), `make_banks.py` copied from Megamiga, `FAR_CALL` and its stubs in the fixed ROM.
  The FAT32 write layer moved to banks 0/1: fixed ROM 32057 -> 27715 of 32768 words.
- `x68_img.asm` (bank 2): the settings file remembers every image line's path
  (`fdd0=SD1:/megax/...`, also fdd1, sasi, sxsi1, sxsi2, sram); PREP_START mounts them again
  before the X68000 leaves reset; a path that no longer works shows its reason for 5 s and
  is forgotten. PC10-III's pc_hdc.asm for six lines.
- The user freed space on the Fedora host (15 GB free).

## 2026-10-27 - Timing margin: palette in LUT RAM, text VRAM address

- `megax-g` (phase 3) passed only after post-route phys_opt (+0.0006 ns; -0.150 ns before):
  80 MHz, a GVRAM cache read -> 9 levels of the compositor -> the graphic palette's block
  RAM address. Fork develop `106650a`: gpram as distributed RAM with registered addresses
  (port B is never written; the altsyncram's own semantics).
- `megax-j`: that path gone; the new 80 MHz limit was one tvram_ddr register driving the
  address of all 128 text VRAM RAMB36 (0 logic levels). `tvram_bram.vhd`: the write
  registered locally (one clock later: a read reaches the RAM two clocks after its
  command), raddr/w_addr replicated (max_fanout 16). Simulation `tv-a` (test floppy, 2.7 s):
  the same 37,686 lit pixels as phase 1's picture, mask identical.
- **`megax-k`: OK, WNS +0.131 ns (SDRAM outputs), clk_ram +0.152, main_clk +4.08, WHS
  +0.033; 54.6k LUTs, 326 / 365 block RAM tiles. `MegaX-0.1-k-R6.cor`.** (`megax-i`, the
  same without these two changes: +0.113 ns.)

## 2026-10-27 - Hardware bring-up: SDRAM phase, bus trace, the HDMI scaler at 16bpp

- First loads (`megax-k`): black screen, the 68000 never got through the IPL. A probe
  (`x68_dbg.vhd`, `tools/dbgread.py`) showed SDRAMC sampling the next word: the read hold
  check of CORE.xdc had been one clock off (`-hold 1` showed +9.9 ns; the true slack at the
  fast corner was -2.57 ns). Clock phase 180 -> 288 degrees, no hold multicycle (`megax-m`:
  read +2.91 / +1.18 ns, output +1.29 / +1.03 ns). The X68000 boots the test floppy.
- 68000 bus trace `x68_trace.vhd` (device 0x0110, 1024 cycles, trigger on a program fetch;
  `tools/trace.py`), `tools/qmon.py` (the Shell's debug mode over the USB serial link; leave
  it with `CR224F`).
- `tb/sim/bootdisk/memtest.S`: 960 KB of main RAM written and read back per pass plus a CGROM
  sum. Hardware (`megax-p`): 8 passes, 0 errors, CGROM sum 8511 every pass.
- HDMI only (VGA clean): red snow on the text, and at 720p60 a picture jumping vertically
  with a band of noise for ~2 s every ~8 s. `tb/sim/bootdisk/vidtest.S` (palette, contrast
  and text colour toggles) narrowed the snow to a byte shift in the scaler's 24bpp data
  (green text gave red snow, blue text green snow); not electrical (SDRAM pins at 8 / 4 mA
  SLOW, `megax-s` / `megax-t`, no change; reverted). `tools/hrdump.py` read ascal's frame
  buffer through QMON: every corrupted 16-byte word was the word 256 bytes later in the same
  line (ascal's two-burst input buffer overrun: 768 dots at 34.776 MHz x 3 bytes fill a
  burst in 1.23 us, a HyperRAM write behind an HDMI read burst takes ~1.6 us), while 36,864
  QMON reads of a test pattern elsewhere in HyperRAM were clean. `tools/ascalpoll.py`: the
  scaler's input measurements stay at 768 x 512, 31.5 kHz (31,500.1 Hz lines against
  720p's 45 kHz: a 7:10 ratio drifting once per ~9 s, the rhythm of the jumping).
- Fix: framework exception `M2M-UPSTREAM ascal-16bpp` (`doc/m2m-provenance.md`), on via
  `globals.vhd` `ASCAL_16BPP`: the picture in HyperRAM as 16bpp 565 (1.84 us per burst, a
  third less traffic). **`megax-u`: OK, WNS +0.107 ns, WHS +0.034 ns. Hardware: no snow, no
  jumping at 720p60, colours unchanged.**
- Still open: the ROM debugger instead of the boot at some first loads (the IPL's OPT.2 /
  SRAM `$80E` check); the scaler shows its unwritten buffers' power-up noise for ~2 s until
  the X68000's scanout starts.


## 2026-11-02 - Phase 4: the exact video oscillators

- `clk.vhd`: the four oscillators of `x68k_video_clock.sv`, one MMCM each (internal
  feedback, all running all the time): family 0 69.552239 MHz (31 kHz), 1 38.863636 MHz
  (15 kHz), 2 50.349650 MHz (HMODE 3, VGA 640), 3 75.249113 MHz ("60 Hz" 31 kHz), within
  7.6 ppm. `clk_scan` (the scanout clock and M2M's video clock) is the family the core asks
  for, through a tree of three BUFGMUX_CTRL. `main.vhd`: every mode now gets `scan_ready`;
  the handshake holds the scanout in reset while the selection changes, as the MiSTer core
  does while its PLL relocks.
- `tb/sim/bootdisk/modetest.S`: a boot sector that steps through IOCS _CRTMOD 16, 1, 3, 0,
  2, 19, 17, 18 (~5 s each; mode number, format and colour bars in the text planes).
- **`megax-v`: OK, WNS +0.107 ns, WHS +0.034 ns; 54.4k LUTs, 327.5 / 365 block RAM tiles.
  Hardware: all eight modetest modes work (15, 24 and 31 kHz, 640x480, 1024x848
  interlaced).** Family 3 (75.249 MHz) is not exercised by modetest.

## 2026-11-02 - Licence: GPLv3

- Puu-san answered the user's request on the blog (comment of 2026-10-27 under
  https://fpga8801.seesaa.net/article/519747422.html) on 2026-10-29:
  「GPLv3の条件で再配布いただいて問題ありません。更新をよろしくお願いします。」("Redistributing it
  under the terms of GPLv3 is no problem. I look forward to your updates.") The request was for
  GPL version 3 or later; the answer names GPLv3 only.
- `LICENSE`: GNU GPL version 3 (the user's decision). AGENTS.md rule 5, `doc/plan.md` 4.1,
  `doc/inventory.md` and README updated. The GitHub issue MiSTer-devel/X68000_MiSTer#74
  (no answer since 2026-10-26) got a comment pointing to the blog reply.
- Still without licence text: IKAOPM, `xe1ap.v`, `mister_sync.sv`.

## 2026-11-02 - Human68k boots: the OPM bus wait

- First tries with Human68k 3.02 (`files/`, not in the repository): the DIM floppy and a 40 MB
  SASI image both gave a black screen. The bus trace (`megax-v`): the 68000 stopped for good on
  `TST.B $E90003` (the YM2151 status) in the IPL's OPM write routine at `$FF9C9C`, the first OPM
  access; on the floppy HUMAN.SYS was already loaded and running (fetches `$00AA00-$00CF00`).
  Our test boot sectors never touched the OPM.
- Simulation `h68-a` (same DIM, 6 s): no hang there (the OPM accesses complete).
- `megax-w`: probe `dbg_opm` (fork `X68K_top` port, `x68_trace.vhd` register 9 and an
  opm_ce(0) pulse counter in 10/11, `tools/trace.py --status` decodes it). On the board:
  `opm_csn=0`, `b_rdn=0`, all resets inactive, opm_ce(0) running, `iowait_opm=1`, but
  `opm_wstate` stuck at 0. In the routed design the clock enable of the (one-hot) FSM took the
  clock net `sysclk` through a LUT4: Vivado built upstream's
  `elsif(sndclk' event and sndclk='1' and opm_ce(0) = '1')` into CE = sndclk and ..., which is
  never seen at the rising edge. Quartus and ghdl read it as an edge with an enable.
- Fork `4bd3cb5`: that process as `rising_edge(sndclk)` with the enable inside (provenance
  comment, the original line kept). The two other processes of that form in `X68K_top`
  (palette entry 0, the PS/2 input sampling) have no clock path in their enables (checked in
  the routed design) and stay as they are.
- **`megax-x`: OK, WNS +0.081 ns, WHS +0.034 ns. Hardware: Human68k boots from the DIM floppy
  and from the SASI hard disk image.**
- Open: in simulation the DIM's boot sector stops after reading the FAT and root directory
  (`h68-b`: an IOCS call that looks like an error exit at 1.878 s), while the board loads
  HUMAN.SYS from the same image: probably the testbench's DIM handling, not looked into.

## 2026-11-02 - SxSI 3/4, the fast clear, HDMI black after a reset

- **SxSI 3 and SxSI 4 in the menu** (`megax-y`, `18d456c`): devices 0x0107/0x0108 (x68_sd
  already served slots 6/7), 8 manual loads, settings keys `sxsi3`/`sxsi4`, menu signature 4
  (35 lines; an older settings file is reset). A 4-image HDS pack (1 GB + 3 x 2 GB) boots.
- **Fast clear hang** (TwinBee, the pack's boot sometimes stopped in `BTST #1,$E80481` at
  `$04C2F4`): `vcreg`'s FCbgn/FCend were combinational from the CPU bus into the 80 MHz fast
  clear logic behind the main_clk -> clk_ram multicycle (18.6 ns paths), a phantom FCend ended
  the clear early. Fork `fbdf1fd`: both registered on clk (originals commented), `CORE.xdc`
  takes gclrbgnrq/gclrendrq out of the multicycle. Since `megax-zb` no hang seen.
- **Faster mounts** (seek to the end through the extent map, QNICE branch `megax-fastmap`):
  `megax-z/za` booted the wrong or no disk, `megax-ze` mounted a 40 MB SASI image correctly but
  a 2 GB HDS from the menu ended in a FATAL (803F). Reverted on main (`395c350`), open.
- **HDMI black after about every other reset** (VGA fine, OSD shown on HDMI, the picture
  flashing on HDMI while the reset button is pressed; Megamiga never does this):
  - `megax-zc` (fixed video clock) and `megax-zd2` (ascal held in reset with the core): no
    change. QNICE HyperRAM reads hung in the bad state.
  - `megax-zf`, probe `hr-debug` (the arbiter's lines and counters in `x68_trace` 0x0C-0x0F,
    `trace.py --status`): on the first load already black; the scaler wrote 64-word bursts on
    and on, the controller returned no read data any more (256 words since the load).
  - `megax-zg`: ascal read watchdog (a whole output frame without read progress restarts the
    read pipeline) and ascal's state in the probe. 8 resets fine, the 9th black: readlev=2,
    copylev=0, the watchdog firing every frame, still no read data from the controller.
  - Cause: the HyperRAM controller has no waitrequest in WRITE_BURST_ST. When a write burst is
    cut short upstream, the controller waits for the missing words, later bursts are shifted
    and every read arrives during a "burst" and is lost (the arbiter sees it accepted). In
    MegaX ascal is reset by `video_rst` without the HyperRAM (core resets, the video clock
    reprogrammed per mode); a reset in the middle of a write burst cuts it.
  - `megax-zh` (`b71bf1e`): ascal's Avalon side reset only with the HyperRAM
    (`ascal-avl-reset`). Better, but on the 6th reset HDMI showed only vertical bars (the
    watchdog restarting ascal on stale line buffers): something else still cuts bursts.
  - `megax-zi` (`91e36a5`): the controller holds a read during an unfinished write burst, cuts
    the burst (CS high) and does the read (`hr-burst-cut`). **20 resets and several games
    (TwinBee, Dracula) without a black screen.** Timing: 73 ps short on the new combinational
    waitrequest path (QNICE FIFO - arbiter - controller - arbiter - ascal).
  - `megax-zj` (`628a660`): the same recovery registered (the read taken in WRITE_BURST_ST is
    started from RECOVERY_ST), the cut and watchdog counters counting since the load.
  - **`megax-zj`: OK, WNS +0.140 ns. 20+ resets and games without a black screen; since the
    load the controller cut 6 write bursts (each would have been a black HDMI before) and the
    ascal watchdog fired 15 times.**
- **Fast clear hang, second cause** (`megax-zj`, the SxSI system disk, black screen with a
  cursor on both outputs, the 68000 in `BTST #1,$E80481` at `$0462F4`): reproduced on the
  first try with the trace armed at `$0462F4`. The boot scrolls text by raster copies (read
  `$08`, write `$08` to R21 `$E80481`), ends them with `$00` and 80 bus cycles later writes
  `$02` (fast clear). Every R21 write with bit 1 = 0 left vidcont's `gclrendrq` set until the
  next hcomp, which then cancelled the fast clear requested later in the same line. Fork
  `1ac77b5`: a request clears a stale stop, a stop is taken only when a clear is pending or
  running (provenance comment). Build `megax-zk`.

## 2026-11-02 - Mouse and joysticks

- `mouse.vhd`: an Amiga quadrature mouse in DB9 port 1 as the PS/2 mouse that the core's
  MOUSECONV (SCC) expects: PC10-III's quadrature decoder (`cbm_mouse.sv`), the PS/2 device line
  of `keyboard.vhd`, answers FF (FA AA 00), F2, F4/F5/F6, 3-byte packets at most every 10 ms.
  `tb/shell/run_mouse.sh`: tb_mouse PASS against MOUSECONV (start-up FF/F6/F4, both axes and
  signs, the left button). MOUSECONV's counters have no reset (`mouseconv_sim.py` gives them
  the FPGA's 0 in simulation).
- Joysticks: MiSTer's default 2-button mode (pJoyA/pJoyB: up, down, left, right, A = fire,
  B = pin 9). Menu "Mouse in port 1" (default on: port 2 = X68000 joystick 1; off: ports 1/2 =
  joysticks 1/2), menu signature 5. The second buttons (mouse right, joystick B) are on the
  POT line of pin 9: Megamiga's presence latch, so only active adapters (MouSTer) give them;
  a passive switch to GND is invisible (the POT lines reach the FPGA only through the paddle
  comparators). A keyboard fallback or a pull-up adapter: not for 0.1 (the user).
- `megax-zl` (incremental from megax-zk): timing met, but write_bitstream failed ("Site type
  pointers for element PAD and routed site do not match", 8 IOBs: pins unused in the
  reference); `megax-zl2` (not incremental): OK, WNS +0.078 ns. **Hardware: the mouse works.**
  Joystick not yet tested (the SMS pad is missing). 2026-11-03: **a TAC-2 (one button) works**;
  Dracula's whip is on the second button, which a one-button stick does not have.

## 2026-11-02 - Faster mounts, second try

- Split into **part A**, the firmware's seek to the end through the extent map
  (`FAT32$FILE_SEEK_MAP` of main's QNICE `78aeaac`, `9b7685e`) instead of a second walk of the
  chain by `f32_fseek`, and **part B**, the map builder's fast path (QNICE `megax-fastmap`,
  `749d32d`: `_F32_FM_RUN` follows the entries of the FAT sector in the buffer while each one
  is "current + 1").
- Part B in the QNICE emulator with a file of the size of the user's HDS (1981808640 bytes,
  4 KB clusters = 483840 clusters, one extent; `fat32_seek` with `SPCS=8 BIG_BYTES=...`,
  QNICE `6c0665f`): PASS (map, seeks with and without it, the 65536-cluster crossings).
- **`megax-zm` (part A alone; WNS +0.078 ns): the 2 GB HDS mounts from the menu in about 8 s,
  half the time before.** So part A was not what broke `megax-ze`. The 8 s left are the map
  builder's walk of the chain (3780 FAT sectors, every entry through READ_DW/READ_W/READ_B/
  CALL_DEV), which part B is meant to cut.
- `megax-zn` = `megax-zm` + part B (QNICE `6c0665f`), to try part B alone on the hardware.
  Shell ROM 27928/32768 words.
- **`megax-zn` (part B on top; WNS +0.078 ns): boots fine from the start-up mounts, the 2 GB HDS
  mounts from the menu in about 4.5 s.** Main pins QNICE `megax-fastmap` `6c0665f` again.
- **Direct buffer reads** (QNICE `724b470`, `FAT32$DEV_DIRECT`; the Shell's `SDC$MOUNT` sets it,
  M2M-UPSTREAM fat32-fastmap): the fast path reads the FAT entries through the SD controller's
  cursor and data registers after one byte read call that selects the slot, about 28 instead of
  about 100 instructions per entry. Emulator: every case with and without direct reads, the
  2 GB case, a new `J.BIN` (chain jumping 65536 clusters ahead) for the high word checks;
  mutants all killed except `flush_r9` (survives on `78aeaac` as well).
  **`megax-zo` (WNS +0.078 ns): the 2 GB HDS mounts in about 2 s (16 s before part A), start-up
  mounts and the boot after a reset fine.**
- Next step for mounting speed, after 0.1 (the user: "the way to go", for Megamiga and
  PC10-III too): the extent map built in the FPGA, `doc/plan.md` section 4 item 7.

## 2026-11-03 - Settings file of another menu layout

- The FATAL of 2026-11-02 ("config.vhd: No selected menu group item found within submenu",
  0x0016, after a detour to `megax-u`): `megax-u` (33 lines) read the 35-line file, took the
  extra menu bytes as the start of the text, a 0x00 ended the text, so no signature: the
  defaults, `menu=3` appended behind the old `menu=4`. The longer menu then found its old
  signature first and took the shorter layout's bytes; the HDMI submenu had no item selected.
- Fix (M2M-UPSTREAM cfg-strings, `doc/m2m-provenance.md`; Megamiga has the same code):
  `CFGS_LOAD` skips 0x00/0x01 before the text, and the new `CFGS_GRPCHK` requires exactly one
  selected item per radio group before the signature check; otherwise the defaults, keeping the
  text (the remembered images). A wrong file can now give wrong options, but no FATAL.
- **`megax-zp` (WNS +0.078 ns) on hardware, the incident replayed: `megax-zp` saved its file,
  `megax-u` rewrote it in its layout, `megax-zp` again: no FATAL, the defaults, all four SxSI
  drives of the pack present after the fresh start.**
- Earlier the same day the pack once came up with SxSI 2-4 missing after a JTAG load in the
  middle of a game (the load was mine, the user was playing); not seen again. To watch: after a
  reset the core announces all mounted drives at once on one shared image-size bus (X68000.sv's
  logic, kept in x68_system), so diskemu could take one drive's size for all.
- The user: a reset after mounting an SxSI image would help (the SxSI driver looks for its
  drives only at boot).

## 2026-11-03 - SxSI drives at start-up and after a mount

- The user: all images must be mounted before the X68000 boots, and a mount from the menu needs
  a reboot (the SxSI driver looks for its drives only at boot). Two causes of missing drives:
  `PREP_START` ended the boot load (the 68000 starts) before `IMG_RESTORE`, so the IPL could
  boot while SxSI 2-4 were still mounting; and after a reset x68_system announced all drives in
  the same clock on one shared image-size bus, so diskemu could latch one drive's size for all.
- Firmware (`CORE/m2m-rom/m2m-rom.asm`): `PREP_START` holds the X68000 in reset
  (`M2M$CSR_RESET`) through `IMG_RESTORE`; `START_CONNECT` releases it. A mount or eject of
  an SxSI/SASI image in the menu sets `X68_HD_RESET` (`FD_HDFLAG`: slot 2 = SASI, 4..7 = SxSI 1..4); when the
  menu closes, `HANDLE_CORE_IO` pulses the reset once.
- x68_system: every mount keeps its size per slot (`slot_size`); after a reset the drives are
  announced one at a time, 256 clocks apart, each with its own size on `ann_size` (the old
  announce-all block stays as a comment).
- **`megax-zq` (WNS +0.078 ns): a fresh start with the 4-image pack shows all four drives on the
  first boot; the mounts are quick enough for 0.1.**
  Mounting and ejecting SxSI images from the menu (several times): the X68000 reboots when the
  menu closes, and the drive appears or is gone.
  A reset (key and menu) keeps all four drives, the 1 GB one included.
  Opening and closing the menu without a mount does not reset.

## 2026-11-03 - The hr-debug probe removed

- Out (M2M-UPSTREAM hr-debug, 2026-11-02): the framework's `hr_dbg_o` and its wiring through
  `top_mega65-r6.vhd` and `mega65.vhd`, `x68_trace` registers 0x0C-0x0F, ascal's `o_dbg` and
  watchdog counter, the controller's burst-cut counter in `count_short_o`, the false path in
  `CORE.xdc`, the HyperRAM part of `trace.py --status`.
- Kept: hr-burst-cut, ascal-avl-reset and the read watchdog, now its own tag
  `ascal-read-watchdog` (`doc/m2m-provenance.md`). Why the watchdog fired 15 times on
  `megax-zj` stays open (no reading taken before the probe went); it restarts ascal's read
  pipeline at a VS, at most a frame's glitch.
- **`megax-zr` (WNS +0.078 ns, 35 LUTs fewer, block RAM unchanged at 327.5): cold start with
  the 4-image pack, about ten resets (key and menu) and games: HDMI back every time.**

## 2026-11-03 - Release 0.1 packaged

- `MegaX-0.1-R6.bit` = `megax-zr`; `MegaX-0.1-R6.cor` by `coretool -B ... --target mega65r6
  --bit-name "MegaX X68000" --bit-version 0.1` (verify OK; Megamiga's `make_release.py` naming).
  No settings file in the release: the Shell creates `/megax/megaxcfg` (cfg-create).
- README: status for 0.1, getting started. D88 write-back and the SRAM load/save listed as
  built but not yet tested on the hardware. The user: no noise at power-up any more, the
  sound (OPM, ADPCM) sounds right.
- **The `.cor` flashed to slot 3 boots fine** (the first start from flash; JTAG before).

## 2026-11-04 - R3 study, step 1: the SDRAM traffic measured on R6

- A temporary probe (`doc/plan.md` section 4 item 8, step 1), the provenance comment "MEGA65
  port 2026-11-03 (temporary)" at every place:
  - Fork: cachecont reports its state class (`dbg_class`); memcont and X68K_top bring it out
    with SDRAMC's command lines (`dbg_o`, `dbg_mem`).
  - MegaX: `CORE/vhdl/x68_r3probe.vhd` counts the traffic per class on clk_ram and copies every
    command, with the same number of words, the same class and order, into the HyperRAM
    (the framework's unused `hr_core` port, words 0x200000 up = the upper 4 MB, clear of ascal's 1 MB; read data
    thrown away). So the HyperRAM carries what an R3 core would put on it, next to ascal.
  - It also measures the copy's latency per class, and the time from each HCOMP to the end of
    that line's GVRAM reads. Readout through QNICE (`C_DEV_X68_DEBUG` window 4,
    `tools/r3probe.py`, log in `~/megax-work/r3probe.log`).
  - Tests: `tb/shell/run_r3probe.sh`: synthetic lines into a HyperRAM stand-in, 160 commands
    and 25,920 words copied, nothing lost.
- **`megax-r3a`** (WNS +0.002 ns; +1,600 LUTs, 328.5 tiles): the counters are 32 bits wide, so
  a window must be shorter than 43 s (hr_clk). The first reading (2026-11-03, about 93 s) had
  wrapped; the HyperRAM busy figure was unusable.
- Readings (30 s windows, 2026-11-04):

  | | LHES file manager (31 kHz, GVRAM shown) | Dracula in game (15 kHz) |
  | --- | --- | --- |
  | SDRAM busy (refresh not counted) | 16.4 % | 32.2 % |
  | GVRAM line reads | 9.4 %; 2 x 256 words on 256 lines per frame | none |
  | CPU read fills (128 words) | 5.6 %; 599 per frame | 29.8 %; 3,052 per frame |
  | CPU write-backs | 1.5 %; 1,846 per frame, 2.4 words each | 2.4 %; 2,897 per frame, 1.3 words each |
  | CPU reads hitting the cache | 98 % | 91 % |
  | CPU waiting for SDRAM; longest wait | 7.2 %; 7.95 us | 11.9 %; 1.62 us |
  | busiest line | 1,963 of 2,540 cycles | 3,167 of 5,007 cycles |
  | HyperRAM busy (ascal + copy) | 36.4 % | 27.1 % |
  | copy: longest latency | about 50 us, all classes | 9.1 us (fills) |
  | copy: GVRAM reads, average / latest end after HCOMP | 5.4 us / 49.9 us (line 31.75 us) | - |
  | copy: longest backlog, lost | 17, 0 | 5, 0 |

  - The "refresh" class (62-77 %) is idle time: cachecont starts a refresh whenever it has
    nothing else to do. HyperRAM refreshes itself, so it does not count for R3.
  - HDMI snow (white pixels near text) in the file manager while the copy runs, none in
    Dracula, VGA clean: the copy's traffic in a GVRAM mode disturbs ascal, although ascal has
    the arbiter's priority. Likely its input side waiting behind the copy's 128-word bursts, as
    with 24bpp (2026-10-27); not verified.
  - Not measured: a 512-line GVRAM mode (GVRAM reads on every line, twice the file manager's)
    and graphics fast clear. The user knows no software for these; Human68k and the file
    manager are what is at hand.
- Conclusions for R3:
  - The bandwidth is there: even with the copy, HyperRAM is at most 36 % busy.
  - The CPU side looks feasible: a fill is 128 words, about 1.3 us on either RAM; in HyperRAM
    the waits are longer (queueing behind ascal), which slows a miss and breaks nothing. Only
    the longest fill latency was measured, not the average.
  - The GVRAM line reads are the problem, as expected: on average 5.4 us, but the worst case
    ended 50 us after HCOMP, more than a line late. In an R3 core they need priority over the
    CPU traffic, a guaranteed slot per line next to ascal's bursts or a prefetch further ahead
    than one line (step 2 of the plan). The small write-backs (1-2 words, one HyperRAM command
    each) are worth batching.
  - The snow says ascal's share needs protecting too: shorter bursts for the core's port.

## 2026-11-05 - R3 step 2: the core's memory in the HyperRAM (x68_hrmem), in simulation

- `CORE/vhdl/x68_hrmem.vhd` takes the place of the core's SDRAM controller under cachecont: the
  fork's memcont got a generic `EXT_RAMC` (SDRAMC's lines to `xr_` ports, X68K_top passes them
  through); `x68_system` `G_HRMEM`, `globals.vhd` `X68_HRMEM` (off: the R6 build is unchanged),
  `main.vhd`/`mega65.vhd` route the framework arbiter's core port to it (the R3 probe's mirror
  then sees a port that never answers). HyperRAM layout: ascal's frame buffer (1 MB), GVRAM, the
  ROMs, 4 MB of main RAM (vis_mem 4 MB), the rest aliased (no D88 on R3).
  - Inside: three dual-clock FIFOs (`x68_afifo.vhd`, written out so that tb/sim runs the same
    code), bursts of at most 64 words, posted writes, the HyperRAM side keeps the order.
  - SDRAMC's behaviour, measured with its chip model and copied exactly: a read gives
    ((end - bgn - 2) mod 2^bwidth) + 2 words with de (one round more when end = bgn + 1), and one
    more word, the one at end, in the clock after the last de word with busy already low
    (cachecont's fast clear takes it on de's falling edge); a write writes at least two words;
    write data come one clock after addr_wc.
- `tb/hrmem`: the same 4000 random commands through SDRAMC and x68_hrmem, both against a
  reference model. Found and fixed: the write side threw the next write's words away in the
  clock after a write's last burst; one tag for reads and writes let a read take an aborted
  read's late words (an abort, three posted writes); four aborted reads in a row wrapped the
  read tag (now the words of aborted reads are counted and dropped). 50 seeds pass.
- tb/sim (`HRMEM=1`, a HyperRAM model with waits and gaps, `HOG=256,100`: the arbiter taken 39 %
  of the time, as by ascal): ghdl's synthesis dropped memcont's assignments from the `xr_`
  ports inside the generate (busy never reached cachecont: no picture at all), now chosen
  outside it; the first read was lost when the HyperRAM side left its reset after the core's
  first command (the idle state popped the command in reset; the 68000 waited 769 us for the
  timeout), now commands wait for the reset to end (and tb/hrmem has the case).
  - **`gvtest` (new boot disk: 512x512 in 65536 colours, all of GVRAM, then main-RAM traffic):
    the HyperRAM build shows the same frames as the SDRAM build** (12 frames in a row with
    the same checksums, all 262140 pixels lit; the HyperRAM one 3 frames later, its 68000 is
    slower).

    | | SDRAM | HyperRAM, 39 % taken |
    | --- | --- | --- |
    | GVRAM line reads: latest end after HCOMP (line 31.75 us) | 8.31 us | 15.41 us |
    | lines still reading at the next HCOMP | 0 | 0 |
    | the 68000 waiting for memory | 6.34 % | 9.01 % |
    | its longest wait | 7.25 us | 14.05 us |

- Vivado, R6 with `X68_HRMEM` on: `megax-hr1` (incremental from megax-r3a) TIMING-FAILED: the
  crossing constraints named Gray pointer registers Vivado had merged into the binary ones,
  the burst length logic had 15 levels, and the TVRAM address fan-out routed 13.8 ns. Now the
  constraints name the synchronisers, the counts and the burst length are registered: **`megax-hr2`
  (non-incremental) OK, WNS +0.103 ns**, block RAM 327.5 tiles, crossings +2.5/+3.0 ns under
  their 8 ns bound. **`megax-hr3` (the reset fix, incremental from hr2) OK, WNS +0.103 ns**: the
  build for the first try on the R6 (not yet loaded; the user's go-ahead first).

## 2026-11-05 R3 step 2 on the R6: megax-hr3 does not boot

- **`megax-hr3` on the R6 (the user, JTAG): no boot.** HDMI keeps the colour bars it shows while
  the bitstream loads (normally black once the X68000 starts), nothing more happens. The bars
  stay until the IPL programs the CRTC (before that the core sends no frames for ascal to
  write), so either the 68000 never ran or it ran and lost itself before its video set-up.
  A load the core does not take freezes the Shell without a message (x68_boot holds QNICE with
  qnice_wait while its FIFO is full); a load taken but not ended would say "The X68000 did not
  take /megax/boot.rom".
- What simulation now rules out:
  - the boot ROM through the real loader byte by byte into the HyperRAM path (tb/sim
    `--slowload`, HRMEM=1): loaded at 81 ms, the IPL's video mode at 264 ms;
  - the board's resets (tb/sim `--hw-reset 2000`, new: none before the boot ROM, as
    mega65.vhd gates the M2M resets with boot_ended, then the Shell's reset from the end of the
    load, PREP_START): both builds boot the same way (ROM at 81 ms, mode at 265 ms);
  - the framework's own arbiter and HyperRAM controller instead of the Avalon model (tb/hrmem
    `M2M=1`, new: avm_arbit_general with the scaler first, hyperram_errata, hyperram_config,
    hyperram_ctrl synthesised by ghdl, the PHY and the chip modelled at the `hb_*` lines, a
    QNICE-like and a scaler-like master checking their own data): 30 seeds pass, nobody hangs;
  - the hr_rst deadlock idea: the HyperRAM reset follows only the reset button (reset_manager),
    not the Shell's core reset;
  - the memory map: the R6's HyperRAM is one 8 MB part (MiSTer2MEGA65 wiki); ascal uses 1 MB
    (16bpp, triple buffering and its framebuffer mode off);
  - crossings: report_cdc on hr3's routed design shows only the FIFOs' structures (RAM reads,
    Gray pointers), nothing else between clk_ram and hr_clk.
- tb/hrmem on the Fedora host's Verilator 5.046 runs wrongly (every command a write, no reads
  checked; seed 1 hangs in the old mode too); on the laptop (5.032) as before. Not looked into.
- The next try is diagnostic: `megax-hr4` (LED flags, OK WNS +0.103 ns) and `megax-hr5` (hr4 +
  `x68_hrtest.vhd`, a self-test of the HyperRAM path before memcont gets it: 24 blocks of 256
  words, a full write, a byte-masked write, a read-back). The LEDs (X68_HRMEM only, mega65.vhd)
  show the start-up stage (power LED) and the memory path (drive LED) with the Shell frozen.
- `megax-hr4` (REF megax-hr3) OK, WNS +0.103 ns. `megax-hr5`: the incremental synthesis from
  hr4's checkpoint segfaulted after "Mimic Skeleton from Reference" (the new x68_hrtest changed
  the hierarchy); with `NO_REF_SYNTH=1` (implementation still incremental) OK, WNS +0.102 ns.
  tb/sim: the self-test passes (flags 0205) and the machine boots after it; a copy with a
  mutated expectation reports the errors (0605). Neither build loaded yet.

## 2026-11-05 megax-hr5 on the R6: the self-test ran while the HyperRAM was in reset; megax-hr6

- `megax-hr5` on the R6: still no boot. Power LED blue, then green (the boot ROM is in, the
  68000 runs); drive LED blinking magenta (the self-test timed out); the Help key opens the menu
  (the Shell is alive).
- Wrong in the entry above: hr_rst does not follow only the reset button. At power-on the M2M
  reset (reset_manager, the blue power LED) holds hr_rst (clk_m2m: `qnice_locked and sys_rstn_i
  and core_rstn_i`) together with QNICE, while clk_ram runs and x68_hrmem, x68_hrtest and memcont
  are out of reset (they follow `locked`; X68K_top's mem_rstn is plllock, vid_rstn plllock and
  ram_inidone). x68_hrmem's initdone came 256 clocks after `locked`, so the self-test, then
  memcont (its GVRAM clear, the video) started with the HyperRAM side still in reset; a read
  then times out after 65536 clocks and its command stays in the FIFO.
- tb/sim `--hr-reset <us>` (new; the default 2 us was the old behaviour): with 60 ms the old
  x68_hrmem gives the board's result, flags 0a47 (the self-test timed out, commands waited in
  H_IDLE), but the machine still boots (IPL's mode 5 at 325 ms, 182 ms after the Shell's reset,
  as before). So the reset explains hr5's self-test result, not the failure to boot; the test
  said nothing about the HyperRAM.
- Fix (x68_hrmem): hr_rst synchronised into clk_ram (hrrst_s1/s2, ASYNC_REG, CORE.xdc
  max_delay); initdone only while it is low, and a read does not time out while it is high.
  With 60 ms: memcont starts at 60.27 ms, the self-test passes (0205), mode 5 at 325 ms.
  tb/hrmem: 5 seeds and 3 with M2M=1 pass.
- `megax-hr6` = hr5 + the fix (REF megax-hr5, NO_REF_SYNTH=1): its self-test now runs on the
  working HyperRAM, so its result on the drive LED means something.
- `megax-hr6`: TIMING-FAILED, WNS -2.637 ns, the one path hr_rst -> hrrst_s1 (hr_clk -> clk_ram,
  2.5 ns); everything else met (+0.102 ns). The new constraint had no `-from` ("set_max_delay
  -datapath_only requires -from to be non-empty", critical warning, dropped); now `-from
  [get_clocks hr_clk]`. `megax-hr7` = hr6 with that (REF megax-hr6).
- `megax-hr7` OK, WNS +0.000 ns (a GVRAM_CTRL fill_row -> plane RAM address path, met), WHS
  +0.025 ns; no warning on the new constraint, 35 critical warnings as hr5 (the known ones).
  Not loaded yet.
- `megax-hr7` on the R6 (20:32): power LED green, drive LED off (self-test passed, no flag),
  HDMI horizontal stripes flickering (new: before, the bars), VGA black, the menu opens. Bus
  trace (`tools/trace.py`): 4390 bus cycles in all, the last the IPL's copy loop at FF004E
  (longwords FF1Bxx.. -> 0x0484..) reading FF1DFE; dbg_opm: AS low, a read pending, srstn and
  cpu_rstn high. The 68000 waits for the read of FF1E00. tb/sim (60 ms hr_rst, --bus): bus
  cycle 4390 is the same read of FF1DFE, cycle 4391 FF1E00 at 145.150 ms, the CPU read fill
  addrh 7f8f bgn 00 end 00 bwidth 7 (HyperRAM 0x1f8f00: bursts of 64, 64, then 1 word), the
  seventh fill since the reset; the six before it worked on the board too. A CSR reset of the
  X68000 (`trace.py --arm 000001 --reset`): 4391 more cycles (8781), the same stop. So the board
  runs cycle for cycle as tb/sim up to that fill, and it is deterministic. x68_hrmem shows no
  flag (not busy, no read timeout), so either the fill never reached it or cachecont did not
  take its answer.
- Debug window (temporary): x68_hrmem's `dbgx_o` (both state machines, FIFO counts, counters,
  the last read) and memcont's dbg_mem, QNICE device 0x0110 window 5 (mega65.vhd p_hrx, false
  path), `tools/hrstate.py`. Build `megax-hr8` (REF megax-hr7, NO_REF_SYNTH=1).
- tb/sim `--hr-nogap` (read words back to back, no random waitrequest, as the framework's
  controller) and `--hr-lat <min>,<span>`: with no gaps and fixed latencies of 8, 15, 30 and 60
  clocks the IPL goes on past the fill (12808..14774 bus cycles at 150 ms). Not reproduced.
- `megax-hr8` OK, WNS +0.050 ns, 35 critical warnings (as before, none on the new false path).
- `megax-hr8` on the R6 (21:02), `tools/hrstate.py` at the hang (both reads the same): x68_hrmem
  idle with everything done (1382 reads, 1382 ended, none aborted or timed out, FIFOs empty,
  the HyperRAM side idle); memcont: the CPU's read request up, no acknowledge, cachecont in
  ST_IDLE. So cachecont never starts the fill; x68_hrmem is not the one waiting. The last read
  was GVRAM 77ff (the GVRAM clear's last row): X68K_top's power-on clear runs again when the
  Shell's reset ends (gvclr follows rstn), concurrently with the IPL (tb/sim: 143..156 ms), and on
  the board it ran to the end while the CPU waited (1382 reads against ~600 in tb/sim at that
  point). In ST_IDLE the fill starts when braddrnone and sb_rd (rambusy 0, brcache_busy is
  always 0): with the request up, a read block must claim line 7f8f without the word.
- Debug window 5 extended (fork, temporary): cachecont's state, brcache_sel, aborted, the
  synchronised request and address, per read block the tag, cacheext's mask and rdb
  (cacheext dbg_o, cachecont dbg2_o, memcont, X68K_top dbg_cache), words 64..127;
  `tools/hrstate.py --raw` decodes tb/sim's dump (tb/sim prints it at the end). In tb/sim at
  150 ms six reads were aborted during their words (SDRAMC also takes abort only in its data
  phase). Build `megax-hr9`.
- `megax-hr9` OK, WNS +0.000 ns (gpal -> LBUFWD, met), 35 critical warnings as before.

## 2026-11-05 The root cause: cacheext sampled the CPU clock as data

- `megax-hr9` on the R6 (21:29), `tools/hrstate.py` at the hang: this time the 68000 stopped
  after 19 bus cycles (reading 7f8288, the IPL's second fill). cachecont refreshing and idle,
  sb_rd 1, braddrnone 0: read block 1 holds line 7f8280, its word is there (cacheext rdb 1), but
  cacheext's mask is 0, so brcache_ext is 0 and the CPU gets no acknowledge, for ever; every
  other block has mask 1.
- cacheext (upstream) lowers mask at the block's clear and raises it after two rising edges of
  rclk (the CPU side's clock, 40 MHz), which it counted by sampling rclk itself as data in wclk's
  domain (srclk <= rclk, 80 MHz). clk_sys and clk_ram come from one MMCM with aligned edges, so
  every sample falls on an edge of clk_sys and what it sees depends on the routing: a read
  block whose sampler never sees a rising edge never raises its mask. One such block per
  build, placed by the routing: in hr7/hr8 (hr8 implemented incrementally from hr7, the same
  placement) the block of the seventh fill, in hr9 that of the second. That is why the hang
  was deterministic per build and never seen in tb/sim; the SDRAM builds had placements where
  every block worked (luck: any rebuild could have hit it).
- Fix (fork be44860, cacheext.vhd, provenance comment): rclk's side toggles rtog at every edge
  with sys_ce (the edges at which it steps its read pipeline), wclk's side takes it through two
  registers and counts its changes; rd waits one or two clk_ram clocks longer after a clear.
  tb/sim HRMEM=1 with the board's resets: the same boot (mode 5 at 325.200 ms, flags 0205).
- `megax-hr10` = hr9 + the fix (REF megax-hr9).
- `megax-hr10` OK, WNS +0.107 ns, WHS +0.025 ns. Two new critical warnings: CORE.xdc's false path
  to cacheext's srclk (X68000.sdc's) found no cells; the toggle that replaced it is an ordinary
  clk_sys -> clk_ram path and met timing, so the constraint is removed (no effect on hr10's
  bitstream). Not loaded yet (the user asleep).
- tb/sim SDRAM build (FD0=gvtest, 1.2 s) with the cacheext fix: 57 frames identical to sd-gv3
  (before the fix), mode 5 at 182.075 ms in both. `megax-s1`: the SDRAM build (X68_HRMEM false)
  with the fix, for the board (0.1 = megax-zr has the same latent cacheext bug, its placement
  happened to work).
- `megax-s1` OK, WNS +0.092 ns, WHS +0.022 ns, 19 critical warnings (the SDRAM configuration; the HyperRAM-only constraints are not among them). Not loaded yet.

## 2026-11-06 megax-hr10 boots Human68k from the HDS; a crash at the disk boot: cache tags from b_addr

- `megax-hr10` loaded (the user's OK): the HyperRAM build boots, picture on HDMI and VGA, the IPL
  loads the ROM, the SxSI driver starts, then at the disk boot, every time at the same place:
  "Illegal instruction executed (SR=$2011:PC=$49564958)". $49564958 is "IVIX" in ASCII: text
  taken as a return or jump address, corrupted memory.
- Window 5 (tools/hrstate.py) at the error: no read timed out; 46425 of 48449 reads aborted
  (16-bit counters; the 68000 gets its word first and moves on while the 128-word fill still
  runs, far more often than on the SDRAM); and read blocks 5 and 12 both tagged with line
  0x400 (bytes $800-$8FF, the system work area). braddr is written only at reset, by the
  write-back invalidation and the abort (sb_addr's line, or none) and at a fill start, which
  needs braddrnone (sb_addr's line in no block) but tagged the block with **b_addr's** line
  while it read sb_addr's (ramaddrh, rambgnaddr). So a duplicate means a fill whose b_addr line
  was already cached and whose sb_addr line was not: the block got one line's words under
  another line's tag. sb_addr is b_addr through two clk_ram registers (taken only when stable),
  and b_addr can change under a held b_rd: abus switches between the 68000 and the DMAC
  (`dma_bconte`), and the crash comes with the first disk DMA. The SDRAM builds have the same
  window; the HyperRAM's timing (posted writes, early aborts) hits it.
- Fix (fork 7eda3fd, cachecont, both fill branches): the tag is sb_addr's line. If b_addr has
  moved on, its line simply misses and gets its own fill afterwards. cachecont dbg2_o word 8
  (temporary) counts fills where the two lines differed (tools/hrstate.py prints it).
- `megax-hr11` = hr10 + the fix (REF megax-hr10).
- The user: a long press of the reset button (the M2M reset) leaves the power LED blue for ever
  (also before; never tested). x68_boot's clk_sys side ended once and stayed ended (only the
  clocks' reset cleared s_ended), but the restarted Shell loads boot.rom again: no byte left the
  FIFO, qnice_wait_o held QNICE for ever, so the Shell's reset to the core (blue) never ended. Every
  build since phase 2 has it, 0.1 included. Fix: after the end the clk_sys side takes the bytes of
  a later load and drops them (the core keeps ldr_done and the ROM in memory); the long reset then
  restarts the X68000 like a short one. tb_boot: a long reset and a second load (the old x68_boot
  fails it: "QNICE held for ever"); PASS.
- `megax-hr12` = hr11 + the x68_boot fix (REF megax-hr10); `megax-s2` = s1 + the cachecont tag fix
  + the x68_boot fix (REF megax-s1).
- `megax-s1` loaded (the user): boots from the HDS, no illegal instruction (the cachecont tag
  window did not hit the SDRAM timing there); VGA fine, a bit of snow on HDMI. The snow is
  x68_r3probe's mirror (every SDRAM command copied into the HyperRAM next to ascal; the same snow
  in the R3 measurement, 2026-11-04; 0.1 had no probe). `globals.vhd` `X68_R3PROBE` (new, false):
  the probe's counters stay, its mirror no longer reaches the framework's core port, which is
  idle again in the SDRAM builds as before the study.
- `megax-s3` = s2 + X68_R3PROBE false (REF megax-s1).
- `megax-hr11` OK, WNS +0.107 ns, WHS +0.025 ns, 35 critical warnings (as hr7). `megax-s2` stopped
  (the user skipped it for s3).
- `megax-hr12` OK, WNS +0.107 ns. `megax-s3` OK, WNS +0.092 ns, WHS +0.022 ns.
- `megax-hr11` on the board (the user): the same crash; a bit of HDMI snow hr10 did not have.
  cachecont's new counter: **0** fills with b_addr's line not sb_addr's. So the tag theory was
  wrong: window 5 is read word by word while the machine runs, and "two blocks with one tag" was a
  block read before an eviction and another after it. The tag change stays harmless (the lines
  were always equal) but fixed nothing.
- The bus trace (tools/trace.py --arm 564958 --reset; ~/megax-work/hr11-trace.txt) caught it:
  the CPU writes the long $00014944 to $0148DC and $00014956 to $0148E0, later reads $0148D6,
  $0148DA, $0148DC and $0148DE all as $4956, the last word it wrote, then `MOVEA.L 6(A1),A4` /
  `JSR (A4)` at $DF42 jumps to $49564956.
- **The cause** (x68_hrmem): during a read cachecont merges dirty words of its write cache into
  the read words (brwdath/brwdatl for fills, the same for the GVRAM and TVRAM line reads); it
  looks the write cache's data (BWcache, ramaddrwcb) and dirty bits (BWext, bwwes) up at the
  controller's addr_wc, block RAM with one clock. SDRAMC drives addr_wc <= curaddr and addr_rc <=
  curaddr one clock later, so addr_wc runs one word ahead during reads too. x68_hrmem moved
  addr_wc only during writes: during a fill it stayed where the last write-back had left it, and
  if that word was dirty, every word of the fill became that word.
- Fix: x68_hrmem sets wc to bgnaddr at a read and steps it with every de word (addr_wc = the
  next word's column). tb/hrmem checks it now (de words whose addr_wc one clock before was not
  addr_rc): SDRAMC 0, the old x68_hrmem 284206 (FAIL), the new 0; PASS with seeds 1 and 7 and
  M2M=1. The self-test x68_hrtest could not see it: it makes its write data from addr_wc itself.
- `megax-hr13` = the current tree (all of today's fixes) with X68_HRMEM (REF megax-hr12).
- tb/sim with the cachecont tag change (before the addr_wc fix): SDRAM gvtest 1.2 s, 57 frames
  identical to sd-gv3; HRMEM gvtest with the board's resets, mode 5 at 245 ms, flags 0205, the
  same (blank) frames shifted by the later start.
- `megax-s3` on the board (the user): no HDMI snow, boots from the HDS, the long reset works.
- `megax-hr13` OK, WNS +0.107 ns, WHS +0.025 ns, 35 critical warnings (as hr7..12); the build tree
  has the addr_wc fix. Not loaded yet.
- `megax-hr13` on the board (the user): **boots from the HDS, no snow on HDMI, the long reset
  brings the Shell back** (blue to green). But after any reset, short or long, the X68000 does not
  boot: drive LED steady blue (a read timed out). QMON at the hang: the HyperRAM kept its contents
  (IPL ROM and CGROM words as boot.rom, main RAM's vectors); x68_hrmem timed out 1 read; cachecont
  idle, the 68000 asking for $FF0000's line 7f8000, read block 6 holding that tag without its
  words, so no new fill (the hr7..9 picture, by another way).
- **The cause**: the framework resets the HyperRAM with every core reset (clk_m2m.vhd: hr_rst
  from `qnice_locked and sys_rstn_i and core_rstn_i`, "reset only the core (means the HyperRAM
  needs to be reset, too)"; the controller also pulls the chip's RESET#, contents kept). x68_hrmem's
  hr_clk side dropped the command it was executing on hr_rst; a read so cut never got its words,
  x68_hrmem gave up after 65536 clocks and cachecont kept the half-empty block. At power-on nothing
  is in flight (memcont waits for initdone), so it never showed before.
- Fix (x68_hrmem): on hr_rst a read in H_RREQ/H_RDATA goes back to H_RWAIT with the address and
  count moved past the words already received, and H_RWAIT starts no burst during the reset; it
  resumes after it. A write in flight is still dropped (its remaining words go by their tag; the
  X68000 is reset at the same time).
- tb/hrmem `+hrrst=<n>`: n resets of the HyperRAM side of 30..40 us, 300 us apart, each in a read
  with more bursts to come (so no write is lost and SDRAMC's results still apply); avl_model got a
  reset. 12 resets, seeds 1/3/9/21, model and M2M=1: PASS; the old x68_hrmem: FAIL (model 40 of 40
  reads with a reset lost, M2M 6). (Shorter or denser pulses: the framework controller's 150 us
  start after each reset kept a read waiting past the testbench's limit, not a fault.) With M2M=1 the
  testbench dumps the controller and arbiters when x68_hrmem stays busy.
- tb/sim `--button <ms>,<us>` (new): the core reset and hr_rst together, the HyperRAM model drops
  what is in flight. One run (button at 300 ms for 60 ms, the old x68_hrmem): no read was in flight
  at that moment, the X68000 restarted; it does not reproduce the hang by itself.
- `megax-hr14` = hr13 + this fix (REF megax-hr13).
- `megax-hr14` OK, WNS +0.107 ns, WHS +0.025 ns, 35 critical warnings. Not loaded yet.

## 2026-11-06 Release 0.1.1 (the user: a user's R6 does not boot 0.1)

- 0.1.1 = megax-s3's source (the SDRAM build: cacheext fix, x68_boot long-reset fix, cachecont
  tag change, X68_R3PROBE false) + CORE_VERSION "0.1.1". `megax-s4` (REF megax-s3): Vivado
  segfault in synthesis (incremental); `megax-s5` the same with NO_REF_SYNTH=1.
- `megax-s5` OK, WNS +0.187 ns, WHS +0.022 ns, 19 critical warnings (as s1/s3).

## 2026-11-06 megax-hr14: resets work; HDMI flakes; 16-word bursts

- `megax-hr14` on the board (the user): boots, short and long resets work. Now and then a flake
  of HDMI snow (about one a second on average, irregular), far less than before. Likely ascal's
  input write burst waiting behind a core burst (x68_hrmem's bursts were up to 64 words, ~0.8 us
  with the latency; the arbiter serves ascal first but does not cut a running burst).
- x68_hrmem G_BURST_LOG2 6 -> 4: bursts of at most 16 words (~0.3 us). tb/hrmem: PASS (model and
  M2M=1, with and without +hrrst=12, seeds 1 and 5). `megax-hr15` = hr14 + this (REF megax-hr14).

## 2026-11-06 Release 0.1.1 published

- `megax-s5` on the board (the user): the menu shows MegaX 0.1.1, boots from the HDS, the long
  reset works. `MegaX-0.1.1-R6.bit` = megax-s5 (md5 f3437eaa...), `MegaX-0.1.1-R6.cor` by
  `coretool -B ... --target mega65r6 --bit-name "MegaX X68000" --bit-version 0.1.1` (verify OK),
  in `~/megax-work/release/MegaX-0.1.1`.
- Tag V0.1.1 on MegaX main (the README for 0.1.1). megax-s5 was built from cbc9487; between it and
  the tag only x68_hrmem.vhd changed (16-word bursts), which the SDRAM build does not contain.
  Fork master fast-forwarded to develop 7eda3fd.
- `megax-hr15` OK, WNS +0.107 ns, WHS +0.025 ns, 35 critical warnings (16-word bursts in its tree).
  Not loaded yet.
- `megax-hr15` on the board (the user): **no snow at all**, resets work. But Super Street Fighter
  II is slow and glitchy: at 20 MHz slower than the SDRAM build at 10 MHz.
- Likely cost: cachecont aborts most CPU fills (the 68000 has its word, ~96 % aborted on hr10);
  x68_hrmem honoured the abort only on the clk_ram side (skip counter) while the HyperRAM side read
  the rest of the 128-word fill, now in 8 bursts of 16, ahead of the next fill.
- x68_hrmem: the clk_ram side shows the read it still wants (rd_want: running & 6-bit tag,
  registered, into hr_clk through two registers and taken when two samples agree); the HyperRAM
  side drops a read at a burst boundary once it is no longer wanted (ended, or a later read 1..31
  ahead); read tags 6 bits (at most 15 commands wait in the FIFO), the skip counter is gone, stale
  words go by their tag. tb/hrmem PASS (model and M2M=1, seeds 1/3/9/21, +hrrst=12); M2M seed 1:
  24131 HyperRAM read commands instead of 26220.
- tb/sim with `--hr-hog 300,140` (waitrequest held 140 of every 300 clocks, about ascal's share):
  `hog-base` (hr15's x68_hrmem) against `hog-drop`. `megax-hr16` = the drop (REF megax-hr15,
  NO_REF_SYNTH=1).
- `megax-hr16`: TIMING-FAILED, WNS -0.376 ns, only rd_want -> h_want1 (clk_ram -> hr_clk, the new
  crossing had no constraint). CORE.xdc: set_max_delay -datapath_only 8 to h_want1, as the FIFOs'.
  `megax-hr17` = hr16 + that (REF megax-hr16).
- Probe on hr15 (SSF2 at 20 MHz, window over the 43 s wrap, so only the classes' shares count):
  memory busy ~89 % of the time (GVRAM line reads ~39 %, CPU fills ~49 %), a CPU read 37.9 clk_ram
  cycles on average (SDRAM build, file manager: 3.3), longest 24 us. With 16-word bursts the
  HyperRAM's fixed cost per burst (~20 clocks) is paid for 16 words: a 512-word GVRAM line takes
  ~12 us. The snow limit is ascal's input buffer: two bursts of 128 bytes (i_dpram BLEN*2), one
  fills in 1.84 us in the 768-dot modes.
- `megax-hr17` OK, WNS +0.107 ns, WHS +0.025 ns, 35 critical warnings (the drop and its constraint
  in the tree). Not loaded yet.
- `megax-hr17` on the board (the user): SSF2 at 20 MHz **much faster, the background glitches
  mostly gone**; still a few missing or flashing lines in some background blocks. megax-s5 (0.1.1,
  SDRAM) loaded for comparison.
- `megax-s5` (the user): no slowdown, no missing lines; hr17 "pretty close now". hr17 at 10 MHz:
  the background glitches worse and slower than s5. So the glitches follow the CPU's speed (the
  game updating the background as it is shown, late), not late GVRAM line reads: the remaining gap
  is the CPU's miss cost. The probe (hr15): about one CPU read in ten is a fill.
- Fork: cachecont gets 32 read blocks (8 KB, BRBLOCKS from X68K_top: 32 with EXT_RAMC, 16 as
  before in the SDRAM build); each block is 2 RAMB18 + ~180 LUTs, 143 FFs (+16 BRAM tiles, 37.5
  were free); cachesel's LRU and the tag compares scale with it. Block debug words only for the
  first 24 blocks. `megax-hr18` (REF megax-hr17, NO_REF_SYNTH=1); tb/sim `hr32` (gvtest).
- The user: after a reset the drive LED stays orange (hr builds): x68_hrmem's sticky "busy 13 ms"
  flag, set by every reset now (the HyperRAM's reset holds a read for over 50 ms, as intended
  since the reset fix). mega65.vhd: the drive LED keeps the self-test's blinking results, then
  shows the floppy motor as without X68_HRMEM; the flags stay readable in the debug window. In the
  build after megax-hr18.
- `megax-hr18` OK, WNS +0.083 ns, WHS +0.025 ns, 35 critical warnings; block RAM 343.5 of 365
  tiles (+16, the 16 more blocks). Not loaded yet.
- `megax-hr18` on the board (the user): about hr17's speed, perhaps a little faster; the
  background glitches mostly gone at 20 MHz, a little better at 10 MHz.
