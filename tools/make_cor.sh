#!/usr/bin/env bash
# MegaX: a .cor file (for a core slot of the MEGA65's flash) from a bitstream, with the MEGA65
# tools' coretool (https://github.com/MEGA65/mega65-tools), as PC10-III's make_release.py does.
#
#   tools/make_cor.sh <mega65_r6.bit> <version> [out.cor]
#
# coretool: on the PATH, or ~/git/pub/mega65-tools/bin/coretool.
set -euo pipefail
bit=$1 ver=$2 out=${3:-MegaX-$2-R6.cor}
tool=$(command -v coretool || echo "$HOME/git/pub/mega65-tools/bin/coretool")
[ -x "$tool" ] || { echo "coretool not found" >&2; exit 1; }
"$tool" --quiet --force --build "$out" --bit "$bit" --target mega65r6 --bit-name MegaX --bit-version "$ver"
"$tool" --no-color --verify "$out" | grep -E "Name|Version|Target|mega65" | head -5
ls -l "$out"
