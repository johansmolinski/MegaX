; ****************************************************************************
; MegaX - Sharp X68000 for MEGA65
;
; QNICE firmware (the M2M "Shell" plus the core's callbacks)
;
; The Shell does almost everything: SD cards, the settings file, the menu, and
; the boot ROM: /megax/boot.rom (MiSTer's boot.rom, Sharp's IPL and CGROM; not
; in the bitstream, AGENTS.md rule 4) is a mandatory auto-loaded ROM
; (globals.vhd), so the Shell streams it into the boot ROM device
; (x68_boot.vhd), which hands every byte to the X68000's loader, and goes
; fatal if the file is missing. PREP_START then checks that exactly 1 MB
; arrived, ends the load and waits until the X68000 has taken the last byte;
; the core then lets its 68000 run.
;
; The floppy images: menu lines FDD0 and FDD1 hand the chosen file to
; x68_sd.vhd (PREP_LOAD_IMAGE, FD_SETUP), which serves its sectors to the core
; straight from the SD card.
;
; Callbacks the Megamiga fork's Shell needs on top of the M2M template's:
; HANDLE_CORE_IO (core-io-hook), BROWSE_EXTRA (cfg-strings), CFG_SIGCHECK and
; CFG_SIGSET (the settings file signature); the FAT32 write layer (the Shell
; creates and resizes the settings file with it) is included flat, through
; fat32_wglue.asm, so there are no code banks (QNICE_CODE_BANKS = "").
;
; done by Johan Smolinski in 2026, after PC10-III's m2m-rom.asm (the
; MiSTer2MEGA65 template, sy2002 and MJoergen, and the Megamiga firmware)
; ****************************************************************************

#define RELEASE

; ----------------------------------------------------------------------------
; Firmware: M2M system
; ----------------------------------------------------------------------------

#include "../../M2M/rom/main.asm"
#include "../../M2M/rom/shell.asm"

; ----------------------------------------------------------------------------
; Firmware: Main Code
; ----------------------------------------------------------------------------

START_FIRMWARE  RBRA    START_SHELL, 1

; ----------------------------------------------------------------------------
; Core specific constants
; ----------------------------------------------------------------------------

#include "osm_const.asm"

X68_BOOT_CTRL   .EQU    0x1000                  ; x68_boot.vhd: control window
X68_BOOT_SIZELO .EQU    0x0000                  ; offsets in it
X68_BOOT_SIZEHI .EQU    0x0001
X68_BOOT_END    .EQU    0x0002
X68_BOOT_OVFL   .EQU    0x0003

