# The simulation (tb/sim)

The whole machine (`x68_system`: the MiSTer core's `X68K_top`, the text VRAM in
block RAM, the clock enables, reset and loader glue) runs under Verilator with a
model of the MEGA65's SDRAM. It is the reference for the port: what the IPL does
here is what the hardware should do.

```sh
cd tb/sim
make                       # obj/sim: ghdl (VHDL -> Verilog), then Verilator
make run MS=200            # 200 ms of machine time, frames in obj/frames/*.ppm
python3 ppm2png.py obj/frames/*.ppm
```

Disks: `make run FD0=boot` mounts the test boot disk (`bootdisk/boot.S`: a 2HD
boot sector of our own that prints through the IPL's IOCS and draws colour bars,
built into a 1232 KB XDF by `bootdisk/mkxdf.py`); `FD0=<image>` mounts any image
(XDF/DIM/HDM by name, else D88); `FD0=<name>` builds and mounts any
`bootdisk/<name>.S` (`memtest`, `modetest`, `vidtest`, `gvtest`: GVRAM in 65536 colours, all
512 KB, then main-RAM traffic forever). The testbench serves MiSTer's hps_io sector
interface (`img_*`, `sd_*` of `x68_system`), the same one the MEGA65 shell will
serve from the SD card.

`BOOTROM=<file>` selects the boot ROM (MiSTer's `boot.rom`: the X68000's IPL and
CGROM, Sharp's; default: the copy in the submodule's `releases/` folder, never
copied into this repository). `ARGS="--turbo"`, `ARGS="--slowload <boot.rom>"`,
`TRACE=1` + `ARGS="--fst x.fst --fst-from <ms>"` as described in `sim_main.cpp`.

