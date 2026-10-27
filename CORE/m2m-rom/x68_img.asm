; ****************************************************************************
; MegaX - Sharp X68000 for MEGA65: the disk images across power-off
;
; The settings file's text (M2M-UPSTREAM cfg-strings, M2M/rom/cfgstr.asm)
; remembers the image of every image line by its path with the card in front
; (M2M-UPSTREAM sd-host, two slots: "SD0:" = the bottom tray, "SD1:" = the
; back slot), one key per line:
;
;   fdd0=SD1:/megax/human68k.xdf
;   sasi=SD0:/megax/hd40.hdf
;
; PREP_LOAD_IMAGE writes the key when an image is mounted (IMG_SAVE; a failed
; mount removes it), the SPACE eject in HANDLE_CORE_IO removes it, and the
; Shell writes the file when the menu closes (ROSM_SAVE: CFGS_DIRTY).
; PREP_START mounts them all again before the X68000 leaves reset
; (IMG_RESTORE) through PREP_LOAD_IMAGE, as the menu does, so the IPL finds
; its disk at once. PC10-III's pc_hdc.asm (one drive) for every image line,
; after Megamiga's machine profiles.
;
; Lives in code bank BANK_IMG; the entry points IMG_SAVE, IMG_RESTORE and
; IMG_PEND_APPLY are FAR_CALL stubs in the fixed ROM (m2m-rom.asm). The texts
; here are in the bank: they are only handed to fixed-ROM routines that do not
; change the bank.
;
; Variables (m2m-rom.asm): IMG_PEND (bit i: image i was restored and the menu
; line has no name yet; while a restore mounts, its key stays), IMG_KEY, IMG_PATH
; (IMG_PLEN words, the last one IMG_PATH_Z), IMG_FDH, IMG_DE.
;
; done by Johan Smolinski in 2026
; ****************************************************************************

IMG_PLEN        .EQU    128                     ; IMG_PATH: at most 127 characters
IMG_N           .EQU    6                       ; image lines

; per image i (= the manual ROM's index, the order of the menu's image lines):
; its key, its menu group, its QNICE device, the Shell's file handle
IMG_KEYS        .DW     IMG_K0, IMG_K1, IMG_K2, IMG_K3, IMG_K4, IMG_K5
IMG_GROUPS      .DW     X68_OPTM_G_FDD0, X68_OPTM_G_FDD1, X68_OPTM_G_SASI
                .DW     X68_OPTM_G_SXSI1, X68_OPTM_G_SXSI2, X68_OPTM_G_SRAMF
IMG_DEVS        .DW     X68_DEV_FDD0, X68_DEV_FDD1, X68_DEV_SASI
                .DW     X68_DEV_SXSI1, X68_DEV_SXSI2, X68_DEV_SRAM
IMG_HANDLES     .DW     HANDLE_RM_FILE1, HANDLE_RM_FILE2, HANDLE_RM_FILE3
                .DW     HANDLE_RM_FILE4, HANDLE_RM_FILE5, HANDLE_RM_FILE6
IMG_BITS        .DW     0x0001, 0x0002, 0x0004, 0x0008, 0x0010, 0x0020

IMG_K0          .ASCII_W "fdd0"
IMG_K1          .ASCII_W "fdd1"
IMG_K2          .ASCII_W "sasi"
IMG_K3          .ASCII_W "sxsi1"
IMG_K4          .ASCII_W "sxsi2"
IMG_K5          .ASCII_W "sram"
IMG_NONE        .DW     0                       ; the empty value removes the key
IMG_UP          .ASCII_W ".."
IMG_S_ERR       .ASCII_W "\nNot mounted again:\n"
IMG_S_NF        .ASCII_W "Not found"

; ----------------------------------------------------------------------------
; _IMG_IDX: R9 = a menu group -> C=1 and R9 = its image index, or C=0.
; Other registers preserved.
; ----------------------------------------------------------------------------

_IMG_IDX        INCRB
                MOVE    IMG_GROUPS, R0
                XOR     R1, R1
_IIX_L          CMP     @R0++, R9
                RBRA    _IIX_F, Z
                ADD     1, R1
                CMP     IMG_N, R1
                RBRA    _IIX_L, !Z
                DECRB
                AND     0xFFFB, SR              ; C=0
                RET
_IIX_F          MOVE    R1, R9
                DECRB
                OR      0x0004, SR              ; C=1
                RET

