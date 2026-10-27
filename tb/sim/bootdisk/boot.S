| MegaX simulation: a test boot sector for the X68000 (2HD, 1024 bytes).
|
| The IPL reads the first sector of a bootable floppy to $2000 (IOCS $46) and runs
| it in supervisor mode with its IOCS (trap #15) set up, but only if its first byte
| is $60, a BRA (IPL at FF02BE: cmpi.b #$60,(a1)); otherwise it tries the next
| device. This one starts with a BRA over its name, uses only the IOCS and
| the text VRAM, so a frame shows the whole path - floppy emulator, 68000, CGROM
| font, text VRAM, palette, video - without any copyrighted disk:
|   _CRTMOD 16 (768x512, 16 colours, 31 kHz), text colours 0-4 set (_CRTMOD leaves
|   them all black), cursor off, a line of text at (4,4),
|   then 64 lines of four-colour bars (text colours 0..3) from line 400.
| GNU as, MIT syntax: m68k-linux-gnu-as -m68000 boot.S (tb/sim/Makefile).

	.text
	.globl	entry
entry:
	bras	start			| $60xx: the IPL's boot sector check
	.ascii	"MegaX boot test"
	.even
start:
	moveq	#0x10,%d0		| IOCS _CRTMOD
	moveq	#16,%d1			| mode 16: 768x512, 16 colours, 31 kHz
	trap	#15
	| _CRTMOD leaves the text palette all 0 (black): our own colours,
	| GGGGG RRRRR BBBBB I
	lea	0xe82200,%a0
	movew	#0x0000,%a0@+		| 0 black
	movew	#0xfffe,%a0@+		| 1 white
	movew	#0x07c0,%a0@+		| 2 red
	movew	#0xf800,%a0@+		| 3 green
	movew	#0x003e,%a0@+		| 4 blue
	moveq	#0x1f,%d0		| IOCS _B_CUROFF
	trap	#15
	moveq	#0x23,%d0		| IOCS _B_LOCATE (d1 = x, d2 = y)
	moveq	#4,%d1
	moveq	#4,%d2
	trap	#15
	moveq	#0x21,%d0		| IOCS _B_PRINT (a1 = string)
	lea	msg(%pc),%a1
	trap	#15

	| colour bars: text planes 0 and 1, 128 bytes per line (1024 dots)
	movew	#0,0xe8002a		| CRTC R21: one plane per access
	lea	0xe00000+128*400,%a0	| plane 0, line 400
	lea	0xe20000+128*400,%a1	| plane 1, line 400
	movew	#64*64-1,%d7		| 64 lines x 64 words
1:	movew	#0x0f0f,%a0@+		| plane 0 / plane 1 per pixel: 00 01 10 11
	movew	#0x00ff,%a1@+
	dbra	%d7,1b

2:	bras	2b			| done: leave the picture on screen

msg:	.ascii	"MegaX - X68000 for MEGA65 - boot sector test"
	.byte	0
	.even
