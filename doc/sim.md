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

`BOOTROM=<file>` selects the boot ROM (MiSTer's `boot.rom`: the X68000's IPL and
CGROM, Sharp's; default: the copy in the submodule's `releases/` folder, never
copied into this repository). `ARGS="--turbo"`, `ARGS="--slowload <boot.rom>"`,
`TRACE=1` + `ARGS="--fst x.fst --fst-from <ms>"` as described in `sim_main.cpp`.

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
