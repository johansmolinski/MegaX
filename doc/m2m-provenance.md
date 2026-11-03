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
`fat32-fastseek`, at **`78aeaac`**, the commit Megamiga `main` pins (fast
FAT32 seek, extent maps, the FAT32 write layer), plus this core's exception
fat32-fastmap on top (branch `megax-fastmap`, pinned to `724b470`, see below).

Rules:

- Leave `M2M/` as it is. A framework change that cannot be avoided follows
  Megamiga's convention: an `M2M-UPSTREAM <name>` tag at every changed place
  and an entry in this file (section "Framework exceptions" below).
- To update: copy Megamiga's `M2M/` again (tracked files only), move the
  submodule to the commit Megamiga pins, update the two hashes above, and
  rebuild.

## Framework exceptions of this core

- **fat32-fastmap** (2026-11-02; `QNICE/monitor/fat32_library.asm`,
  `QNICE/test_programs/fat32_seek/`; the submodule on the branch `megax-fastmap` of
  johansmolinski/QNICE-FPGA, from `78aeaac`): a fast path in `FAT32$FILE_MAP_CB`. While the
  FAT sector of the current cluster is the one in the buffer, `_F32_FM_RUN` follows its entries
  in a tight loop as long as each is "current + 1", calling the device's byte read directly
  instead of `READ_DW`/`READ_W`/`READ_B`/`CALL_DEV`; the first entry that does not continue the
  extent (and every error) takes the unchanged general path, the progress hook still runs once
  per 256 clusters. Three mutants of the fast path in the mutation tests; `fat32_seek` runs a
  2 GB file with 4 KB clusters (`SPCS=8 BIG_BYTES=1981808640`). Why: mounting a 2 GB `.HDS`
  took about 16 s (half of it this map, half a seek to the end that MegaX now does through the
  map); with both, 4.5 s on the hardware (`megax-zn`).
  Direct buffer reads (2026-11-03; also `QNICE/monitor/sysdef.asm` and `rom/sdcards.asm`): a
  new device handle word `FAT32$DEV_DIRECT` (`FAT32$DEV_STRUCT_SIZE` 0x1B -> 0x1C), cleared by
  `FAT32$MOUNT`, set by `FAT32$MOUNT_SD` and by the Shell's `SDC$MOUNT`. With it the fast path
  calls the device's byte read once per run (it selects the card slot) and then reads the
  entries through `IO$SD_DATA_POS`/`IO$SD_DATA` itself, about 28 instead of about 100
  instructions per entry: the 2 GB `.HDS` mounts in about 2 s (`megax-zo`). The test suite
  runs every case with and without direct reads; `J.BIN` (a chain that jumps 65536 clusters
  ahead) kills the mutants without the high word check.
- **cfg-strings, layout fallback** (2026-11-03; `rom/cfgstr.asm`, `rom/options.asm`; Megamiga's
  cfg-strings code, the fix belongs there too): a settings file written for another menu layout
  stopped the core with "config.vhd: No selected menu group item found within submenu" (seen
  on 2026-11-02 after a detour to an older build). Chain: a build with a SHORTER menu read the
  longer menu's file, took its extra menu bytes (0x00/0x01) as the start of the text, a 0x00
  ended the text at once, so no signature: the defaults, a new signature appended behind the
  old one, saved. The longer menu then read its own old signature first, accepted the bytes
  of the shorter layout, and a radio group ended up with no item selected. Now `CFGS_LOAD`
  skips 0x00/0x01 bytes before the text (the text is printable), and the new `CFGS_GRPCHK`
  checks, before the signature, that every radio group (groups 1..254 without flags) has
  exactly one item selected; if not, the Shell takes the defaults as for a file of another
  signature (keeping the text: the remembered images stay).
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
  waited for words was accepted and lost. Now such a read is taken as in INIT_ST (`cut_read`),
  the write burst ends early (CS high, RECOVERY_ST) and RECOVERY_ST starts the read; a 4-bit
  counter counts the cuts since the configuration. (megax-zi held the read with a
  combinational waitrequest instead: 20 resets fine, but a 73 ps timing failure on the path
  QNICE FIFO - arbiter - controller - arbiter - ascal.) Why: megax-zh (with ascal-avl-reset) still lost every read after some
  resets (HDMI showed only vertical bars: the watchdog restarting ascal on stale lines), so
  something else still cuts write bursts short. `megax-zj` cut 6 write bursts in 20+ resets,
  none of them a black HDMI.
- **ascal-read-watchdog** (2026-11-02; `vhdl/av_pipeline/ascal.vhd`): a read watchdog in
  Scalaire: a whole output frame without a readack, a readdataack or an idle read pipeline
  restarts the read pipeline at the VS (o_state, o_copy, readlev, copylev, fload). Why: while
  the cut bursts (hr-burst-cut) still swallowed reads, READLEV/COPYLEV stayed locked and HDMI
  black until the next reset; kept as a safety net (it fired 15 times in the 20+ resets of
  `megax-zj`). It came with the temporary probe hr-debug (2026-11-02, the HyperRAM arbiter's
  lines, ascal's read state and the watchdog and burst-cut counters in `x68_trace` 0x0C-0x0F),
  which found the cause of the black HDMI and was removed again on 2026-11-03 (`megax-zr`).
