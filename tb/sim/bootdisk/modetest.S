| MegaX: a video mode test boot sector for the X68000 (2HD, 1024 bytes), for phase 4 (the
| exact video oscillators, CORE/vhdl/clk.vhd): steps through the IOCS _CRTMOD modes, ~5 s
| each, and shows the mode, its format and the colour bars of boot.S in the text planes:
|   16 768x512 31 kHz (69.552 MHz, the anchor)   1 512x512 15 kHz   3 256x256 15 kHz (38.864 MHz)
|   0 512x512 31 kHz   2 256x256 31 kHz (69.552 MHz)   19 640x480 31 kHz (50.35 MHz)
|   17 1024x424 24 kHz   18 1024x848 24 kHz interlaced (69.552 MHz)
| Started by the IPL like boot.S (a BRA first).
| GNU as, MIT syntax: m68k-linux-gnu-as -m68000 modetest.S.

	.text
	.globl	entry
entry:
	bras	start			| $60xx: the IPL's boot sector check
	.ascii	"MegaX modetest"
	.even
start:
	lea	modes(%pc),%a5		| a5: the next entry (mode byte, 31-byte text)
next:
	moveq	#0,%d1
	moveb	%a5@,%d1
	bpl	1f
	lea	modes(%pc),%a5		| $FF: from the top again
	moveb	%a5@,%d1
1:	moveq	#0x10,%d0		| IOCS _CRTMOD d1
	trap	#15
	lea	0xe82200,%a0		| text colours: 0 black, 1 white, 2 red, 3 green
	movew	#0x0000,%a0@+
	movew	#0xfffe,%a0@+
	movew	#0x07c0,%a0@+
	movew	#0xf800,%a0@+
	moveb	#15,0xe8e001		| contrast: full
	moveq	#0x1f,%d0		| IOCS _B_CUROFF
	trap	#15
	moveq	#0x23,%d0		| _B_LOCATE 1,1: the mode
	moveq	#1,%d1
	moveq	#1,%d2
	trap	#15
	moveq	#0x21,%d0
	lea	%a5@(1),%a1
	trap	#15
	| colour bars (boot.S) from text line 64 on: plane 0 = $0F0F, plane 1 = $00FF
	movew	#0,0xe8002a
	lea	0xe00000+128*64,%a0
	lea	0xe20000+128*64,%a1
	movew	#64*64-1,%d7
2:	movew	#0x0f0f,%a0@+
	movew	#0x00ff,%a1@+
	dbra	%d7,2b
	movel	#2800000,%d7		| about 5 s at 10 MHz (subq.l 8 + bne 10 clocks)
3:	subql	#1,%d7
	bne	3b
	lea	%a5@(32),%a5
	bra	next

| the modes: the mode byte, then 31 bytes of text (zero-terminated)
modes:
	.byte	16
	.ascii	"16: 768x512 31kHz 69.552"
	.byte	0,0,0,0,0,0,0
	.byte	1
	.ascii	"1: 512x512 15kHz 38.864"
	.byte	0,0,0,0,0,0,0,0
	.byte	3
	.ascii	"3: 256x256 15kHz 38.864"
	.byte	0,0,0,0,0,0,0,0
	.byte	0
	.ascii	"0: 512x512 31kHz 69.552"
	.byte	0,0,0,0,0,0,0,0
	.byte	2
	.ascii	"2: 256x256 31kHz 69.552"
	.byte	0,0,0,0,0,0,0,0
	.byte	19
	.ascii	"19: 640x480 31kHz 50.35"
	.byte	0,0,0,0,0,0,0,0
	.byte	17
	.ascii	"17: 1024x424 24kHz 69.552"
	.byte	0,0,0,0,0,0
	.byte	18
	.ascii	"18: 1024x848 24kHz i 69.55"
	.byte	0,0,0,0,0
	.byte	0xff
	.even
