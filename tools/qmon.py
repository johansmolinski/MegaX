#!/usr/bin/env python3
"""MegaX: type commands into the QNICE monitor (QMON, the firmware's debug mode) over the
MEGA65's USB serial link and print what comes back.

  tools/qmon.py [--port /dev/ttyUSB1] [--wait <s>] <keys> [<keys> ...]

--wait: first wait up to <s> seconds for the prompt "QMON>" (enter the debug mode on the
MEGA65 meanwhile: menu closed, hold Run/Stop + Cursor Up, press Help).

Each argument is typed character by character (20 ms apart), then the output is collected
for a moment. QMON commands are two letters and fixed-width hex: "MCFFF40101" = memory change
0xFFF4 := 0x0101, "MD80008012" = memory dump 0x8000..0x8012.
"""
import os, sys, termios, time, select

args = sys.argv[1:]
port = "/dev/ttyUSB1"
wait = 0
while args[:1] in (["--port"], ["--wait"]):
    if args[0] == "--port":
        port = args[1]
    else:
        wait = int(args[1])
    args = args[2:]
fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
a = termios.tcgetattr(fd)
a[0] = 0; a[1] = 0; a[3] = 0
a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
a[4] = a[5] = termios.B115200
termios.tcsetattr(fd, termios.TCSANOW, a)

def drain(t):
    out = b""
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                out += os.read(fd, 4096)
            except BlockingIOError:
                pass
    return out

if wait:
    # wait (at most <wait> s) for the monitor's prompt: nothing is typed before it, since
    # characters sent earlier stay in the UART and start some command
    seen = b""
    end = time.time() + wait
    while time.time() < end and b"QMON>" not in seen:
        seen += drain(0.5)
    sys.stdout.write(seen.decode("latin1").replace("\r", ""))
    if b"QMON>" not in seen:
        sys.exit("no QMON prompt")
else:
    drain(0.3)
for cmd in args:
    for ch in cmd:
        os.write(fd, ch.encode())
        time.sleep(0.02)
    # the reply: until the next prompt (a long dump takes a while), at most 30 s
    got = b""
    end = time.time() + 30
    while time.time() < end and b"QMON>" not in got and not got.rstrip().endswith(b"NEW VALUE="):
        got += drain(0.2)
    sys.stdout.write(got.decode("latin1").replace("\r", ""))
    sys.stdout.flush()
os.close(fd)
