| MegaX: a GVRAM test boot sector for the X68000 (2HD, 1024 bytes), for the R3 memory path
| (x68_hrmem.vhd, tb/sim HRMEM=1): the upper half of GVRAM lives in the external RAM, and the
| video reads each line of it into the plane caches before the line is shown.
|
| Started by the IPL like boot.S (a BRA first). IOCS _CRTMOD 12 (512x512, 65536 colours,
| 31 kHz: one page is all 512 KB of GVRAM, both halves), _G_CLR_ON, a pattern over the whole
| page (an arithmetic series of longs, ~0.4 s), a text line; then, forever, every word of
| 256 KB of main RAM ($10000-$4FFFF) incremented in turn: cache misses and write-backs all the
| time while the picture is shown. The frames must stay the same, and be the same with the SDRAM
| and with the HyperRAM (tb/sim prints a checksum per frame).
| GNU as, MIT syntax: m68k-linux-gnu-as -m68000 gvtest.S (tb/sim/Makefile: FD0=gvtest).

	.text
	.globl	entry
entry:
	bras	start			| $60xx: the IPL's boot sector check
	.ascii	"MegaX gvtest"
	.even
start:
	moveq	#0x10,%d0		| IOCS _CRTMOD 12: 512x512, 65536 colours, 31 kHz
	moveq	#12,%d1
	trap	#15
	movel	#0x90,%d0		| IOCS _G_CLR_ON: graphics cleared and shown
	trap	#15
	lea	0xe82200,%a0		| text colours: 0 transparent, 1 white
	movew	#0x0000,%a0@+
	movew	#0xfffe,%a0@+
	moveb	#15,0xe8e001		| contrast: full (the IPL leaves 0)
	moveq	#0x1f,%d0		| IOCS _B_CUROFF
	trap	#15
	| the pattern: long n = n * $2B304F1D + $01234567 (a different word everywhere, both halves)
	lea	0xc00000,%a0
	movel	#0x01234567,%d1
	movel	#0x2b304f1d,%d3
	moveq	#1,%d6			| 2 x 64K longs = 512 KB
1:	movew	#0xffff,%d7
2:	movel	%d1,%a0@+
	addl	%d3,%d1
	dbra	%d7,2b
	dbra	%d6,1b
	moveq	#0x23,%d0		| _B_LOCATE 2,2
	moveq	#2,%d1
	moveq	#2,%d2
	trap	#15
	moveq	#0x21,%d0		| _B_PRINT
	lea	msg(%pc),%a1
	trap	#15
	| main RAM traffic, forever
2:	lea	0x10000,%a0
	movel	#0x20000-1,%d7		| 128K words = 256 KB
3:	addqw	#1,%a0@+
	subql	#1,%d7
	bpl	3b
	bras	2b

msg:	.asciz	"MegaX gvtest: GVRAM 512x512 65536 colours"
	.even
