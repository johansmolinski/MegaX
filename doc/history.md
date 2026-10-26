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
