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
