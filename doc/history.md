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
