# MegaX simulation of the machine (x68_system) under Verilator.
#
#   make              build obj/sim (ghdl: VHDL -> obj/x68_system.v; Verilator)
#   make run          run 50 ms from the preloaded boot ROM, frames into obj/frames
#   make run MS=300   longer
#   make run FD0=boot the test boot disk (bootdisk/boot.S) in drive 0; FD0=<file> any image
#   make run TRACE=1 OBJ=obj-trace ARGS="--trace ../../t.vcd --trace-from 0.07 --trace-to 0.08"
#                     VCD of a window (python3 vcdpeek.py shows signals from it)
#
# The boot ROM is MiSTer's boot.rom (Sharp's IPL + CGROM): BOOTROM=<file>; by default
# the copy in the submodule's releases/ folder (never copied into this repository).
#
# Tool working directories: the RAM/ROM init files and fx68k's microcode are read
# from ../../X68000_MiSTerMEGA65/... (the path Vivado sees from CORE/CORE-R6.runs/
# synth_1), so ghdl and the simulator run in obj/run/sim, next to obj/X68000_MiSTerMEGA65.

CORE     := ../../CORE
OBJ      := obj
RUN      := $(OBJ)/run/sim
BOOTROM  ?= $(CORE)/X68000_MiSTerMEGA65/releases/boot.rom
MS       ?= 50
ARGS     ?=
FD0      ?=
THREADS  ?= 1
TRACE    ?= 0

GHDLFLAGS := --std=08 -frelaxed -fsynopsys --workdir=$(abspath $(OBJ)/ghdl)

VHDL_SRC := $(shell awk '$$1=="vhdl"{print $$2}' $(CORE)/sources.txt)
SV_SRC   := $(shell awk '$$1=="sv"{print $$2}' $(CORE)/sources.txt)
SDRAMC   := X68000_MiSTerMEGA65/rtl/memory/SDRAMC.vhd
VHDL_SIM := $(addprefix $(abspath $(CORE))/,$(filter-out $(SDRAMC),$(VHDL_SRC))) $(abspath $(OBJ)/SDRAMC_sim.vhd)
SV_SIM   := $(addprefix $(CORE)/,$(SV_SRC)) sdram_chip.sv cachememwn.sv debug.vlt

VFLAGS := --cc --exe --build -j 0 --top-module x68_system -O3 +1364-2005ext+v --x-assign 0 --x-initial 0 --no-assert-case \
          --timescale-override 1ps/1ps --threads $(THREADS) \
          -Wno-fatal -Wno-WIDTH -Wno-PINMISSING -Wno-CASEINCOMPLETE -Wno-TIMESCALEMOD \
          -Wno-MULTIDRIVEN -Wno-UNOPTFLAT -Wno-LATCH -Wno-SELRANGE -Wno-IMPLICIT \
          -Wno-COMBDLY -Wno-INITIALDLY -Wno-BLKANDNBLK -Wno-STMTDLY -Wno-ASCRANGE \
          -CFLAGS "-O2" --Mdir $(OBJ)/vl -o sim
ifeq ($(TRACE),1)
VFLAGS += --trace
endif

.PHONY: all run clean
all: $(OBJ)/vl/sim

$(OBJ)/X68000_MiSTerMEGA65:
	mkdir -p $(OBJ) $(RUN) $(OBJ)/ghdl
	ln -sfn ../../../CORE/X68000_MiSTerMEGA65 $@

$(abspath $(OBJ)/SDRAMC_sim.vhd): $(CORE)/$(SDRAMC) sdramc_sim.py | $(OBJ)/X68000_MiSTerMEGA65
	python3 sdramc_sim.py $< $@

# ghdl: analyse, elaborate, synthesise to Verilog. Black boxes: the SystemVerilog
# and Verilog modules (fx68k, jt51, IKAOPM, tvram_ddr, the #72 video modules) and
# sdram_chip. VHDL extended identifiers (\VMODE\) come out in VHDL form; Verilog
# needs plain names there. fix_dups.py repairs ghdl's instance-output name collisions.
$(OBJ)/x68_system.v: $(VHDL_SIM) $(CORE)/sources.txt fix_dups.py | $(OBJ)/X68000_MiSTerMEGA65
	rm -f $(OBJ)/ghdl/*.cf
	ghdl -i $(GHDLFLAGS) $(VHDL_SIM)
	cd $(RUN) && ghdl -m $(GHDLFLAGS) x68_system > $(abspath $(OBJ))/ghdl_make.log 2>&1
	cd $(RUN) && ghdl --synth $(GHDLFLAGS) --out=verilog x68_system > $(abspath $@).tmp 2> $(abspath $(OBJ))/ghdl_synth.log
	sed -E 's/\\([A-Za-z_][A-Za-z0-9_]*)\\/\1/g' $@.tmp > $@.tmp2 && rm $@.tmp
	python3 fix_dups.py $@.tmp2 $@ && rm $@.tmp2
	@grep -c "warning" $(OBJ)/ghdl_synth.log | xargs echo "ghdl warnings:"

$(OBJ)/vl/sim: $(OBJ)/x68_system.v $(SV_SIM) sim_main.cpp Makefile
	verilator $(VFLAGS) $(OBJ)/x68_system.v $(SV_SIM) sim_main.cpp > $(OBJ)/verilator.log 2>&1 || (tail -40 $(OBJ)/verilator.log; false)
	@grep -c "%Warning" $(OBJ)/verilator.log | xargs echo "verilator warnings:"

$(OBJ)/boot_sdram.hex: $(BOOTROM) mkbootimg.py | $(OBJ)/X68000_MiSTerMEGA65
	python3 mkbootimg.py $< $@

# the test boot disk: a 2HD XDF whose boot sector is bootdisk/boot.S
$(OBJ)/boot.xdf: bootdisk/boot.S bootdisk/mkxdf.py | $(OBJ)/X68000_MiSTerMEGA65
	m68k-linux-gnu-as -m68000 $< -o $(OBJ)/boot.o
	m68k-linux-gnu-objcopy -O binary $(OBJ)/boot.o $(OBJ)/boot.bin
	python3 bootdisk/mkxdf.py $(OBJ)/boot.bin $@

ifeq ($(FD0),boot)
FD0_DEP  := $(OBJ)/boot.xdf
FD0_ARG  := --fd0 ../../boot.xdf
else ifneq ($(FD0),)
FD0_ARG  := --fd0 $(abspath $(FD0))
endif

run: $(OBJ)/vl/sim $(OBJ)/boot_sdram.hex $(FD0_DEP)
	mkdir -p $(OBJ)/frames
	cd $(RUN) && ../../vl/sim --ms $(MS) --dump ../../frames +sdram_init=../../boot_sdram.hex $(FD0_ARG) $(ARGS)

clean:
	rm -rf $(OBJ)
