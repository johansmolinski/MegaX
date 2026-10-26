// MegaX simulation driver: x68_system (CORE/vhdl, via ghdl -> Verilog) under Verilator.
//
// Clocks, as on the MiSTer: clk_ram 80 MHz, clk_sys 40 MHz with its rising edges on
// every other rising edge of clk_ram, clk_scan at the X68000 oscillator the core asks
// for. The video clock handshake (scan_req -> scan_mode/scan_ready) follows the
// MiSTer's x68k_video_clock.sv: a request stable for 64 clk_sys clocks is applied,
// the clock switches, and scan_ready rises 4096 clk_sys clocks after lock.
//
// Boot ROM: by default preloaded into the SDRAM model (+sdram_init=..., see
// mkbootimg.py) and the loader handshake runs without bytes, so the core sees
// ldr_done; --slowload <boot.rom> sends every byte through the real loader instead.
//
// Disks: MiSTer's hps_io sector interface (img_*, sd_*), as the MiSTer HPS serves
// it: --fd0 <image> mounts at 1 ms (D88, or XDF/DIM/HDM by the file name), every
// request (sd_rd/sd_wr bit n = drive n) is answered after 5 us: sd_ack, then the
// 512 bytes (read: sd_buff_dout + one-clock sd_buff_wr per byte; write: sd_buff_din
// per sd_buff_addr), then sd_ack drops. Writes go to the image in memory only.
//
// Video: frames from the scanout (clk_scan, video_ce); one line per frame on stdout
// (size, lit pixels, checksum); a PPM file whenever the picture changes.
//
// usage: sim [--ms <time>] [--dump <dir>] [--max-dumps <n>] [--turbo]
//            [--slowload <boot.rom>] [--trace <file.vcd> --trace-from <ms> --trace-to <ms>]
//            [--bus <file> [--bus-from <ms>] [--bus-to <ms>] [--bus-data]]
//            [--fd0 <image>] [--fd1 <image>] [+plusargs...]
// The 68000's bus cycles (debug.vlt makes them readable): --bus logs each one
// (time, function code, R/W, address, data); the most frequent program-fetch
// addresses are printed at the end.

#include "Vx68_system.h"
#include "Vx68_system___024root.h"
#include "verilated.h"
#if VM_TRACE
#include "verilated_vcd_c.h"
#endif
#include <algorithm>
#include <chrono>
#include <map>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

typedef uint64_t fs_t;                                   // femtoseconds
static const fs_t FS_PER_PS = 1000;

struct Clock {
   fs_t half;
   fs_t next;
   bool val;
};

static fs_t half_period(double mhz) { return (fs_t)(1e9 / mhz / 2.0 + 0.5); }

// x68k_video_clock.sv: oscillator family of a requested mode (v60 = "60 fps" boost)
static double family_mhz(unsigned mode, bool v60) {
   if ((mode & 3) == 3) return 50.35;
   if (!(mode & 4))     return 38.863636;
   return v60 ? 75.248600 : 69.551990;
}

struct Frame {
   std::vector<uint32_t> px;
   std::vector<int> line_len;
   int cur = 0;
};

