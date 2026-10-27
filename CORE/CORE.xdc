## MegaX - Sharp X68000 for MEGA65
##
## Core specific constraints (M2M/common.xdc and M2M/MEGA65-R6.xdc hold the framework's)
##
## After PC10-III's and Megamiga's CORE/CORE.xdc and the MiSTer core's X68000.sdc

## The clocks (CORE/vhdl/clk.vhd). clk_ram 80 MHz and clk_sys 40 MHz come from one MMCM with
## aligned edges, as on the MiSTer; clk_sdram is clk_ram at 180 degrees (the SDRAM chip's
## clock); clk_scan 69.552 MHz (the X68000's 31 kHz oscillator, M2M's video clock) has an MMCM
## of its own.
create_generated_clock -name clk_ram   [get_pins CORE/clk_gen/i_clk_x68/CLKOUT0]
create_generated_clock -name main_clk  [get_pins CORE/clk_gen/i_clk_x68/CLKOUT1]
create_generated_clock -name clk_sdram [get_pins CORE/clk_gen/i_clk_x68/CLKOUT2]
create_generated_clock -name clk_scan  [get_pins CORE/clk_gen/i_clk_scan/CLKOUT0]

## The scanout (clk_scan) is asynchronous to the render side and the CPU (X68000.sdc: the
## video PLL in a clock group of its own). The core's crossings are #72's handshakes, dual-clock
## line RAMs and two-flop synchronizers (x68k_native_crtc.sv, x68k_video_cdc.sv); main.vhd's
## scan_locked synchronizer is ASYNC_REG.
set_clock_groups -asynchronous -group [get_clocks clk_scan] -group [get_clocks {clk_ram main_clk clk_sdram}]

## X68000.sdc: clk_ram -> clk_sys and clk_sys -> clk_ram paths get a whole clk_sys period
## (the core hands data between the two on the common edges)
set_multicycle_path 2 -setup -start -from [get_clocks clk_ram] -to [get_clocks main_clk]
set_multicycle_path 1 -hold  -start -from [get_clocks clk_ram] -to [get_clocks main_clk]
set_multicycle_path 2 -setup -end   -from [get_clocks main_clk] -to [get_clocks clk_ram]
set_multicycle_path 1 -hold  -end   -from [get_clocks main_clk] -to [get_clocks clk_ram]

## X68000.sdc: the 68000 (fx68k: phi1/phi2 enables at most every second clk_sys clock) and the
## DMA controller (DMA63450) work on enables: two clocks for paths from and to them. Counted in
## destination clocks for setup AND hold (-end): with Vivado's default (-start) for hold, a
## path from clk_ram into the 68000 got a 12.5 ns hold requirement (build megax-c, -11 ns).
## Into the 68000 only from main_clk; clk_ram -> 68000 paths keep the clock-pair rule above.
set MPU [get_cells -hierarchical -filter {IS_SEQUENTIAL && NAME =~ CORE/i_main/i_x68_system/i_core/MPU/*}]
set DMA [get_cells -hierarchical -filter {IS_SEQUENTIAL && NAME =~ CORE/i_main/i_x68_system/i_core/DMA/*}]
set_multicycle_path 2 -setup -end -from $DMA
set_multicycle_path 1 -hold  -end -from $DMA
set_multicycle_path 2 -setup -end -from $MPU
set_multicycle_path 1 -hold  -end -from $MPU
set_multicycle_path 2 -setup -end -from [get_clocks main_clk] -to $MPU
set_multicycle_path 1 -hold  -end -from [get_clocks main_clk] -to $MPU

## X68000.sdc: the contrast register is static for the video; BG RAM writes are on sys_ce;
## vidcont's address to the cache controller has two clocks; cacheext's srclk is not timed;
## the YM3802's interpolator advances every four clocks
set_false_path -from [get_cells -hierarchical -filter {IS_SEQUENTIAL && NAME =~ CORE/i_main/i_x68_system/i_core/cont/contval*}]
set_multicycle_path 2 -setup -end -from [get_clocks main_clk] -to [get_cells -hierarchical -filter {IS_SEQUENTIAL && NAME =~ CORE/i_main/i_x68_system/i_core/spmem/bgv*}]
set_multicycle_path 1 -hold  -end -from [get_clocks main_clk] -to [get_cells -hierarchical -filter {IS_SEQUENTIAL && NAME =~ CORE/i_main/i_x68_system/i_core/spmem/bgv*}]
set_multicycle_path 2 -setup -end -from [get_cells -hierarchical -filter {IS_SEQUENTIAL && NAME =~ CORE/i_main/i_x68_system/i_core/vc/vaddr*}] -to [get_cells -hierarchical -filter {IS_SEQUENTIAL && NAME =~ CORE/i_main/i_x68_system/i_core/RAM/CACHEC/*}]
set_multicycle_path 1 -hold  -end -from [get_cells -hierarchical -filter {IS_SEQUENTIAL && NAME =~ CORE/i_main/i_x68_system/i_core/vc/vaddr*}] -to [get_cells -hierarchical -filter {IS_SEQUENTIAL && NAME =~ CORE/i_main/i_x68_system/i_core/RAM/CACHEC/*}]
set_multicycle_path 4 -setup -end -from [get_clocks main_clk] -to [get_cells -hierarchical -filter {IS_SEQUENTIAL && (NAME =~ CORE/i_main/i_x68_system/i_core/midi/interp_spacing* || NAME =~ CORE/i_main/i_x68_system/i_core/midi/interp_countdown*)}]
set_multicycle_path 3 -hold  -end -from [get_clocks main_clk] -to [get_cells -hierarchical -filter {IS_SEQUENTIAL && (NAME =~ CORE/i_main/i_x68_system/i_core/midi/interp_spacing* || NAME =~ CORE/i_main/i_x68_system/i_core/midi/interp_countdown*)}]

## qnice_clk (50 MHz) <-> main_clk (40 MHz) and clk_scan: different MMCMs. All crossings are
## synchronizers, cdc_stable, xpm FIFOs (x68_boot.vhd) or the framework's own CDCs; bound them
## to one qnice period (max_delay, not false_path, so the tighter cdc_stable bounds of
## common.xdc stay in force).
set_max_delay -datapath_only 20.000 -from [get_clocks qnice_clk] -to [get_clocks {main_clk clk_scan}]
set_max_delay -datapath_only 20.000 -from [get_clocks {main_clk clk_scan}] -to [get_clocks qnice_clk]

## ascal asynchronous FIFO data crossings (PC10-III/Megamiga CORE.xdc, framework paths): i_dpram
## is written on i_clk (= clk_scan) and read on avl_clk (= hr_clk), o_dpram is written on avl_clk
## and read on o_clk (= hdmi_clk). Bound the LUTRAM paths to one destination period.
set_max_delay -datapath_only 10.000 \
   -from [get_pins -hierarchical -regexp {.*/i_ascal/i_dpram_reg.*/CLK}] \
   -to   [get_cells -hierarchical -regexp {.*/i_ascal/avl_dr_reg\[[0-9]+\]}]
