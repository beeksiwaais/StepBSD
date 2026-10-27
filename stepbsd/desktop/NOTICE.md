# Licences of the StepBSD desktop components

`StepBSD-desktop` is built from the sources pinned in `sources.lock`. Each
keeps its own licence; this table was checked against the licence files and
headers in each pinned archive. The patches in `patches/` are under the
licence of the component they apply to. The scripts in this directory
(`build-desktop.sh`, `package.sh`) are BSD-2-Clause, like the rest of
StepBSD (`../../LICENSE`).

| Component | Licence | Where it says so |
|---|---|---|
| swift-corelibs-libdispatch | Apache-2.0 | `LICENSE` |
| tools-make (gnustep-make) | GPL-3.0-or-later | `COPYING` |
| libobjc2 | MIT | `COPYING` |
| libs-base (gnustep-base) | LGPL-2.1-or-later (library); GPL for the tools | `COPYING.LIB`, `COPYING`, `COPYINGv3` |
| libs-gui (gnustep-gui) | LGPL-2.1-or-later (library); GPL-3.0 for the tools | `COPYING.LIB`, `COPYING` |
| libs-back (gnustep-back) | LGPL-2.1-or-later (library); GPL-3.0 for the tools | `COPYING.LIB`, `COPYING` |
| libs-av | LGPL-2.1-or-later | source headers (`AVFoundation/AVAsset.h`) |
| gershwin-system | BSD-2-Clause | `LICENSE` |
| gershwin-assets | per asset: Inter (`Fonts/Inter/LICENSE.txt`), URW base 35 (AGPL-3.0 with font exception, `Fonts/URW/LICENSE`), Luxi (Bigelow & Holmes, `Fonts/Luxi/COPYRIGHT.BH`), Nimbus Sans, desktop pictures | files under `Library/Fonts/*/` |
| gershwin-components | BSD-2-Clause | `LICENSE` |
| gershwin-systempreferences | GPL-2.0 | `COPYING` |
| gershwin-workspace | GPL-2.0 | `COPYING` |
| gershwin-eau-theme | LGPL-2.1 | `LICENSE` |
| gershwin-terminal | GPL-2.0 | source headers (`TerminalServices.m`) |
| gershwin-textedit | MIT | `LICENSE` |
| gershwin-windowmanager | MIT | `WindowManager/LICENSE` |