int main(int argc, char** argv) {
   double ms_total = 50.0;
   std::string dump_dir, slowload, trace_file;
   double trace_from_ms = 0.0, trace_to_ms = 1e9;
   int max_dumps = 50;
   std::string bus_file;
   double bus_from_ms = 0.0, bus_to_ms = 1e9;
   bool bus_data_only = false;                           // --bus-data: no program fetches
   std::string fd_file[2];
   bool turbo = false;
   for (int i = 1; i < argc; i++) {
      std::string a = argv[i];
      if (a == "--ms" && i + 1 < argc) ms_total = atof(argv[++i]);
      else if (a == "--dump" && i + 1 < argc) dump_dir = argv[++i];
      else if (a == "--max-dumps" && i + 1 < argc) max_dumps = atoi(argv[++i]);
      else if (a == "--turbo") turbo = true;
      else if (a == "--slowload" && i + 1 < argc) slowload = argv[++i];
      else if (a == "--trace" && i + 1 < argc) trace_file = argv[++i];
      else if (a == "--trace-from" && i + 1 < argc) trace_from_ms = atof(argv[++i]);
      else if (a == "--trace-to" && i + 1 < argc) trace_to_ms = atof(argv[++i]);
      else if (a == "--bus" && i + 1 < argc) bus_file = argv[++i];
      else if (a == "--bus-from" && i + 1 < argc) bus_from_ms = atof(argv[++i]);
      else if (a == "--bus-to" && i + 1 < argc) bus_to_ms = atof(argv[++i]);
      else if (a == "--bus-data") bus_data_only = true;
      else if (a == "--fd0" && i + 1 < argc) fd_file[0] = argv[++i];
      else if (a == "--fd1" && i + 1 < argc) fd_file[1] = argv[++i];
   }

   VerilatedContext* ctx = new VerilatedContext;
   ctx->commandArgs(argc, argv);
   Vx68_system* top = new Vx68_system{ctx};

#if VM_TRACE
   VerilatedVcdC* tfp = nullptr;
   bool trace_done = false;
   if (!trace_file.empty()) ctx->traceEverOn(true);
#endif

   std::vector<uint8_t> rom;
   if (!slowload.empty()) {
      FILE* f = fopen(slowload.c_str(), "rb");
      if (!f) { fprintf(stderr, "cannot open %s\n", slowload.c_str()); return 1; }
      rom.resize(1 << 20);
      if (fread(rom.data(), 1, rom.size(), f) != rom.size()) { fprintf(stderr, "short boot.rom\n"); return 1; }
      fclose(f);
   }

   // disk images (drive n = sd_rd/sd_wr bit n)
   std::vector<uint8_t> img[8];
   bool img_xdf[8] = {false};
   for (int d = 0; d < 2; d++) {
      if (fd_file[d].empty()) continue;
      FILE* f = fopen(fd_file[d].c_str(), "rb");
      if (!f) { fprintf(stderr, "cannot open %s\n", fd_file[d].c_str()); return 1; }
      fseek(f, 0, SEEK_END);
      img[d].resize(ftell(f));
      fseek(f, 0, SEEK_SET);
      if (fread(img[d].data(), 1, img[d].size(), f) != img[d].size()) { fprintf(stderr, "short read\n"); return 1; }
      fclose(f);
      std::string ext = fd_file[d].size() > 4 ? fd_file[d].substr(fd_file[d].size() - 4) : "";
      for (auto& c : ext) c = tolower(c);
      img_xdf[d] = ext == ".xdf" || ext == ".dim" || ext == ".hdm";
   }
   enum { D_IDLE, D_WAIT, D_READ, D_WRITE, D_DONE } dstate = D_IDLE;
   int dwait = 0, ddrive = 0, dbyte = 0, dphase = 0, dlog = 0;
   bool dwrite = false;
   uint32_t dlba = 0;
   int mount_next = 0;                                   // next drive to announce

   Clock c_ram{half_period(80.0), 0, false};
   Clock c_sys{half_period(40.0), 0, false};
   Clock c_scan{half_period(80.0), 0, false};            // pll_native's power-up output

   // video clock handshake state (x68k_video_clock.sv)
   unsigned candidate = 0, applied = 0, quiet = 0;
   bool valid = false;
   int relock = 0;                                       // clk_sys clocks until locked
   int settle = 0;
   bool locked = true;

   // loader
   enum { L_RESET, L_START, L_SEND, L_END, L_DONE } lstate = L_RESET;
   long sys_cycles = 0;
   size_t lptr = 0;

   // RTC: 2026-10-26 (Monday) 12:00:00, MiSTer layout (BCD), bit 64 toggles on update
   const uint8_t rtc_b[8] = {0x00, 0x00, 0x12, 0x26, 0x10, 0x26, 0x01, 0x40};
   for (int w = 0; w < 2; w++) {
      uint32_t v = 0;
      for (int b = 0; b < 4; b++) v |= (uint32_t)rtc_b[w * 4 + b] << (8 * b);
      top->rtc[w] = v;
   }
   top->rtc[2] = 0;

   top->locked = 0;                                      // the PLL locks after 1 us
   top->reset = 1;
   top->turbo = turbo;
   top->boot_active = 0;
   top->boot_wr = 0;
   top->boot_addr = 0;
   top->boot_data = 0;
   top->scan_ready = 0;
   top->img_mounted = 0;
   top->img_readonly = 0;
   top->img_size = 0;
   top->img_xdf = 0;
   top->sd_ack = 0;
   top->sd_buff_addr = 0;
   top->sd_buff_dout = 0;
   top->sd_buff_wr = 0;
   top->fd_eject = 0;
   top->fd_sync = 0;
   top->scan_mode = 0;
   top->clk_ram = top->clk_sys = top->clk_scan = 0;
   top->eval();

   // 68000 bus monitor
   auto* R = top->rootp;
   FILE* busf = bus_file.empty() ? nullptr : fopen(bus_file.c_str(), "w");
   bool bus_as_prev = true;
   uint32_t bus_addr = 0, bus_fc = 0, bus_rw = 1, bus_dat = 0, bus_ds = 0;
   long bus_cycles = 0;
   std::map<uint32_t, long> fetch_hist;
   long region_rd[256] = {0}, region_wr[256] = {0};      // per 64 KB of address space

   // frame capture
   Frame fr;
   long frame_no = 0;
   uint64_t last_sum = 0;
   int dumps = 0;
   bool prev_vs = false, prev_hs = false;
   const fs_t end_fs = (fs_t)(ms_total * 1e12);
   fs_t now = 0, next_report = (fs_t)1e12;              // every simulated ms
   auto wall0 = std::chrono::steady_clock::now();

   while (now < end_fs && !ctx->gotFinish()) {
      // the next edge(s)
      fs_t t = c_ram.next;
      if (c_sys.next < t) t = c_sys.next;
      if (c_scan.next < t) t = c_scan.next;
      now = t;
      ctx->time(now / FS_PER_PS);
      bool ram_rise = false, sys_rise = false, scan_rise = false;
      if (c_ram.next == t)  { c_ram.val = !c_ram.val;   c_ram.next += c_ram.half;   ram_rise = c_ram.val; }
      if (c_sys.next == t)  { c_sys.val = !c_sys.val;   c_sys.next += c_sys.half;   sys_rise = c_sys.val; }
      if (c_scan.next == t) { c_scan.val = !c_scan.val; c_scan.next += c_scan.half; scan_rise = c_scan.val; }
      top->clk_ram = c_ram.val;
      top->clk_sys = c_sys.val;
      top->clk_scan = c_scan.val;
      top->eval();
#if VM_TRACE
      if (!trace_file.empty() && !tfp && !trace_done && now >= (fs_t)(trace_from_ms * 1e12)) {
         tfp = new VerilatedVcdC;
         top->trace(tfp, 99);
         tfp->open(trace_file.c_str());
      }
      if (tfp) {
         tfp->dump(ctx->time());
         if (now >= (fs_t)(trace_to_ms * 1e12)) { tfp->close(); delete tfp; tfp = nullptr; trace_done = true; }
      }
#endif
      (void)ram_rise;

      if (sys_rise) {
         sys_cycles++;
         if (sys_cycles == 40) top->locked = 1;
         // reset for the first 1000 clk_sys clocks (25 us)
         if (sys_cycles == 1000) top->reset = 0;

         // loader (MiSTer's ioctl: one byte per write, wait while boot_wait)
         top->boot_wr = 0;
         switch (lstate) {
         case L_RESET: if (sys_cycles == 2000) { top->boot_active = 1; lstate = L_START; } break;
         case L_START: lstate = rom.empty() ? L_END : L_SEND; break;
         case L_SEND:
            if (!top->boot_wait) {
               if (lptr < rom.size()) {
                  top->boot_addr = lptr;
                  top->boot_data = rom[lptr];
                  top->boot_wr = 1;
                  lptr++;
               } else lstate = L_END;
            }
            break;
         case L_END:
            if (!top->boot_wait) {
               top->boot_active = 0;
               lstate = L_DONE;
               printf("[%8.3f ms] boot ROM %s\n", now / 1e12, rom.empty() ? "preloaded (loader handshake only)" : "sent");
            }
            break;
         default: break;
         }

         // disk mounts: one drive per clock from 1 ms on (40000 clk_sys)
         top->img_mounted = 0;
         if (sys_cycles >= 40000 && mount_next < 8) {
            int d = mount_next++;
            if (!img[d].empty()) {
               top->img_mounted = 1u << d;
               top->img_size = img[d].size();
               top->img_xdf = img_xdf[d];
               printf("[%8.3f ms] drive %d: mounted %s (%zu bytes, %s)\n", now / 1e12, d, fd_file[d].c_str(),
                      img[d].size(), img_xdf[d] ? "XDF/DIM/HDM" : "D88");
            }
         }

         // sector service (hps_io)
         top->sd_buff_wr = 0;
         switch (dstate) {
         case D_IDLE: {
            unsigned req = (top->sd_rd | top->sd_wr) & 0xFF;
            if (req) {
               ddrive = __builtin_ctz(req);
               dwrite = (top->sd_wr >> ddrive) & 1;
               dlba = top->sd_lba;
               dwait = 200;                              // 5 us HPS latency
               dstate = D_WAIT;
            }
            break;
         }
         case D_WAIT:
            if (--dwait == 0) {
               if (dlog++ < 20)
                  printf("[%8.3f ms] drive %d: %s block %u\n", now / 1e12, ddrive, dwrite ? "write" : "read", dlba);
               top->sd_ack = 1u << ddrive;
               top->sd_buff_addr = 0;
               dbyte = 0;
               dphase = 0;
               dstate = dwrite ? D_WRITE : D_READ;
            }
            break;
         case D_READ:                                    // one byte per 4 clocks
            if (dphase == 0) {
               size_t o = (size_t)dlba * 512 + dbyte;
               top->sd_buff_addr = dbyte;
               top->sd_buff_dout = o < img[ddrive].size() ? img[ddrive][o] : 0;
               top->sd_buff_wr = 1;
            }
            if (++dphase == 4) {
               dphase = 0;
               if (++dbyte == 512) { top->sd_ack = 0; dwait = 40; dstate = D_DONE; }
            }
            break;
         case D_WRITE:                                   // address, then data two clocks later
            if (dphase == 0) top->sd_buff_addr = dbyte;
            if (++dphase == 4) {
               size_t o = (size_t)dlba * 512 + dbyte;
               if (o < img[ddrive].size()) img[ddrive][o] = top->sd_buff_din;
               dphase = 0;
               if (++dbyte == 512) { top->sd_ack = 0; dwait = 40; dstate = D_DONE; }
            }
            break;
         case D_DONE:                                    // let the core drop its request
            if (--dwait == 0) dstate = D_IDLE;
            break;
         }

         // video clock (x68k_video_clock.sv, mgmt_clk = clk_sys)
         unsigned request = top->scan_req & 0xF;
         if (request != candidate) { candidate = request; quiet = 0; }
         else if (quiet < 63) quiet++;
         if (request != applied || !locked) top->scan_ready = 0;
         if (relock > 0) {
            if (--relock == 0) { locked = true; settle = 0; }
         } else if (quiet == 63 && candidate == request && (!valid || request != applied)) {
            applied = request;
            valid = true;
            top->scan_mode = request;
            double mhz = family_mhz(request, false);
            c_scan.half = half_period(mhz);
            locked = false;
            relock = 400;                                // PLL relock: 10 us (assumed)
            printf("[%8.3f ms] video clock: mode %X -> %.4f MHz\n", now / 1e12, request, mhz);
         } else if (valid && request == applied && locked) {
            if (settle < 4096) settle++;
            else top->scan_ready = 1;
         }
      }

      if (sys_rise) {
         bool as = R->x68_system__DOT__i_core__DOT__i_asn;
         if (!as) {                                      // during the cycle: latest values
            bus_addr = R->x68_system__DOT__i_core__DOT__mpu_addr & 0xFFFFFE;
            bus_fc = R->x68_system__DOT__i_core__DOT__mpu_fc;
            bus_rw = R->x68_system__DOT__i_core__DOT__i_rwn;
            bus_ds = (!R->x68_system__DOT__i_core__DOT__mpu_udsn << 1) | !R->x68_system__DOT__i_core__DOT__mpu_ldsn;
            bus_dat = bus_rw ? R->x68_system__DOT__i_core__DOT__dbus : R->x68_system__DOT__i_core__DOT__mpu_od;
         } else if (!bus_as_prev) {                     // the cycle ended
            bus_cycles++;
            if ((bus_fc & 3) == 2) fetch_hist[bus_addr]++;
            else if (bus_fc != 7) (bus_rw ? region_rd : region_wr)[bus_addr >> 16]++;
            double ms = now / 1e12;
            if (busf && ms >= bus_from_ms && ms <= bus_to_ms && !(bus_data_only && (bus_fc & 3) == 2))
               fprintf(busf, "%10.6f %d %c %06X %04X %c%c\n", ms, bus_fc, bus_rw ? 'R' : 'W', bus_addr, bus_dat,
                       bus_ds & 2 ? 'U' : '-', bus_ds & 1 ? 'L' : '-');
         }
         bus_as_prev = as;
      }

      if (scan_rise && top->video_ce) {
         bool vs = top->video_vs, hs = top->video_hs;
         if (hs && !prev_hs) {                           // end of a line
            if (fr.cur > 0) { fr.line_len.push_back(fr.cur); fr.cur = 0; }
         }
         if (vs && !prev_vs) {                           // end of a frame
            if (fr.cur > 0) { fr.line_len.push_back(fr.cur); fr.cur = 0; }
            int h = (int)fr.line_len.size(), w = 0;
            for (int l : fr.line_len) if (l > w) w = l;
            long lit = 0;
            uint64_t sum = 1469598103934665603ULL;
            for (uint32_t p : fr.px) { if (p) lit++; sum = (sum ^ p) * 1099511628211ULL; }
            printf("[%8.3f ms] frame %ld: %dx%d, %ld lit, sum %016llx%s\n", now / 1e12, frame_no, w, h, lit,
                   (unsigned long long)sum, sum != last_sum ? " (new)" : "");
            if (!dump_dir.empty() && sum != last_sum && dumps < max_dumps && w > 0 && h > 0) {
               char name[512];
               snprintf(name, sizeof name, "%s/frame%05ld.ppm", dump_dir.c_str(), frame_no);
               FILE* f = fopen(name, "wb");
               if (f) {
                  fprintf(f, "P6\n%d %d\n255\n", w, h);
                  size_t k = 0;
                  for (int l : fr.line_len) {
                     for (int x = 0; x < w; x++) {
                        uint32_t p = x < l ? fr.px[k + x] : 0;
                        uint8_t rgb[3] = {(uint8_t)(p >> 16), (uint8_t)(p >> 8), (uint8_t)p};
                        fwrite(rgb, 1, 3, f);
                     }
                     k += l;
                  }
                  fclose(f);
                  dumps++;
               }
            }
            last_sum = sum;
            fr.px.clear();
            fr.line_len.clear();
            frame_no++;
         }
         prev_vs = vs;
         prev_hs = hs;
         if (top->video_de) {
            fr.px.push_back(((uint32_t)top->video_r << 16) | ((uint32_t)top->video_g << 8) | top->video_b);
            fr.cur++;
         }
      }

      if (now >= next_report) {
         double wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - wall0).count();
         printf("[%8.3f ms] wall %.1f s (%.2f s per simulated ms)\n", now / 1e12, wall, wall / (now / 1e12));
         fflush(stdout);
         next_report += (fs_t)1e12;
      }
   }

   top->final();
   if (busf) fclose(busf);
   std::vector<std::pair<long, uint32_t>> hot;
   for (auto& kv : fetch_hist) hot.push_back({kv.second, kv.first});
   std::sort(hot.rbegin(), hot.rend());
   printf("68000 data accesses per 64 KB (address: reads/writes):");
   for (int r = 0, n = 0; r < 256; r++)
      if (region_rd[r] || region_wr[r]) printf("%s %02X0000: %ld/%ld", n++ % 6 ? "" : "\n ", r, region_rd[r], region_wr[r]);
   printf("\n68000: %ld bus cycles, %zu distinct program addresses; most fetched:\n", bus_cycles, fetch_hist.size());
   for (size_t i = 0; i < hot.size() && i < 16; i++) printf("  %06X %ld\n", hot[i].second, hot[i].first);
#if VM_TRACE
   if (tfp) tfp->close();
#endif
   printf("[%8.3f ms] end, %ld frames\n", now / 1e12, frame_no);
   delete top;
   delete ctx;
   return 0;
}