The R3 memory path: `make run HRMEM=1 OBJ=obj-hr` builds `x68_system` with `G_HRMEM`
(`x68_hrmem.vhd` in place of the SDRAM controller) and serves its HyperRAM port with a model
in `sim_main.cpp` (read latency 15..29 clocks, gaps, random waitrequest; the boot ROM preloaded
where `x68_hrmem` keeps it); `HOG=<period>,<length>` holds waitrequest `<length>` of every
`<period>` hr_clk clocks, ascal's share of the arbiter. Every run ends with memory timing
statistics (`memory: ...`: per line the time from HCOMP to the end of the GVRAM reads, the
68000's waits for memory); `ARGS="--memlog <ms>"` logs cachecont's commands, and a busy
period of more than 50 us prints the last 32 commands. `--hw-reset <us>` applies the board's
resets instead of the default ones (none before the boot ROM, then the Shell's reset from the end
of the load for `<us>`; mega65.vhd, PREP_START); with `--slowload` instead of the preloaded ROM
it is the board's start-up: `MEM_ARG="--slowload <boot.rom> --hw-reset 2000 --hr-reset 60000"`.
`--hr-reset <us>` holds the HyperRAM side's reset (hr_rst) that long (default 2 us) and starts
the load 1 ms after it: at power-on the M2M reset (the blue power LED) holds hr_rst, the Shell and
QNICE, while the X68000's memory controller and video already run.

## How it is put together

1. **VHDL to Verilog with ghdl's synthesis.** The core is mixed VHDL and
   (System)Verilog with VHDL on top, which no free simulator runs natively.
   `ghdl --synth` turns `x68_system` and every VHDL entity below it into one
   Verilog file; the (System)Verilog modules (fx68k, jt51, IKAOPM, `tvram_ddr`,
   the video modules of #72) stay black boxes there and Verilator compiles their
   sources. The file list is `CORE/sources.txt`, the same one the Vivado project
   uses.
2. **What ghdl needed in the fork** (all in `rtl/mega65/` or with a `MEGA65 port`
   comment): the Quartus RAM wrappers re-done as inferred RAMs
   (`x68k_rams.vhd`), renames of identifiers that VHDL-2008 reserves
   (`legalize.py`: Vivado rejects them too), a missing `when others`, a doubly
   driven port, a port range. Vivado needs all of these as well, except the
   `reg` rename (`legalize.py` explains).
3. **What the simulation adds on top** (tb/sim only):
   - `sdramc_sim.py`: ghdl cannot carry the SDRAM's inout data bus through the
     hierarchy, so the simulation uses a copy of upstream's `SDRAMC.vhd` with the
     chip model instantiated inside it; its write-data register's `'Z'` default
     becomes `'0'` (ghdl's synthesis turned the registered tristate into logic
     that lost assignments: the second word of a write burst repeated the
     first). Three mechanical edits; the controller is upstream's;
   - `sdram_chip.sv`: the IS42S16320 with full-page bursts on the inverted clock,
     timing and refresh checks (8192 refreshes per 64 ms window), statistics at
     the end. **Board delay:** SDRAMC takes the first word of a READ three clocks
     after the command; with an inverted clock a CL2 chip holds it only until
     ~2.5 clocks, so the controller relies on the MiSTer board's clock/data delay.
     The model delays read data by one falling edge (`+sdram_rd_delay=1`, the
     default; 0 makes every read return the next word). The MEGA65 shell must
     place the data the same way;
   - `fix_dups.py`: ghdl 5.0.1 names an instance output's net
     `<instance>_<port>` even when a signal or port of that name exists; the
     script renames those nets (it stops on anything of another shape);
   - a sed step: VHDL extended identifiers (`\VMODE\`) as plain Verilog names;
   - `cachememwn.sv`: `tvram_ddr.sv` instantiates the VHDL `CACHEMEMWN` from
     SystemVerilog, which in ghdl's output only exists under hashed names;
   - `mkbootimg.py`: the boot ROM preloaded into the SDRAM model where the
     core's loader would write it (word address 0x780000, big-endian); the loader
     handshake still runs (without bytes) so the core sees `ldr_done`.
4. **`sim_main.cpp`** drives the three clocks phase-exact (80 MHz, 40 MHz on
   every other 80 MHz edge, the scan clock at the requested X68000 oscillator
   with MiSTer's `x68k_video_clock.sv` handshake), the reset, the loader and the
   RTC, and captures the frames from the scanout.

Tool working directories: the RAM/ROM init files and fx68k's microcode are read
from `../../X68000_MiSTerMEGA65/...`, the path Vivado sees from
`CORE/CORE-R6.runs/synth_1`; ghdl and the simulator therefore run in
`obj/run/sim`, next to the link `obj/X68000_MiSTerMEGA65`.

## Debugging

- `--bus <file> [--bus-from <ms>] [--bus-to <ms>]`: every 68000 bus cycle
  (time, function code, R/W, address, data, strobes); at the end a summary of
  data accesses per 64 KB and the most fetched program addresses (`debug.vlt`
  makes the bus nets readable).
- `+sdram_watch=<lo>:<hi>`: every write and read word of SDRAM model indices
  `{bank, row, column}` in that range.
- `make run TRACE=1 OBJ=obj-trace ARGS="--trace ../../t.vcd --trace-from <ms>
  --trace-to <ms>"`: a VCD of a window; `python3 vcdpeek.py t.vcd <regex>...
  [--from <ms>] [--to <ms>] [--list]` prints the matching signals, one line per
  change (names: `TOP.x68_system.i_core.ram.cachec.ram_state` and so on).
- Runs go to the Fedora host: `tools/remote/rsim.sh start <name> run MS=...`,
  `wait`, `fetch` (log and frames as PNG). One Verilator thread: 0.56 s per
  simulated ms there; four threads on the shared host were 100 times slower.

## The MEGA65 shell's own tests (tb/shell)

ghdl testbenches for the shell entities in `CORE/vhdl`, against stand-ins for Vivado's
UNISIM/XPM primitives (`unisim_stub.vhd`, `xpm_stub.vhd`). Run them on the Fedora host
(each takes seconds to minutes):

- `check.sh`: analyses and elaborates the whole design (`MEGA65_Core` with the machine and
  the M2M packages it uses) in about 8 s: the syntax and type check before a Vivado run.
- `run_keyboard.sh` (`tb_keyboard.vhd`): `keyboard.vhd` against the core's own PS/2 host
  (KBCONV, PS2IF, the MiSTer layout ROMs) and an MFP-style reader: the key codes the X68000
  gets, BREAK, the MEGA layer, typematic repeat. Two simulation-only copies: PS2IF
  (`ps2if_sim.py`: a counter goes below its range once, which wraps harmlessly in the FPGA)
  and KBCONV (`kbconv_sim.py`: `KBWAIT_CMD` gets the FPGA's power-up value 0).
- `run_boot.sh` (`tb_boot.vhd`): `x68_boot.vhd` with x68_system's loader glue and a core
  that acknowledges each byte after 3..40 clocks: every byte at its address, the end
  handshake.
- `run_sd.sh` (`tb_sd.vhd`): `x68_sd.vhd` with an SD host engine-port model and a core model
  speaking hps_io's sector protocol: the mount pulse, the extent-map arithmetic across two
  extents, reads, a write, an LBA beyond the file.

`tb/hrmem/run.sh` (SystemVerilog, Verilator): `x68_hrmem` against the core's own SDRAM controller
(`SDRAMC` with its chip model) and a reference model, the same 4000 random commands of
cachecont's kinds (whole-block and partial reads with wrap, bwidth 7 and 8, writes of 1..256 words
with byte enables, refreshes, aborted reads); every read's words, column addresses and the word
after them must agree; an Avalon HyperRAM model with random waits, gaps and ascal-like stretches;
the HyperRAM side leaves reset 30 us late. `obj/vl/tb +verilator+seed+<n>` reruns another seed.
`M2M=1 tb/hrmem/run.sh`: the Avalon side as on the board instead (`avl_m2m.sv`, `m2m_hr.vhd`):
the framework's arbiter (`avm_arbit_general`, the scaler first) and the HyperRAM controller's
logic (`hyperram_errata`, `hyperram_config`, `hyperram_ctrl`) synthesised by ghdl, the PHY and the
chip modelled at the controller's `hb_*` lines (the clock leaves on `clk_del`: the chip takes the
controller's word of clock t with the clock pulse of clock t+1), a QNICE-like master (single
words) and a scaler-like master (128-word bursts), each checking its own data and reporting a
hang with the arbiter's and the controller's state. Runs on the laptop (Verilator 5.032): the
Fedora host's Verilator 5.046 runs `tb_hrmem` wrongly (all commands writes, no reads checked,
seed 1 hangs in the old mode too), a Verilator difference not looked into.

Vivado problems are narrowed down with out-of-context syntheses (`tools/synth/ooc.tcl`,
`tools/synth/mkwrap.py` for a pass-through wrapper), about a minute each on the host.