; ----------------------------------------------------------------------------
; B_IMG_SAVE (IMG_SAVE): R8 = 0: the image line of group R9 was mounted from
; the open file R10 (the Shell opened it from the current directory of its
; card's device handle); else the line is empty. The key follows: the file's
; path, or no key (also if the path cannot be found or is longer than 127
; characters). The names come from directory listings (IMG_FDH, IMG_DE): the
; entry with the file's first cluster in the current directory, then each
; directory by its cluster in its parent (".."), up to the root. The current
; directory is kept, and the sector buffer is nobody's afterwards if IMG_FDH
; had it. While IMG_RESTORE mounts this image (its IMG_PEND bit) the key stays
; as it is. All registers preserved.
; ----------------------------------------------------------------------------

B_IMG_SAVE      SYSCALL(enter, 1)
                RSUB    _IMG_IDX, 1             ; R9: the image
                RBRA    _ISV_RET, !C
                MOVE    IMG_BITS, R3            ; IMG_RESTORE mounts it: the key
                ADD     R9, R3                  ; stays
                MOVE    IMG_PEND, R2
                MOVE    @R2, R2
                AND     @R3, R2
                RBRA    _ISV_RET, !Z
                MOVE    IMG_KEYS, R3            ; IMG_KEY: the key (R8..R12 are
                ADD     R9, R3                  ; the syscalls')
                MOVE    IMG_KEY, R2
                MOVE    @R3, @R2
                MOVE    IMG_NONE, R3            ; R3: the value: none..
                CMP     0, R8
                RBRA    _ISV_SET, !Z            ; (empty)
                MOVE    @R10, R6                ; R6: the device (FDH_DEVICE = 0)
                ADD     FAT32$FDH_START_CLUS_LO, R10
                MOVE    @R10++, R4              ; R5:R4: the cluster to find
                MOVE    @R10, R5
                MOVE    R6, R0                  ; R0: the current directory of
                ADD     FAT32$DEV_AD_1STCLUS_LO, R0 ; the device, R2:R1: the
                MOVE    @R0++, R1               ; one there now (put back at
                MOVE    @R0, R2                 ; the end)
                SUB     1, R0
                MOVE    IMG_PATH_Z, R7          ; R7: the path, from its end
                MOVE    0, @R7

_ISV_DIR        MOVE    R6, R8                  ; the current directory: the
                MOVE    IMG_FDH, R9             ; entry with the cluster
                SYSCALL(f32_od, 1)              ; (hidden ones too)
                CMP     0, R9
                RBRA    _ISV_END, !Z
_ISV_ENT        MOVE    IMG_FDH, R8
                MOVE    IMG_DE, R9
                MOVE    FAT32$FA_ALL, R10
                SYSCALL(f32_ld, 1)
                CMP     0, R11
                RBRA    _ISV_END, !Z
                CMP     0, R10
                RBRA    _ISV_END, Z             ; the end: not there
                MOVE    IMG_DE, R8
                ADD     FAT32$DE_CLUS_LO, R8
                CMP     @R8++, R4
                RBRA    _ISV_ENT, !Z
                CMP     @R8, R5
                RBRA    _ISV_ENT, !Z

                MOVE    IMG_DE, R8              ; "/" and its name in front, if
                SYSCALL(strlen, 1)              ; "SDx:" still fits: R9 + 5
                ADD     5, R9                   ; must not exceed the room
                MOVE    R7, R10
                SUB     IMG_PATH, R10           ; R10: the room
                CMP     R9, R10
                RBRA    _ISV_END, N             ; (R9 > R10)
                SUB     5, R9
                SUB     R9, R7
                MOVE    R9, R10
                MOVE    R7, R9
                SYSCALL(memcpy, 1)              ; (R8: the name)
                MOVE    0x002F, @--R7

                MOVE    R0, R8                  ; R5:R4: this directory, to find
                MOVE    @R8++, R4               ; in its parent; the root (in
                MOVE    @R8, R5                 ; front of it: DEV_RD_1STCLUS):
                SUB     3, R8                   ; done
                CMP     @R8++, R4
                RBRA    _ISV_UP, !Z
                CMP     @R8, R5
                RBRA    _ISV_DONE, Z
_ISV_UP         MOVE    R6, R8                  ; cd .. (to the root for a
                MOVE    IMG_UP, R9              ; cluster 0)
                XOR     R10, R10
                SYSCALL(f32_cd, 1)
                CMP     0, R9
                RBRA    _ISV_DIR, Z
                RBRA    _ISV_END, 1

_ISV_DONE       MOVE    R6, R8                  ; the card in front
                RSUB    SDC$SLOT, 1
                ADD     0x0030, R8
                MOVE    0x003A, @--R7           ; "SDx:"
                MOVE    R8, @--R7
                MOVE    0x0044, @--R7
                MOVE    0x0053, @--R7
                MOVE    R7, R8                  ; to the start of IMG_PATH
                MOVE    IMG_PATH, R9
                MOVE    R9, R3                  ; R3: ..or the path
                SYSCALL(strcpy, 1)
_ISV_END        MOVE    R1, @R0++               ; the current directory back
                MOVE    R2, @R0
                MOVE    R6, R8                  ; the sector buffer: nobody's
                ADD     FAT32$DEV_BUFFERED_FDH, R8 ; if IMG_FDH has it
                CMP     IMG_FDH, @R8
                RBRA    _ISV_SET, !Z
                MOVE    0, @R8
_ISV_SET        MOVE    IMG_KEY, R8
                MOVE    @R8, R8
                MOVE    R3, R9
                RSUB    CFGS_SET, 1
_ISV_RET        SYSCALL(leave, 1)
                RET

; ----------------------------------------------------------------------------
; B_IMG_RESTORE (IMG_RESTORE; PREP_START, the X68000 still in reset): mount
; every image the keys name through PREP_LOAD_IMAGE, as the menu does; the
; menu lines show their names once the menu is opened (IMG_PEND). A path that
; cannot be opened, or an image that PREP_LOAD_IMAGE refuses, leaves the line
; empty: the reason is shown for 5 s and the key is removed. All registers
; preserved; the RAMROM selection changes.
; ----------------------------------------------------------------------------

B_IMG_RESTORE   SYSCALL(enter, 1)
                MOVE    IMG_PEND, R0
                MOVE    0, @R0
                XOR     R4, R4                  ; R4: the image
_IRS_I          MOVE    IMG_BITS, R3            ; pending while it mounts
                ADD     R4, R3
                MOVE    IMG_PEND, R0
                OR      @R3, @R0
                MOVE    IMG_KEYS, R8
                ADD     R4, R8
                MOVE    @R8, R8
                MOVE    IMG_PATH, R9
                MOVE    IMG_PLEN, R10
                RSUB    CFGS_GET, 1
                RBRA    _IRS_NO, !C             ; nothing remembered
                MOVE    IMG_S_NF, R2            ; R2: the reason
                MOVE    R9, R0                  ; "SD0:" or "SD1:"
                CMP     0x0053, @R0++
                RBRA    _IRS_ERR, !Z
                CMP     0x0044, @R0++
                RBRA    _IRS_ERR, !Z
                MOVE    @R0++, R8
                SUB     0x0030, R8
                CMP     R8, 1
                RBRA    _IRS_ERR, N             ; (R8 > 1, also below "0")
                CMP     0x003A, @R0++
                RBRA    _IRS_ERR, !Z
                RSUB    SDC$MOUNT, 1            ; R8: the card's device handle
                CMP     0, R9
                RBRA    _IRS_ERR, !Z
                MOVE    IMG_HANDLES, R9         ; the Shell's handle of the line
                ADD     R4, R9
                MOVE    @R9, R9
                MOVE    R9, R1
                MOVE    R0, R10                 ; the path behind the card
                XOR     R11, R11                ; ("/" separates)
                SYSCALL(f32_fopen, 1)
                CMP     0, R10
                RBRA    _IRS_ERR, !Z
                MOVE    R1, R8                  ; the menu's way (R2: the file
                MOVE    IMG_PATH, R2            ; name, PREP_LOAD_IMAGE's D88
                MOVE    CTX_LOAD_ROM, R9        ; check)
                MOVE    IMG_GROUPS, R10
                ADD     R4, R10
                MOVE    @R10, R10
                RSUB    PREP_LOAD_IMAGE, 1
                MOVE    R9, R2
                CMP     0, R8
                RBRA    _IRS_ERR, !Z
                MOVE    IMG_DEVS, R8            ; the menu line counts as loaded
                ADD     R4, R8                  ; (CRTROM_MLST_GET) and shows
                MOVE    @R8, R8                 ; the name when the menu opens
                MOVE    CRTROM_CSR_STATUS, R9   ; (IMG_PEND)
                MOVE    CRTROM_CSR_ST_OK, R10
                RSUB    CRTROM_CSR_W, 1
                RBRA    _IRS_NEXT, 1

_IRS_ERR        RSUB    FRAME_FULLSCR, 1        ; the reason for 5 s
                RSUB    SCR$OSM_M_ON, 1
                MOVE    IMG_S_ERR, R8
                RSUB    SCR$PRINTSTR, 1
                MOVE    IMG_PATH, R8
                RSUB    SCR$PRINTSTR, 1
                MOVE    NEWLINE, R8
                RSUB    SCR$PRINTSTR, 1
                MOVE    R2, R8
                RSUB    SCR$PRINTSTR, 1
                MOVE    15, R0
_IRS_W          RSUB    WAIT333MS, 1
                SUB     1, R0
                RBRA    _IRS_W, !Z
                RSUB    SCR$OSM_OFF, 1
_IRS_NO         MOVE    IMG_BITS, R3            ; nothing pending, the line is
                ADD     R4, R3                  ; empty: no key
                MOVE    @R3, R3
                NOT     R3, R3
                MOVE    IMG_PEND, R0
                AND     R3, @R0
                MOVE    1, R8
                MOVE    IMG_GROUPS, R9
                ADD     R4, R9
                MOVE    @R9, R9
                RSUB    B_IMG_SAVE, 1
_IRS_NEXT       ADD     1, R4
                CMP     IMG_N, R4
                RBRA    _IRS_I, !Z
                SYSCALL(leave, 1)
                RET

; ----------------------------------------------------------------------------
; B_IMG_PEND_APPLY (IMG_PEND_APPLY, HANDLE_CORE_IO): the names of the images
; IMG_RESTORE mounted for their menu lines, as HANDLE_MOUNTING does after a
; load from the browser: the name behind the last "/" of the path, at most
; OPTM_DX - 1 characters (more than OPTM_DX - 2 give the Shell's ellipsis), in
; the line's buffer of OPTM_HEAP ((vdrives + submenus + image) x OPTM_DX),
; its "%s is replaced" flag 0. OPTM_HEAP exists once the menu has been opened;
; that runs this in the menu's key loop before CRTROM_MLST_GET sees STATUS ok
; and redraws the lines with the names. Cheap while nothing waits. All
; registers preserved.
; ----------------------------------------------------------------------------

B_IMG_PEND_APPLY SYSCALL(enter, 1)
                MOVE    IMG_PEND, R0
                CMP     0, @R0
                RBRA    _IPA_RET, Z             ; nothing waits
                MOVE    OPTM_HEAP, R1
                CMP     0, @R1
                RBRA    _IPA_RET, Z             ; no menu yet
                XOR     R5, R5                  ; R5: the image
_IPA_I          MOVE    IMG_BITS, R6
                ADD     R5, R6
                MOVE    @R6, R6                 ; R6: its bit
                MOVE    IMG_PEND, R0
                MOVE    @R0, R7
                AND     R6, R7
                RBRA    _IPA_NEXT, Z
                NOT     R6, R6
                AND     R6, @R0
                MOVE    IMG_KEYS, R8            ; the path again
                ADD     R5, R8
                MOVE    @R8, R8
                MOVE    IMG_PATH, R9
                MOVE    IMG_PLEN, R10
                RSUB    CFGS_GET, 1
                RBRA    _IPA_NEXT, !C
                MOVE    VDRIVES_NUM, R8         ; the buffer: (vdrives +
                MOVE    @R8, R8                 ; submenus + image) x OPTM_DX
                MOVE    OPTM_SCOUNT, R9
                ADD     @R9, R8
                ADD     R5, R8
                MOVE    SCR$OSM_O_DX, R9
                MOVE    @R9, R9
                SYSCALL(mulu, 1)                ; R10: the offset (R9 kept)
                MOVE    OPTM_HEAP, R1
                MOVE    @R1, R2
                ADD     R10, R2                 ; R2: the buffer
                MOVE    IMG_PATH, R3            ; R4: behind the last "/"
_IPA_S          MOVE    R3, R4
_IPA_SL         CMP     0, @R3
                RBRA    _IPA_C, Z
                CMP     0x002F, @R3++
                RBRA    _IPA_SL, !Z
                RBRA    _IPA_S, 1
_IPA_C          MOVE    R2, R3
                ADD     R9, R2                  ; R2: behind the buffer
                SUB     1, R9                   ; R9: at most OPTM_DX - 1
_IPA_CL         CMP     0, @R4
                RBRA    _IPA_CE, Z
                MOVE    @R4++, @R3++
                SUB     1, R9
                RBRA    _IPA_CL, !Z
_IPA_CE         MOVE    0, @R3
                MOVE    0, @--R2                ; "%s is replaced" := 0
_IPA_NEXT       ADD     1, R5
                CMP     IMG_N, R5
                RBRA    _IPA_I, !Z
_IPA_RET        SYSCALL(leave, 1)
                RET
