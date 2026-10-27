| MegaX: a video test boot sector for the X68000 (2HD, 1024 bytes), for the hardware
| bring-up: where does the "red snow" come from?
|
| Started by the IPL like boot.S (a BRA first). Draws the text line and the colour bars of
| boot.S, prints the video control register R2 ($E82600: bit 6 sprites, 5 text, 4..0
| graphics planes) as found and after _CRTMOD (on the hardware both $0020: graphics off),
| then every ~3 s switches text colour 3 (the printed text) between green and blue and says
| so on line 6. Hardware findings so far (megax-p/s): the snow is HDMI only (VGA clean), stays
| red when text colour 2 is made blue, the scaler's frame buffer in HyperRAM reads back clean.
| A pixel read one byte off in the scaler's 24 bpp layout turns green (0,G,0) into red (G,0,0)
| and blue (0,0,B) into green (0,B,0): with blue text such snow turns green.
| GNU as, MIT syntax: m68k-linux-gnu-as -m68000 vidtest.S.

	.text
	.globl	entry
entry:
	bras	start			| $60xx: the IPL's boot sector check
	.ascii	"MegaX vidtest"
	.even
start:
	movew	0xe82600,%d6		| d6: R2 as the IPL left it (before _CRTMOD)
	moveq	#0x10,%d0		| IOCS _CRTMOD 16
	moveq	#16,%d1
	trap	#15
	movew	0xe82600,%d5		| d5: R2 after _CRTMOD
	lea	0xe82200,%a0		| text colours: 0 black, 1 white, 2 red, 3 green
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
	| R2 before / after _CRTMOD, line 4
	lea	line(%pc),%a1
	movel	%d6,%d7
	lea	%a1@(9),%a3
	bsr	hex4
	movel	%d5,%d7
	lea	%a1@(28),%a3
	bsr	hex4
	moveq	#0x23,%d0
	moveq	#4,%d1
	moveq	#4,%d2
	trap	#15
	moveq	#0x21,%d0
	lea	line(%pc),%a1
	trap	#15
	| colour bars as in boot.S
	movew	#0,0xe8002a
	lea	0xe00000+128*400,%a0
	lea	0xe20000+128*400,%a1
	movew	#64*64-1,%d7
1:	movew	#0x0f0f,%a0@+
	movew	#0x00ff,%a1@+
	dbra	%d7,1b

toggle:
	movew	#0x003e,0xe82206	| colour 3 blue
	lea	off(%pc),%a4
	bsr	say
	bsr	wait
	movew	#0xf800,0xe82206	| colour 3 green
	lea	on(%pc),%a4
	bsr	say
	bsr	wait
	bra	toggle

say:	moveq	#0x23,%d0		| _B_LOCATE 4,6
	moveq	#4,%d1
	moveq	#6,%d2
	trap	#15
	moveq	#0x21,%d0
	movel	%a4,%a1
	trap	#15
	rts

wait:	movel	#1700000,%d7		| about 3 s at 10 MHz (subq.l 8 + bne 10 clocks)
2:	subql	#1,%d7
	bne	2b
	rts

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

title:	.ascii	"MegaX vidtest: text green / blue every 3 s"
	.byte	0
line:	.ascii	"R2 found xxxx, after CRTMOD xxxx"
	.byte	0
off:	.ascii	"text BLUE "
	.byte	0
on:	.ascii	"text GREEN"
	.byte	0
	.even
