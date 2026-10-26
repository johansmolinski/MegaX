# MegaX - agent notes

MegaX (the user's name for it, 2026-10-26; GitHub johansmolinski/MegaX,
local checkout `~/git/my/x68000`, SD card folder `/megax`) is a port of the
MiSTer Sharp X68000 core (Puu-san's X68000 core, MiSTer port by the
MiSTer-devel contributors, currently maintained by albconde) to the MEGA65
on the Megamiga fork of MiSTer2MEGA65. The plan and the porting inventory:
`doc/plan.md`, `doc/inventory.md`. The dated engineering log:
`doc/history.md` (one entry per increment: what, why, test numbers, build
names).

## Rules

1. **The MiSTer code lives in the submodule** `CORE/X68000_MiSTerMEGA65`,
   the fork johansmolinski/X68000_MiSTerMEGA65 of
   MiSTer-devel/X68000_MiSTer (remote `upstream` in the submodule), the
   Megamiga pattern (`CORE/Minimig_MiSTerMEGA65` there):
   - branch **MiSTer** mirrors upstream `master`;
   - branch **develop** carries all Xilinx/MEGA65 changes (the superproject
     tracks it, `.gitmodules` `branch = develop`);
   - branch **master** is the released state (= `develop` at each release).
   Every change to an original file has a dated provenance comment
   (`MEGA65 port YYYY-MM-DD: why`) with the original code kept commented
   out, so upstream merges stay readable. MEGA65-only modules (the shell,
   memory adapters, replacements for Altera primitives that are not a 1:1
   swap) live in `CORE/vhdl/` of this repository, not in the fork.
   Upstream merges: `git fetch upstream`, fast-forward `MiSTer`, merge it into
   `develop`, record the upstream hash in `doc/history.md`.
2. **`M2M/` is vendored unchanged** from Megamiga (`doc/m2m-provenance.md`).
   A framework change that cannot be avoided gets an `M2M-UPSTREAM <name>`
   tag at every changed place and an entry in that file.
3. **Push at will** (the user, 2026-10-26: "Everything will be public from
   day 0"): this repository (`origin` = johansmolinski/MegaX) and the fork's
   `develop`. Commit as `Johan Smolinski <johan.smolinski@gmail.com>`, no
   Co-Authored-By trailers (the user's rule in Megamiga and PC10-III).
4. **No Sharp ROMs in the repository or the bitstream.** The IPL ROM and the
   CGROM (MiSTer's `boot.rom`) are Sharp's; the core loads them from the SD
   card at start-up. (Upstream's `releases/` folder carries a `boot.rom`; it
   stays in the submodule's history and is never copied into this
   repository or used to initialise a RAM.)
5. **No licence file** in this repository (the user, 2026-10-26): Puu-san's
   RTL has no licence; a ticket upstream asks for one. Do not add a LICENSE
   or licence headers to our files until the user says so.
6. **Board: MEGA65 R6 only** for now (one `CORE/CORE-R6.xpr`). The main RAM
   (up to 12 MB) has to be in the SDRAM, so R3 is out; R4/R5 projects can be
   derived from Megamiga's later.
7. **Hardware rules from Megamiga apply** (`~/git/pub/AExp/AGENTS.md`):
   .xpr SFType tokens only `VHDL2008`, `SVerilog` or none (anything else
   segfaults Vivado); video into the framework with active-high syncs and
   blanks covering syncs; check the timing summary after every build; build
   incrementally where possible; never stop a running build without asking.
8. **Do not touch Megamiga's main checkout** (`~/git/pub/AExp`): peer sessions
   work in it. Read from it with `git show`/`git archive`.

## Tools and machines

- Vivado 2022.2 here (`source ~/xilinx-env.sh` in the same shell command
  that starts it); the Fedora host (`ssh fedora`) builds and runs long tests,
  as for Megamiga and PC10-III (`tools/remote/rbuild.sh` in PC10-III).
- Simulators: nvc, ghdl, iverilog, Verilator.
- An untouched upstream clone for diffs: `~/git/my/X68000_MiSTer` (remote
  `fork` = the fork).
