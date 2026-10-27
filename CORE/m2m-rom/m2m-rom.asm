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

; PREP_LOAD_IMAGE: no manual loads exist; OK for anything.
; Input:  R8: file handle, R9: context (CTX_*), R10: menu group
; Output: R8: 0 = OK, else an error code; R9: image type (0) or the error text
PREP_LOAD_IMAGE XOR     R8, R8
                XOR     R9, R9
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
; At most 3 characters (CFG_SIGCHECK's buffer).
CFG_SIG_KEY     .ASCII_W "menu"
CFG_SIG_VAL     .ASCII_W "1"

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
; for this 15-line menu the demand is about 20 + 214 item characters + 1 +
; 4 x 15 + 1 + (1 submenu + 1) x 30 = 356 words; the Shell checks it at boot
; (ERR_FATAL_HEAP1/2). The rest of the heap is the file browser's.
MENU_HEAP_SIZE  .EQU 512

#ifndef RELEASE
HEAP_SIZE       .EQU 0
HEAP            .BLOCK 1
#else
; HEAP + MENU_HEAP_SIZE + HEAP_SIZE must stay below VAR$STACK_START -
; STACK_SIZE (check HEAP and VAR$STACK_START in m2m-rom.lis). PC10-III's
; budget (19296 + its 1280 menu words), less its 412 words of hard disk
; variables that MegaX does not have, rounded down.
HEAP_SIZE       .EQU 20480
HEAP            .BLOCK 1

                .ORG    0xFED0                  ; as Megamiga: the FAT32 write layer's
                                                ; larger device handle (main_vars.asm)
#endif

STACK_SIZE      .EQU    1536
B_STACK_SIZE    .EQU    768

#include "../../M2M/rom/main_vars.asm"
