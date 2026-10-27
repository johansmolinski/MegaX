# MegaX - the plan

Status: 2026-10-27, phase 1 done (the IPL boots a disk in simulation and
draws), phase 2 (the MEGA65 shell) built, waiting for the first hardware test.
The facts behind this plan, with file:line references into the MiSTer core, are
in `doc/inventory.md`; what happened, in `doc/history.md`.

## 1. Starting point

- **Source:** MiSTer-devel/X68000_MiSTer `bb4368b` (2026-10-10, #72), in the
  submodule `CORE/X68000_MiSTerMEGA65` (fork, branch `develop`). Puu-san's
  X68000 core (VHDL, `rtl/X68K_top.vhd` and below) with fx68k, jt51/IKAOPM,
  a D88 bit-level and an XDF/DIM/HDM sector-level floppy emulator, SASI and
  SxSI hard disks, and since #72 a native-clock CRTC scanout.
- **Framework:** Megamiga's M2M (`M2M/`, `doc/m2m-provenance.md`), the same
  one PC10-III uses: two SD slots, the SD host engine port (native 4-bit,
  hardware sector transfers), FAT32 extent maps, settings-file text, code
  banks, nested submenus.
- **Board:** MEGA65 R6 (XC7A200T-2, 365 RAMB36, 64 MB SDRAM IS42S16320,
  8 MB HyperRAM).

## 2. Architecture decisions

### 2.1 Clocks

MiSTer runs the core at 80 MHz (`clk_ram`: SDRAM, cache controller, video
render) and 40 MHz (`clk_sys`: 68000 via clock enables at 10/20 MHz, all
peripherals), plus a run-time retuned video PLL for the X68000's four
oscillators (69.552, 38.864, 50.35 MHz and 75.249 MHz for "60 fps").

- Phase 2 (done that way, `CORE/vhdl/clk.vhd`): one MMCM for 80/40 MHz (CL2
  SDRAM with an ODDR-forwarded clock at 180 degrees, as on MiSTer) and **one
  fixed video clock at the 31 kHz oscillator, 69.552 MHz**. The core asks for
  its oscillator (`scan_req`); `main.vhd` grants it only for the 31 kHz modes
  (IPL, Human68k's 768x512), the others stay dark until phase 4. (The first
  idea, the pre-#72 fractional pixel enable in `mister_sync.sv`, would have
  needed a change to #72's CRTC.)
- Phase 4: exact oscillators: a second MMCM reprogrammed through its DRP
  (all four have fits within 7 ppm from a 100 MHz reference, inventory 6),
  or four outputs and a glitch-free BUFGMUX. M2M's video pipeline then sees a
  mode-dependent `video_clk`, which ascal tolerates (it re-syncs per frame);
  the analog scandoubler path needs checking for 24/31 kHz modes.

### 2.2 Memory

| What | MiSTer | MEGA65 (proposal) |
|---|---|---|
| Main RAM 12 MB, CGROM/IPL 1 MB, GVRAM upper 256 KB, D88/SASI caches | SDRAM 80 MHz | SDRAM, same controller (`SDRAMC`/`cachecont`), 80 MHz first |
| GVRAM lower 256 KB | block RAM (64 tiles) | block RAM |
| TVRAM 512 KB | DDR3 (`tvram_ddr.sv`) | **block RAM** (128 tiles), see below |
| Everything else (PCG, BG, palettes, SRAM, buffers) | block RAM | block RAM / LUTRAM |

**TVRAM** is the one real design choice (inventory section 3):

- **Block RAM (the user's choice, if it fits):** a drop-in `tvram_bram` with
  `tvram_ddr`'s port list: port A CPU (byte/plane masks, RMW in one cycle)
  and raster copy, port B the 4-plane video fetch. Deterministic, no
  arbitration, simplest to verify against the original. Cost: 128 tiles,
  total about 294-321 of 365 (estimate), before trimming (the core's line
  doubler is 3 tiles, the 40 tiny two-write-port cache RAMs cost 20 tiles
  and could be repacked into about 3).
- **SDRAM (fallback):** the pre-#68 path is still in `memcont`/`cachecont`
  (the `t0`/`t1` ports and the raster-copy path, tied off in
  `X68K_top.vhd:3224-3280`). Upstream ran everything in SDRAM at 120 MHz
  before #52; Megamiga runs the same chip at 113.5 MHz. Needs a bandwidth
  check.
- **HyperRAM:** not proposed. Shared with ascal, 15-20 clocks per single
  access; the CPU path and raster copy would need a redesign.

The SDRAM refresh is counted per operation, not timed; check it against the
IS42S16320's 8192 rows / 64 ms before the first hardware run (simulation
with a timing-checking SDRAM model).

### 2.3 Storage (what hps_io did)

| MiSTer | MEGA65 |
|---|---|
| `boot.rom` (1 MB: CGROM 768 KB, 128 KB zero, IPL 128 KB) via ioctl into SDRAM before reset release | QNICE auto-load ROM `/megax/boot.rom`, streamed through the core's existing `ldr_*` port (the CPU stays in reset until `ldr_done`) |
| FDD0/1: D88 (bit-level emulator, image cached in SDRAM), XDF/DIM/HDM (sector-level) via `sd_*` | sector service in hardware from the SD card through the engine port and the file's extent map, PC10-III's `pc_fdd_sd.vhd` pattern (Megamiga `adf_sd.vhd`); XDF first, D88 second |
| SASI HDF, SxSI HDS x4 (GB images) | the same sector service (Megamiga's `ide_engine` / PC10-III's hard disk C:) |
| SRAM image (16 KB, default `boot3.vhd`) | load at start, write back on change (settings-file path, Megamiga's cfg strings) |
| RTC (`sysrtc`, 65 bits) | M2M's `main_rtc_i` (same format) |
| PS/2 keyboard -> `KBCONV` (tables `ktbln_m`/`ktble0_m`) | phase 2: MEGA65 matrix -> PS/2 set 2 -> a PS/2 keyboard device in the shell (`keyboard.vhd`) -> `KBCONV` with the MiSTer layout, unchanged (the MEGA key is the Windows key of KBCONV's combos) |
| PS/2 mouse -> `MOUSECONV` | DB9 Amiga/1351 mouse -> X68000 mouse packets (later) |
| joysticks (USB, 7 pad types) | two DB9 ports: 2-button first; MD/6-button/CyberStick need real pads on the strobe line (later) |
| MIDI on UART, MT32-pi on USER_IO | PMOD (later, optional) |

M2M's buffered `vdrives` is not used for disks: it runs on the QNICE clock,
has 32-bit sizes and a whole-image model that does not fit hard disks.

### 2.4 Altera to Xilinx

- The ~20 MegaWizard `altsyncram` wrappers (Altera licence, inventory 6) are
  replaced **in the fork, under the same entity names and ports**, by
  inferred VHDL RAMs (one generic template per shape: TDP/SDP, mixed width,
  byte enables, unregistered outputs as the originals). The rest of the
  core stays untouched; upstream merges stay easy.
- `altera_pll`, `pll_cfg`, `altddio_out`: not ported; the MEGA65 top
  (`CORE/vhdl/`) has its own MMCMs and ODDR.
- MIF/HEX init files: converted by a script to a format Vivado reads.
- Attributes: `ramstyle` -> `ram_style`, `altera_attribute` synchronizer ->
  `ASYNC_REG`.
- `X68000.sv` (the MiSTer top) is not used; its glue (clock enables, mount
  logic, joystick types, audio mix) moves into `CORE/vhdl/main.vhd`.
- `X68000.sdc` multicycles (fx68k, DMAC, 80/40 MHz pairs) move to
  `CORE/CORE.xdc`.

## 3. Phases

0. **Bootstrap** (done 2026-10-26): repository, fork, M2M, inventory, this
   plan.
1. **Simulation baseline.** The core under Verilator (or ghdl + iverilog):
   `X68K_top` with the Xilinx RAM templates, a timing-checking SDRAM model,
   TVRAM in BRAM, a fake loader that writes `boot.rom` through `ldr_*`.
   Goal: the IPL runs and draws its first screen (frame dump to PNG). This is
   the reference for every later step and catches the Altera-to-Xilinx RAM
   semantics (read-during-write, unregistered outputs) early.
2. **MEGA65 shell, first light** (built 2026-10-27, hardware test next).
   `CORE/vhdl` (clk, mega65, main, config, globals, keyboard, x68_boot),
   firmware, `CORE-R6.xpr`, build scripts (from PC10-III). Fixed video clock.
   Goal: the IPL's "insert a disk" screen on HDMI, keyboard working.
3. **Disks.** XDF/DIM/HDM floppies through the SD sector service, then D88,
   SRAM persistence, SASI/SxSI hard disks. Goal: Human68k boots from floppy
   and from a hard disk image.
4. **Exact video clocks** and the 15/24/31 kHz modes through ascal and the
   analog output.
5. **Input and extras:** mouse, joystick types, turbo, OPM choice, MIDI on
   PMOD, menu polish, release packaging.

## 4. Decisions and open questions

1. **Licence** (the user, 2026-10-26): no licence file in this repository
   for now; a ticket upstream asks for one. Puu-san's RTL has no licence file
   or headers; the only statement is `Doc/readme.txt` ("this RTL is free
   software", copyright kept by Puu, no warranty). IKAOPM, `xe1ap.v` and
   `mister_sync.sv` carry no licence text; fx68k and jt51 are GPL-3+, the top
   GPL-2+. Revisit when the upstream ticket is answered.
2. **TVRAM in block RAM** if it fits (the user, 2026-10-26); otherwise the
   SDRAM fallback of section 2.2.
3. **Name and SD card folder** (the user, 2026-10-26): the core is **MegaX**;
   its files (`boot.rom`, disk images, settings file) live in `/megax`.
