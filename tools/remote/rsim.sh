#!/usr/bin/env bash
# MegaX: run the simulation (tb/sim) on the Fedora host ("ssh fedora"; 16 cores, 62 GB,
# ghdl, Verilator), never on the laptop (the user, 2026-10-26). After PC10-III's
# tools/remote/rbuild.sh. Runs live in fedora:~/megax-work/<name> (log <name>.log, pid
# <name>.pid).
#
#   rsim.sh start <name> [make args ...]   copy this checkout (submodules as files, no
#                                           .git, no tb/sim/obj; rsync via ~/megax-work/.base)
#                                           and run "make -C tb/sim
#                                           <make args>" in the background (default: run)
#   rsim.sh from <run> <name> [make args]   a new run on a copy of <run> (its build and
#                                           checkpoints), sources synced over it
#   rsim.sh status <name>                   RUNNING/FINISHED and the last lines of the log
#   rsim.sh wait <name>                     block until it has exited, print the log's tail
#   rsim.sh fetch <name> [dest]             log + frames (as PNG) to dest
#                                           (default ~/megax-work/runs/<name>)
#   rsim.sh stop <name>                     kill this run (its process group only)
#
# Example: tools/remote/rsim.sh start ipl-a run MS=300
# Other people's jobs run on the host too: never stop anything but our own runs.
set -euo pipefail
# no rsync in this AppVM (root changes vanish): the Debian package unpacked into ~/.local
command -v rsync >/dev/null || PATH=$HOME/.local/opt/rsync/usr/bin:$PATH
H=fedora
B=megax-work
cmd=${1:-}; shift || true
root=$(cd "$(dirname "$0")/../.." && pwd)

case "$cmd" in
start)
    name=$1; shift
    [ $# -gt 0 ] || set -- run
    ssh $H "test ! -e ~/$B/$name" || { echo "fedora:~/$B/$name exists - pick another name" >&2; exit 1; }
    # rsync into a base copy on the host (only changed files travel), then a local
    # copy of it for this run
    rsync -a --delete --exclude='.git' --exclude='/tb/sim/obj*' --exclude='*.runs' \
        --exclude='*.cache' --exclude='*.hw' --exclude='/.claude' --exclude='*.rbf' \
        "$root/" $H:$B/.base/
    ssh $H "cp -a ~/$B/.base ~/$B/$name"
    q=$(printf ' %q' "$@")
    # cd first, so that setsid itself is the background job: its pid is the new
    # session's leader (make), and nothing keeps this ssh session open
    ssh $H "cd ~/$B/$name/tb/sim || exit 1; setsid nohup make$q > ~/$B/$name.log 2>&1 < /dev/null & echo \$! > ~/$B/$name.pid; echo started pid \$(cat ~/$B/$name.pid)"
    ;;
from)
    # a new run on top of an earlier one: its build and checkpoints are reused,
    # make rebuilds only what the current sources changed
    base=$1 name=$2; shift 2
    [ $# -gt 0 ] || set -- run
    ssh $H "test -d ~/$B/$base && test ! -e ~/$B/$name" || { echo "need fedora:~/$B/$base, and no $name yet" >&2; exit 1; }
    ssh $H "cp -a ~/$B/$base ~/$B/$name"
    rsync -a --exclude='.git' --exclude='/tb/sim/obj*' --exclude='*.runs' \
        --exclude='*.cache' --exclude='*.hw' --exclude='/.claude' --exclude='*.rbf' \
        "$root/" $H:$B/$name/
    q=$(printf ' %q' "$@")
    ssh $H "cd ~/$B/$name/tb/sim || exit 1; setsid nohup make$q > ~/$B/$name.log 2>&1 < /dev/null & echo \$! > ~/$B/$name.pid; echo started pid \$(cat ~/$B/$name.pid)"
    ;;
status)
    name=$1
    ssh $H "if kill -0 \$(cat ~/$B/$name.pid) 2>/dev/null; then echo RUNNING; else echo FINISHED; fi; tail -${N:-15} ~/$B/$name.log"
    ;;
wait)
    # polls with short ssh calls (one long ssh session was seen to return early)
    name=$1
    while ssh $H "kill -0 \$(cat ~/$B/$name.pid) 2>/dev/null"; do sleep 30; done
    ssh $H "tail -${N:-25} ~/$B/$name.log"
    ;;
fetch)
    name=$1 dest=${2:-$HOME/megax-work/runs/$name}
    mkdir -p "$dest"
    scp -q "$H:$B/$name.log" "$dest/sim.log"
    ssh $H "cd ~/$B/$name/tb/sim && ls obj/frames/*.ppm >/dev/null 2>&1 && python3 ppm2png.py obj/frames/*.ppm >/dev/null && tar -cf - -C obj/frames \$(cd obj/frames && ls *.png)" \
        | tar -xf - -C "$dest" 2>/dev/null || true
    ls "$dest" | head -40
    ;;
stop)
    name=$1
    # the whole session of the run (make, ghdl/verilator or the simulator)
    ssh $H "p=\$(cat ~/$B/$name.pid); s=\$(ps -o sid= -p \$p | tr -d ' '); if [ -n \"\$s\" ]; then pkill -s \$s && echo stopped; else echo 'not running'; fi"
    ;;
*)
    sed -n '2,20p' "$0"
    exit 1
    ;;
esac
