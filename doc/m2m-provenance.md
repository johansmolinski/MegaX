# Provenance of the vendored framework (M2M/)

`M2M/` is the MiSTer2MEGA65 framework as modified by the **Megamiga** project
(johansmolinski/Megamiga, local checkout `~/git/pub/AExp`), copied unchanged
(tracked files only, `git archive`) from its `main` branch at commit
**`4dac552`** (2026-10-21, "doc: PC XT core and A2088 bridgeboard ideas"),
the same commit the PC10-III core (`~/git/my/pc10-iii`) vendors. The base is
M2M V2.0.1 (sy2002 and MJoergen, GPL-3.0) plus Megamiga's framework
exceptions (interlace, core-io-hook, screen-center, osm-hotkey, osm-scale,
raw-joyports, floppy/SDRAM/PMOD/Ethernet pins, osm-deps, live-text,
nested-submenus, rtg-framebuffer, rom-32k, code-banks, cfg-strings, sd-host
with two slots, ...). Each change carries an `M2M-UPSTREAM <name>` tag in the
code; the list with the reasons is in Megamiga's `AGENTS.md`.

`M2M/QNICE` is a git submodule: johansmolinski/QNICE-FPGA, branch
`fat32-fastseek`, pinned to **`78aeaac`**, the commit Megamiga `main` pins
(fast FAT32 seek, extent maps, the FAT32 write layer).

Rules:

- Leave `M2M/` as it is. A framework change that cannot be avoided follows
  Megamiga's convention: an `M2M-UPSTREAM <name>` tag at every changed place
  and an entry in this file (section "Framework exceptions" below).
- To update: copy Megamiga's `M2M/` again (tracked files only), move the
  submodule to the commit Megamiga pins, update the two hashes above, and
  rebuild.

## Framework exceptions of this core

- **ascal-16bpp** (2026-10-27; `vhdl/av_pipeline/digital_pipeline.vhd`,
  `vhdl/av_pipeline/av_pipeline.vhd`): a generic `G_ASCAL_16BPP` (default false
  = the framework's 24bpp) that stores the core's picture in HyperRAM as ascal's
  16bpp 565 format, with RAMSIZE for 2 bytes per pixel; av_pipeline sets it from
  `globals.vhd`'s `ASCAL_16BPP`. Why: the X68000's 768-dot lines at 34.776 MHz
  overran ascal's two-burst input buffer at 24bpp (corrupted bursts in the frame
  buffer, seen as red snow) and loaded the HyperRAM so much that at 720p60 the
  scaler lost the top of the frame every few seconds (`doc/history.md`,
  2026-10-27).
- **ascal-avl-reset** (2026-11-02; `vhdl/av_pipeline/ascal.vhd`, `digital_pipeline.vhd`): ascal's
  Avalon side gets its own reset input `reset_avl_na` (default '1'), driven with `not hr_rst_i`;
  the input and output sides keep `reset_na` (video_rst or hr_rst). Why: in MegaX `video_rst`
  comes without the HyperRAM reset (core resets, the X68000's video clock reprogrammed per
  mode). A reset in the middle of an ascal write burst cut the burst short; the HyperRAM
  controller waited for the missing words, every later burst was shifted and every read arrived
  while the controller was still in a write burst and was swallowed (the arbiter saw it
  accepted). HDMI stayed black (OSD and VGA fine) until the next reset, QNICE's HyperRAM reads
  hung. Found with the hr-debug probe (megax-zf, megax-zg).
- **hr-burst-cut** (2026-11-02; `vhdl/controllers/hyperram/hyperram_ctrl.vhd`): in
  WRITE_BURST_ST the controller had no waitrequest, so a read arriving while a write burst still
  waited for words was accepted and lost. Now such a read is held (combinational waitrequest),
  the write burst ends early (CS high, RECOVERY_ST) and the read follows; a 4-bit counter
  counts the cuts. Why: megax-zh (with ascal-avl-reset) still lost every read after some
  resets (HDMI showed only vertical bars: the watchdog restarting ascal on stale lines), so
  something else still cuts write bursts short. Temporarily `count_short_o` bits 31..16 carry
  the state, the missing burst words and the cut counter for hr-debug.
- **hr-debug** (2026-11-02, temporary; `vhdl/framework.vhd`, `vhdl/top_mega65-r6.vhd`): a
  64-bit debug word out of the framework (`hr_dbg_o`, hr_clk domain): the HyperRAM arbiter's
  request/acknowledge lines towards the controller, the scaler and QNICE, `hr_rst`, counters of
  accepted commands, delivered read words and QNICE's accepted commands, the burst count; shown
  by `x68_trace.vhd` (registers 0x0C-0x0F, `tools/trace.py --status`). Why: about every other
  reset HDMI stays black and every HyperRAM access hangs (QNICE's too); to see who waits for
  whom. To be removed with the fix. Megax-zf showed the controller healthy: the scaler kept
  writing 64-word bursts but never read again (256 read words since the load), on the first
  load too. Since megax-zg also `vhdl/av_pipeline/ascal.vhd` (port `o_dbg`, a read watchdog
  in Scalaire: a whole output frame without a readack, a readdataack or an idle read pipeline
  restarts the pipeline at the VS), `digital_pipeline.vhd` and `av_pipeline.vhd` (`ascal_dbg_o`);
  bits 63..48 of the word are now ascal's state and the watchdog counter. The watchdog may stay
  as the fix (then as its own tag) if it proves to be one.
