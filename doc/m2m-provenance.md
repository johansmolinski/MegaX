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
fat32-fastmap on top (branch `megax-fastmap`, see below).

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
- **fat32-fastmap** (2026-11-02; `QNICE/monitor/fat32_library.asm`,
  `QNICE/test_programs/fat32_seek/mutants.py`; the submodule on the branch
  `megax-fastmap` of johansmolinski/QNICE-FPGA, from `78aeaac`): a fast path in
  `FAT32$FILE_MAP_CB`. While the FAT sector of the current cluster is the one in
  the buffer, `_F32_FM_RUN` follows its entries in a tight loop as long as each
  is "current + 1", calling the device's byte read directly instead of
  `READ_DW`/`READ_W`/`READ_B`/`CALL_DEV`; the first entry that does not continue
  the extent (and every error) takes the unchanged general path, the progress
  hook still runs once per 256 clusters. Why: mounting a 2 GB `.HDS` took about
  15 s (half of it the map, half a seek to the end that MegaX now does through
  the map); the map walks every cluster, about 480,000 with 4 KB clusters. Three
  mutants of the fast path added to the mutation tests.
