| MegaX: a memory test boot sector for the X68000 (2HD, 1024 bytes), for the hardware
| bring-up: is the SDRAM read back as written?
|
| Started by the IPL like boot.S (a BRA first). Endless passes; each one
|   - writes 960 KB of main RAM ($10000-$FFFFF) with a pattern that depends on the
|     address and the pass, reads it back and counts the words that differ (the
|     first one: its address, the word read, the word written),
|   - sums the first 256 KB of the CGROM ($F00000-$F3FFFF; the same every pass when the
|     reads are right),
| and prints one line per pass (lines 4..27, then from the top again):
|   P pass  E errors  A first address  G got  W wanted  C CGROM sum  T total errors
| GNU as, MIT syntax: m68k-linux-gnu-as -m68000 memtest.S (tb/sim/Makefile: FD0=memtest).

	.text
	.globl	entry
entry:
	bras	start			| $60xx: the IPL's boot sector check
	.ascii	"MegaX memtest"
	.even
start:
	moveq	#0x10,%d0		| IOCS _CRTMOD 16: 768x512, 16 colours, 31 kHz
	moveq	#16,%d1
	trap	#15
	lea	0xe82200,%a0		| text colours: 0 black, 1 white, 3 green
	movew	#0x0000,%a0@+
	movew	#0xfffe,%a0@+
	movew	#0x07c0,%a0@+
	movew	#0xf800,%a0@+
	moveb	#15,0xe8e001		| contrast: full
	moveq	#0x1f,%d0		| IOCS _B_CUROFF
	trap	#15
	moveq	#0x23,%d0		| _B_LOCATE 4,2: the title
	moveq	#4,%d1
	moveq	#2,%d2
	trap	#15
	moveq	#0x21,%d0
	lea	title(%pc),%a1
	trap	#15

	moveq	#0,%d6			| d6: pass
	moveq	#0,%d5			| d5: total errors
	moveq	#4,%d4			| d4: the output line
pass:
	addq.l	#1,%d6
	movew	%d6,%d3			| d3: the pass's pattern
	mulu	#0x3c5b,%d3
	| write
	lea	0x10000,%a0
	movel	#0x78000-1,%d7		| 480K words = 960 KB, inside the first MB
1:	movew	%a0,%d1
	eorw	%d3,%d1
	movew	%d1,%a0@+
	subql	#1,%d7
	bpl	1b
	| read back
	lea	0x10000,%a0
	movel	#0x78000-1,%d7
	moveq	#0,%d2			| d2: errors in this pass
	suba.l	%a2,%a2			| a2: the first error's address
	moveq	#0,%d0			| d0: got (word) | wanted (word) of the first error
2:	movew	%a0,%d1
	eorw	%d3,%d1
	cmpw	%a0@+,%d1
	beqs	3f
	tstl	%d2
	bnes	4f
	lea	%a0@(-2),%a2
	movew	%a0@(-2),%d0
	swap	%d0
	movew	%d1,%d0
4:	addql	#1,%d2
3:	subql	#1,%d7
	bpl	2b
	addl	%d2,%d5
	| CGROM sum
	lea	0xf00000,%a0
	movel	#0x20000-1,%d7
	moveq	#0,%d1
5:	addw	%a0@+,%d1
	subql	#1,%d7
	bpl	5b
	movel	%d1,%a4			| a4: the sum (hex4 uses d1)
	| the line
	lea	line(%pc),%a1
	movel	%d6,%d7
	lea	%a1@(2),%a3
	bsr	hex4
	movel	%d2,%d7
	lea	%a1@(9),%a3
	bsr	hex8
	movel	%a2,%d7
	lea	%a1@(20),%a3
	bsr	hex8
	movel	%d0,%d7
	swap	%d7
	lea	%a1@(31),%a3
	bsr	hex4
	movel	%d0,%d7
	lea	%a1@(38),%a3
	bsr	hex4
	movel	%a4,%d7
	lea	%a1@(45),%a3
	bsr	hex4
	movel	%d5,%d7
	lea	%a1@(52),%a3
	bsr	hex8
	moveq	#0x23,%d0		| _B_LOCATE 4,d4
	moveq	#4,%d1
	movel	%d4,%d2
	trap	#15
	moveq	#0x21,%d0		| _B_PRINT the line
	lea	line(%pc),%a1
	trap	#15
	addql	#1,%d4
	cmpl	#28,%d4
	blt	pass
	moveq	#4,%d4
	bra	pass

| hex8 / hex4: d7 as 8 / 4 hex digits at a3 (d7, a3 clobbered)
hex8:	swap	%d7
	bsrs	hex4
	swap	%d7
hex4:	moveq	#3,%d1
	movel	%d1,-(%sp)
	movel	%d7,-(%sp)
	rolw	#4,%d7
6:	movew	%d7,%d1
	andw	#15,%d1
	addw	#0x30,%d1
	cmpw	#0x3a,%d1
	blts	7f
	addw	#7,%d1
7:	moveb	%d1,%a3@+
	rolw	#4,%d7
	subql	#1,(4,%sp)
	bpl	6b
	movel	(%sp)+,%d7
	addql	#4,%sp
	rts

title:	.ascii	"MegaX memtest: 960 KB at $10000, CGROM sum"
	.byte	0
line:	.ascii	"P xxxx E xxxxxxxx A xxxxxxxx G xxxx W xxxx C xxxx T xxxxxxxx"
	.byte	0
	.even