set_max_delay -datapath_only 13.400 \
   -from [get_pins -hierarchical -regexp {.*/i_ascal/o_dpram_reg.*/CLK}] \
   -to   [get_cells -hierarchical -regexp {.*/i_ascal/o_dr_reg\[[0-9]+\]}]

## SDRAM (IS42S16320F, CL2 at 80 MHz; main.vhd explains the scheme). The chip's clock is
## clk_sdram forwarded by an ODDR; commands, addresses and write data leave on clk_ram and are
## sampled by the chip on the next sdram_clk edge, half a period later. Read data: the chip
## starts driving the word of a READ tAC after the second sdram_clk edge after the command and
## holds it until tOH after the third; SDRAMC samples it on the clk_ram edge three clocks after
## the command, i.e. two clk_ram clocks after the launching sdram_clk edge (multicycle 2).
## Datasheet (-7, CL2): tAC 6.0 ns max, tOH 2.7 ns min (2.5 used), tIS 1.5 ns, tIH 0.8 ns; board
## traces 0.1 .. 0.5 ns.
create_generated_clock -name sdram_clk_pin -source [get_pins CORE/i_main/i_sdram_clk/C] -multiply_by 1 [get_ports sdram_clk_o]

set SD_OUT [get_ports {sdram_cke_o sdram_cs_n_o sdram_ras_n_o sdram_cas_n_o sdram_we_n_o sdram_ba_o[*] sdram_a_o[*] sdram_dqml_o sdram_dqmh_o sdram_dq_io[*]}]
set_output_delay -clock sdram_clk_pin -max  [expr 1.5 + 0.5] $SD_OUT
set_output_delay -clock sdram_clk_pin -min  [expr -0.8 + 0.1] $SD_OUT

set_input_delay -clock sdram_clk_pin -max [expr 6.0 + 0.5 + 0.5] [get_ports {sdram_dq_io[*]}]
set_input_delay -clock sdram_clk_pin -min [expr 2.5 + 0.1 + 0.1] [get_ports {sdram_dq_io[*]}]
set_multicycle_path 2 -setup -end -from [get_clocks sdram_clk_pin] -to [get_clocks clk_ram]
set_multicycle_path 1 -hold  -end -from [get_clocks sdram_clk_pin] -to [get_clocks clk_ram]

## M2M-UPSTREAM sd-host: the native 4-bit SD bus needs pull-ups on CMD and DAT0..DAT3 of both
## slots. Port names are the SPI ones of the board XDCs: mosi = CMD, miso = DAT0, reset = DAT3.
set_property -dict {PULLUP TRUE} [get_ports {sd_mosi_o sd_miso_i sd_d1_i sd_d2_i sd_reset_o}]
set_property -dict {PULLUP TRUE} [get_ports {sd2_mosi_o sd2_miso_i sd2_d1_i sd2_d2_i sd2_reset_o}]