; ----------------------------------------------------------------------------
; Core specific callback functions: Submenus
;
; SUBMENU_SUMMARY: R8 = 0 = the standard semantics (the selected item of the
; submenu's first group replaces the %s).
; ----------------------------------------------------------------------------

SUBMENU_SUMMARY XOR     R8, R8
                RET

; ----------------------------------------------------------------------------
; Core specific callback functions: File browsing and image mounting (none
; yet: the disks are phase 3)
; ----------------------------------------------------------------------------

; FILTER_FILES: R8 = 0 = show every file
FILTER_FILES    XOR     R8, R8
                RET

; PREP_LOAD_IMAGE: the floppy images of FDD0 and FDD1 (menu lines " FDD0:%s",
; " FDD1:%s", manual ROM loads 0 and 1 into C_DEV_X68_FDD0/1). Nothing is
; loaded: x68_sd.vhd reads and writes the file on the SD card through its
; extent map (FD_SETUP), and the file pointer is left at the end, so the Shell
; only does the CSR handshake. The core is told D88 (the extension .D88) or a
; sector image (XDF, DIM, HDM: anything else), as MiSTer's file type does.
; Input:  R8: file handle, R9: context (CTX_*), R10: menu group; the caller's
;         R2 (this register bank, before INCRB): the file name
; Output: R8: 0 = OK, else an error code; R9: image type (0) or the error text
PREP_LOAD_IMAGE MOVE    R2, R11                 ; R11: the file name (the
                INCRB                           ; caller's bank)
                CMP     CTX_LOAD_ROM, R9
                RBRA    _X68PL_OK, !Z
                XOR     R1, R1                  ; R1: slot 0 = FDD0, 1 = FDD1
                CMP     X68_OPTM_G_FDD0, R10
                RBRA    _X68PL_D, Z
                MOVE    1, R1
                CMP     X68_OPTM_G_FDD1, R10
                RBRA    _X68PL_OK, !Z

_X68PL_D        MOVE    R8, R0                  ; R0: the file handle
                MOVE    R0, R2                  ; at most 8 MB
                ADD     FAT32$FDH_SIZE_HI, R2
                MOVE    @R2, R2
                AND     0xFF80, R2
                RBRA    _X68PL_BIG, !Z

                MOVE    R11, R8                 ; R2: 0 = D88, 4 = sector image
                RSUB    IS_D88, 1               ; (MODE bit 2)
                MOVE    4, R2
                RBRA    _X68PL_SET, !C
                XOR     R2, R2
_X68PL_SET      MOVE    R0, R8                  ; R8: handle, R9: slot,
                MOVE    R1, R9                  ; R10: the MODE bits
                MOVE    R2, R10
                RSUB    FD_SETUP, 1             ; R8: 0, 1 = too fragmented,
                XOR     R9, R9                  ; 2 = FAT32 error
                CMP     0, R8
                RBRA    _X68PL_RET, Z
                MOVE    ERR_FD_FRAG, R9
                CMP     1, R8
                RBRA    _X68PL_RET, Z
                MOVE    ERR_FD_FAT, R9
                RBRA    _X68PL_RET, 1

_X68PL_BIG      MOVE    3, R8
                MOVE    ERR_FD_SIZE, R9
                RBRA    _X68PL_RET, 1

_X68PL_OK       XOR     R8, R8
                XOR     R9, R9
_X68PL_RET      DECRB
                RET

ERR_FD_SIZE     .ASCII_W "Not a floppy image (more than 8 MB)"
ERR_FD_FRAG     .ASCII_W "Image too fragmented (> 127 extents)"
ERR_FD_FAT      .ASCII_W "FAT32 error mapping the image"

; IS_D88: C=1 when the file name R8 ends in ".D88" (any case). Registers
; preserved.
IS_D88          INCRB
                MOVE    R8, R0                  ; R1: the last '.'
                XOR     R1, R1
_ISD88_L        MOVE    @R0, R2
                RBRA    _ISD88_E, Z
                CMP     '.', R2
                RBRA    _ISD88_N, !Z
                MOVE    R0, R1
_ISD88_N        ADD     1, R0
                RBRA    _ISD88_L, 1
_ISD88_E        CMP     0, R1
                RBRA    _ISD88_NO, Z
                MOVE    ISD88_EXT, R3           ; compare "D88" + end
                ADD     1, R1                   ; after the '.'
_ISD88_C        MOVE    @R1++, R2               ; the next name character
                CMP     'a', R2                 ; to upper case
                RBRA    _ISD88_U, N
                CMP     'z', R2
                RBRA    _ISD88_U, !N
                SUB     0x20, R2
_ISD88_U        CMP     @R3++, R2
                RBRA    _ISD88_NO, !Z
                CMP     0, R2
                RBRA    _ISD88_C, !Z
                DECRB
                OR      0x0004, SR              ; C=1
                RET
_ISD88_NO       DECRB
                AND     0xFFFB, SR              ; C=0
                RET

ISD88_EXT       .ASCII_W "D88"

; FD_SEL: point the RAMROM window at one slot's device
; Input: R8: slot 0..1 (FDD0, FDD1), R9: window (FD_REGWIN or FD_MAPWIN);
; registers preserved
FD_SEL          INCRB
                MOVE    FD_DEV_TAB, R0
                ADD     R8, R0
                MOVE    M2M$RAMROM_DEV, R1
                MOVE    @R0, @R1
                MOVE    M2M$RAMROM_4KWIN, R1
                MOVE    R9, @R1
                DECRB
                RET

FD_DEV_TAB      .DW     X68_DEV_FDD0, X68_DEV_FDD1
FD_REGWIN       .EQU    0x0000
FD_MAPWIN       .EQU    0x0001
FD_MODE         .EQU    0x8000                  ; bit 0 on, bit 1 the card in slot 1,
                                                ; bit 2 a sector image (XDF/DIM/HDM)
FD_SECT         .EQU    0x8001                  ; sectors lo, hi; BASE lo, hi; SHIFT
FD_BYTES        .EQU    0x8009                  ; the file size lo, hi
FD_MAP          .EQU    0x8000
FD_MAPW         .EQU    512                     ; map words: 127 extents

; FD_SETUP: hand an image file to x68_sd.vhd (PC10-III's, after Megamiga's
; ADF_TB_SETUP): the extent map, the number of sectors (rounded up), the block
; of cluster 0 (DEV_CLUSTER - (2 << shift)), the cluster size, the file size
; and the card; the mode goes last (it mounts the image in the core). The
; handle is moved to the end of the file.
; Input:  R8: file handle, R9: slot 0..1, R10: MODE bits besides on and card
;         (bit 2: a sector image)
; Output: R8: 0 = OK, 1 = more extents than the map holds, 2 = FAT32 error;
;         R9 clobbered, R10..R12 preserved (the RAMROM selection is changed)
FD_SETUP        MOVE    R10, @--SP
                MOVE    R11, @--SP
                MOVE    R12, @--SP
                INCRB
                MOVE    R8, R0                  ; R0: handle
                MOVE    R9, R1                  ; R1: slot
                MOVE    R10, R6                 ; R6: the MODE bits

                MOVE    R1, R8                  ; the extent map
                MOVE    FD_MAPWIN, R9
                RSUB    FD_SEL, 1
                MOVE    R0, R8
                MOVE    FD_MAP, R9
                MOVE    FD_MAPW, R10
                RSUB    FAT32$FILE_MAP, 1
                MOVE    1, R7                   ; R7: the result
                CMP     FAT32$ERR_MAPSIZE, R9
                RBRA    _FDSU_RET, Z
                MOVE    2, R7
                CMP     0, R9
                RBRA    _FDSU_RET, !Z

                MOVE    R1, R8                  ; the registers
                MOVE    FD_REGWIN, R9
                RSUB    FD_SEL, 1

                MOVE    R0, R2                  ; the size in bytes
                ADD     FAT32$FDH_SIZE_LO, R2
                MOVE    @R2, R2
                MOVE    R0, R3
                ADD     FAT32$FDH_SIZE_HI, R3
                MOVE    @R3, R3
                MOVE    FD_BYTES, R4
                MOVE    R2, @R4++
                MOVE    R3, @R4
                ADD     511, R2                 ; sectors = (size + 511) >> 9
                ADDC    0, R3
                AND     0xFFFB, SR
                SHR     9, R2
                MOVE    R3, R4
                AND     0xFFFD, SR
                SHL     7, R4
                OR      R4, R2                  ; R2: sectors lo
                AND     0xFFFB, SR
                SHR     9, R3                   ; R3: sectors hi
                MOVE    FD_SECT, R4
                MOVE    R2, @R4++
                MOVE    R3, @R4++               ; R4: BASE

                MOVE    @R0, R2                 ; R2: device handle
                MOVE    R2, R3                  ; (FAT32$FDH_DEVICE = 0)
                ADD     FAT32$DEV_SECT_PER_CLUS, R3
                MOVE    @R3, R3                 ; R3: sectors per cluster
                XOR     R5, R5                  ; R5: shift
_FDSU_SH        CMP     R3, 1
                RBRA    _FDSU_SHD, !N           ; R3 <= 1: done
                AND     0xFFFB, SR
                SHR     1, R3
                ADD     1, R5
                RBRA    _FDSU_SH, 1
_FDSU_SHD       MOVE    2, R7                   ; base = DEV_CLUSTER - (2 << shift)
                AND     0xFFFD, SR
                SHL     R5, R7
                MOVE    R2, R3
                ADD     FAT32$DEV_CLUSTER_LO, R3
                MOVE    @R3++, R11              ; R12:R11: DEV_CLUSTER
                MOVE    @R3, R12
                SUB     R7, R11
                SUBC    0, R12
                MOVE    R11, @R4++              ; base lo, hi, shift
                MOVE    R12, @R4++
                MOVE    R5, @R4

                MOVE    R2, R8                  ; the card (M2M-UPSTREAM sd-host:
                RSUB    SDC$SLOT, 1             ; the engine port's controller)
                OR      1, R6                   ; on
                CMP     0, R8
                RBRA    _FDSU_S0, Z
                OR      2, R6                   ; slot 1
_FDSU_S0        MOVE    FD_MODE, R3             ; mode last: the mount
                MOVE    R6, @R3

                MOVE    R0, R8                  ; the handle to the end
                MOVE    R0, R9
                ADD     FAT32$FDH_SIZE_LO, R9
                MOVE    @R9, R9
                MOVE    R0, R10
                ADD     FAT32$FDH_SIZE_HI, R10
                MOVE    @R10, R10
                SYSCALL(f32_fseek, 1)
                MOVE    2, R7
                CMP     0, R9
                RBRA    _FDSU_RET, !Z
                XOR     R7, R7
_FDSU_RET       MOVE    R7, R8
                DECRB
                MOVE    @SP++, R12
                MOVE    @SP++, R11
                MOVE    @SP++, R10
                RET

; BROWSE_EXTRA (M2M-UPSTREAM cfg-strings): no browser entries that are no
; files. Output R8 = 0; R10..R12 preserved.
BROWSE_EXTRA    XOR     R8, R8
                RET

; ----------------------------------------------------------------------------
; Core specific callback functions: Core startup
;
; PREP_START is called after the ROMs were auto-loaded and before the Shell
; releases the core's reset. The boot ROM went to the X68000 byte by byte
; while the Shell loaded it; check that it is exactly 1 MB (0x100000 bytes),
; end the load and wait (up to a few seconds) until the X68000 has it all.
;
; Output: R8: 0 = OK, else pointer to the error message (fatal)
;         R9: 0 = OK, else error code
; ----------------------------------------------------------------------------

PREP_START      INCRB
                MOVE    M2M$RAMROM_DEV, R0
                MOVE    X68_DEV_BOOT, @R0
                MOVE    M2M$RAMROM_4KWIN, R0
                MOVE    X68_BOOT_CTRL, @R0
                MOVE    M2M$RAMROM_DATA, R1     ; R1: the control registers

                MOVE    R1, R2                  ; more than 1 MB?
                ADD     X68_BOOT_OVFL, R2
                MOVE    @R2, R3
                AND     1, R3
                RBRA    _X68PS_SIZE, !Z
                MOVE    R1, R2                  ; exactly 0x10_0000 bytes?
                ADD     X68_BOOT_SIZEHI, R2
                CMP     0x0010, @R2
                RBRA    _X68PS_SIZE, !Z
                MOVE    R1, R2
                ADD     X68_BOOT_SIZELO, R2
                CMP     0, @R2
                RBRA    _X68PS_SIZE, !Z

                MOVE    R1, R2                  ; end the load
                ADD     X68_BOOT_END, R2
                MOVE    1, @R2
                MOVE    0x0040, R4              ; and wait for its end (bit 1),
_X68PS_W1       XOR     R3, R3                  ; 64 x 65536 polls (several s)
_X68PS_W2       MOVE    @R2, R5
                AND     2, R5
                RBRA    _X68PS_OK, !Z
                SUB     1, R3
                RBRA    _X68PS_W2, !Z
                SUB     1, R4
                RBRA    _X68PS_W1, !Z
                MOVE    ERR_BOOT_TAKE, R8
                MOVE    2, R9
                RBRA    _X68PS_RET, 1

_X68PS_OK       XOR     R8, R8
                XOR     R9, R9
                RBRA    _X68PS_RET, 1

_X68PS_SIZE     MOVE    ERR_BOOT_SIZE, R8
                MOVE    1, R9

_X68PS_RET      DECRB
                RET

ERR_BOOT_SIZE   .ASCII_W "/megax/boot.rom must be 1 MB (MiSTer's boot.rom)"
ERR_BOOT_TAKE   .ASCII_W "The X68000 did not take /megax/boot.rom"

; ----------------------------------------------------------------------------
; Core specific callback functions: OSM selections
;
; OSM_SEL_PRE / OSM_SEL_POST: R8 = the selected group, R9 = the selected item
; (single-select: 1 = selected), R10 = the key. Output R8/R9: 0 = OK.
;
; "Reset the X68000" is momentary: OSM_SEL_POST resets the core through the
; CSR and unselects the item again (M2M$FORCE_MENU), like Megamiga's reload
; item.
; ----------------------------------------------------------------------------

OSM_SEL_PRE     XOR     R8, R8
                XOR     R9, R9
                RET

OSM_SEL_POST    INCRB
                CMP     X68_OPTM_G_RESET, R8
                RBRA    _X68OSP_RET, !Z

                MOVE    M2M$CSR, R0             ; reset the core..
                OR      M2M$CSR_RESET, @R0
                MOVE    0x2000, R1              ; ..for about a millisecond
_X68OSP_WAIT    SUB     1, R1
                RBRA    _X68OSP_WAIT, !Z
                AND     M2M$CSR_UN_RESET, @R0

                MOVE    OPTM_CUR_SEL, R8        ; momentary: unselect again
                MOVE    @R8, R8
                XOR     R9, R9
                RSUB    M2M$FORCE_MENU, 1
                RSUB    OPTM_SHOW, 1
                MOVE    OPTM_CUR_SEL, R8
                MOVE    @R8, R8
                MOVE    OPTM_SEL_SEL, R9
                RSUB    OPTM_SELECT, 1

_X68OSP_RET     XOR     R8, R8
                XOR     R9, R9
                DECRB
                RET

; ----------------------------------------------------------------------------
; Core specific callback functions: Custom messages, background work, the
; settings file
; ----------------------------------------------------------------------------

; CUSTOM_MSG: R8 = 0 = no custom message
CUSTOM_MSG      XOR     R8, R8
                RET

; HANDLE_CORE_IO (M2M-UPSTREAM core-io-hook): the Shell's time slice for
; background work (none yet). Must preserve all registers.
HANDLE_CORE_IO  RET

; CFG_SIGCHECK (M2M-UPSTREAM cfg-strings): C=1 = the settings file R8 (open,
; its text loaded by CFGS_LOAD) belongs to this menu: its text has the line
; "menu=" CFG_SIG_VAL. The file holds one byte per menu line, so a file of
; another layout would set the wrong options (the Shell even loads a shorter
; file, as one from a menu that grew at its end); for C=0 the Shell uses the
; defaults and calls CFG_SIGSET, and the next save writes the file in this
; layout. Registers preserved.
CFG_SIGCHECK    SYSCALL(enter, 1)
                SUB     4, SP                   ; SP: the file's value
                MOVE    CFG_SIG_KEY, R8
                MOVE    SP, R9
                MOVE    4, R10
                RSUB    CFGS_GET, 1
                MOVE    SP, R8
                MOVE    CFG_SIG_VAL, R9
                SYSCALL(strcmp, 1)
                ADD     4, SP
                CMP     0, R10
                RBRA    _CFGSC_OK, Z
                SYSCALL(leave, 1)
                AND     0xFFFB, SR              ; C=0
                RET
_CFGSC_OK       SYSCALL(leave, 1)
                OR      0x0004, SR              ; C=1
                RET

; CFG_SIGSET: a new (or reset) settings file: its text gets this menu's
; signature (CFGS_DIRTY: the next save writes it). Registers preserved.
CFG_SIGSET      SYSCALL(enter, 1)
                MOVE    CFG_SIG_KEY, R8
                MOVE    CFG_SIG_VAL, R9
                RSUB    CFGS_SET, 1
                SYSCALL(leave, 1)
                RET

; The menu's layout version (config.vhd): change it with every change of the
; menu lines. "1": 15 lines (HDMI submenu, 68000 at 20 MHz, help, reset).
; "2": 18 lines, FDD0 and FDD1 at lines 2-3.
; At most 3 characters (CFG_SIGCHECK's buffer).
CFG_SIG_KEY     .ASCII_W "menu"
CFG_SIG_VAL     .ASCII_W "2"

; ----------------------------------------------------------------------------
; The FAT32 write layer, flat (the Shell creates and resizes the settings
; file with it)
; ----------------------------------------------------------------------------

#include "../../M2M/QNICE/monitor/fat32_wglue.asm"
#include "../../M2M/QNICE/monitor/fat32_write.asm"
#include "../../M2M/QNICE/monitor/fat32_wfile.asm"

; ----------------------------------------------------------------------------
; END_OF_ROM must stay the last ROM item (make_rom.sh checks it)
; ----------------------------------------------------------------------------

END_OF_ROM      .DW 0

; ----------------------------------------------------------------------------
; Variables: Need to be located in RAM
; ----------------------------------------------------------------------------

#ifdef RELEASE
                .ORG    0xA000                  ; RAM starts at 0xA000: the 4k device
                                                ; window takes 0x8000-0x8FFF (M2M-UPSTREAM
                                                ; rom-32k), the code window 0x9000-0x9FFF
                                                ; (code-banks; unused here)
#endif

#include "../../M2M/rom/shell_vars.asm"

; The menu heap (Megamiga hard rule 11): the menu structure plus OPTM_HEAP;
; for this 18-line menu the demand is about 20 + 230 item characters + 1 +
; 4 x 18 + 1 + (1 submenu + 2 manual ROMs + 1) x 30 = 444 words; the Shell
; checks it at boot (ERR_FATAL_HEAP1/2). The rest of the heap is the file
; browser's.
MENU_HEAP_SIZE  .EQU 640

#ifndef RELEASE
HEAP_SIZE       .EQU 0
HEAP            .BLOCK 1
#else
; HEAP + MENU_HEAP_SIZE + HEAP_SIZE must stay below VAR$STACK_START -
; STACK_SIZE (check HEAP and VAR$STACK_START in m2m-rom.lis). PC10-III's
; budget (19296 + its 1280 menu words), less its 412 words of hard disk
; variables that MegaX does not have, rounded down.
HEAP_SIZE       .EQU 20352
HEAP            .BLOCK 1

                .ORG    0xFED0                  ; as Megamiga: the FAT32 write layer's
                                                ; larger device handle (main_vars.asm)
#endif

STACK_SIZE      .EQU    1536
B_STACK_SIZE    .EQU    768

#include "../../M2M/rom/main_vars.asm"
