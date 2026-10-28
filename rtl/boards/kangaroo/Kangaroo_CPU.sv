//============================================================================
//
//  Kangaroo Main CPU Board (TVG-1-CPU-B)
//  Based on MAME kangaroo.cpp by Ville Laitinen, Aaron Giles
//
//============================================================================

module Kangaroo_CPU
(
    input         reset,
    input         clk_10m,           // 10 MHz master clock (matches real XTAL)

    // Video outputs
    output  [2:0] video_r, video_g,  // BGR 3-bit palette
    output  [1:0] video_b,
    output        video_hsync, video_vsync,
    output        video_hblank, video_vblank,
    output        ce_pix,

    // DIAG-REVERT-2026-09-01: Screen Centering offsets from the OSD, two's complement.
    // h_center is in PIXELS and scaled x2 below because h_cnt runs at the double-rate
    // 10 MHz clock (MAME: 320*2 / 256*2), so one displayed pixel is two h_cnt counts.
    // v_center is only 3 bits: this board's vblank is 20 lines (v_cnt 248..259 + 0..7),
    // so a +-8 range like Vastar's would push vsync onto visible lines. +-4 is the most
    // that fits with the 4-line pulse staying inside vblank.
    input   [3:0] h_center,
    input   [2:0] v_center,

    // Inputs
    input   [7:0] dsw0,             // 8-bit DIP switch
    input   [4:0] in0,              // IN0: service, start1, start2, coin_l, coin_r
    // in1 is 8 bits wide; bits 7:5 are unused on this board.
    input   [7:0] in1,              // IN1: P1 right,left,up,down,punch + bit5 = FF 2nd btn (0x20)
    input   [7:0] in2,              // IN2: P2 right, left, up, down, punch

    // Sound interface
    output  [7:0] sound_latch,      // Data to sound CPU
    output        sound_latch_wr,   // Strobe: sound latch written

    // MCU (MB8841) presence flag (original Kangaroo HW only)
    input         mcu_present,    // 1 = MB8841 fitted (kangaroo/kangarooa); 0 = bootleg / Funky Fish

    input         pause,
    input         crt_flip,

    // Hiscore interface (active high, stubbed for now)
    input  [15:0] hs_address,
    input   [7:0] hs_data_in,
    output  [7:0] hs_data_out,
    input         hs_write,

    // shared CPU / MCU pool (rtl/kangaroo_dispatcher.sv)
    output chip_pool_pkg::z80r_i_t z80_0_i,
    input  chip_pool_pkg::z80r_o_t z80_0_o,
    output chip_pool_pkg::mb88_i_t mb88_0_i,
    input  chip_pool_pkg::mb88_o_t mb88_0_o,

    // shared ROM blocks, read ports: program ROMs and the CPU's blitter-ROM window (all at cpu_A[11:0]), the blitter's
    // own copy of the blitter ROMs, MB8841 program and protection PROM
    output [11:0] rom_cpu_a,
    input   [7:0] rom0_d, rom1_d, rom2_d, rom3_d, rom4_d, rom5_d,
    input   [7:0] blit0_d, blit1_d, blit2_d, blit3_d,
    output [13:0] blitrom_a,
    input   [7:0] blitrom_d,
    output [10:0] mcu_prog_a,
    input   [7:0] mcu_prog_d,
    output [10:0] mcu_prot_a,
    input   [7:0] mcu_prot_d,

    // board RAM pool: 0 = work RAM (port B hiscore), 1-8 = VRAM byte lanes
    output ram_pool_pkg::pram_i_t [8:0] pr_i,
    input  ram_pool_pkg::pram_o_t [8:0] pr_o
);

//------------------------------------------------------- Clock Enables -------------------------------------------------------//

// Generate clock enables from 10 MHz master
// cen_5m  = 10/2 = 5 MHz (pixel clock)
// cen_2m5 = 10/4 = 2.5 MHz (Z80 clock)
reg [1:0] div = 2'd0;
always_ff @(posedge clk_10m) begin
    div <= div + 2'd1;
end
wire cen_5m  = (div[0] == 1'b0);     // Every 2nd clock
wire cen_2m5 = (div == 2'd0);         // Every 4th clock

assign ce_pix = cen_5m;

//------------------------------------------------------------ CPU -------------------------------------------------------------//

// Main CPU — Zilog Z80 (T80s soft core)
wire [15:0] cpu_A;
wire  [7:0] cpu_Dout;
wire n_m1, n_mreq, n_iorq, n_rd, n_wr, n_rfsh;

assign n_m1 = z80_0_o.m1_n; assign n_mreq = z80_0_o.mreq_n; assign n_iorq = z80_0_o.iorq_n;
assign n_rd = z80_0_o.rd_n; assign n_wr = z80_0_o.wr_n; assign n_rfsh = z80_0_o.rfsh_n;
assign cpu_A = z80_0_o.a; assign cpu_Dout = z80_0_o.dout;

//------------------------------------------------------ Address Decoding ------------------------------------------------------//

// Active-low signals for memory regions
wire mem_access = ~n_mreq & n_rfsh;

// ROM: 0x0000-0x5FFF (read only)
wire cs_rom = mem_access & (cpu_A[15:14] == 2'b00) & ~cpu_A[13]; // 0x0000-0x1FFF
wire cs_rom_hi = mem_access & (cpu_A[15:13] == 3'b001);           // 0x2000-0x3FFF
wire cs_rom_top = mem_access & (cpu_A[15:13] == 3'b010);          // 0x4000-0x5FFF
wire cs_any_rom = cs_rom | cs_rom_hi | cs_rom_top;

// Video RAM: 0x8000-0xBFFF (write only from CPU perspective)
wire cs_videoram = mem_access & (cpu_A[15:14] == 2'b10);          // 0x8000-0xBFFF

// Banked blitter ROM: 0xC000-0xDFFF (read only)
wire cs_blitbank = mem_access & (cpu_A[15:13] == 3'b110);         // 0xC000-0xDFFF

// Work RAM: 0xE000-0xE3FF
wire cs_workram = mem_access & (cpu_A[15:10] == 6'b111000);       // 0xE000-0xE3FF

// DSW: 0xE400 (read, mirrored across 0xE400-0xE7FF)
wire cs_dsw = mem_access & (cpu_A[15:10] == 6'b111001);           // 0xE400-0xE7FF

// Video control: 0xE800-0xE80A (write, mirrored with 0x03F0)
wire cs_vidctrl = mem_access & (cpu_A[15:10] == 6'b111010);       // 0xE800-0xEBFF

// IN0 read / soundlatch write: 0xEC00
wire cs_in0 = mem_access & (cpu_A[15:8] == 8'hEC);

// IN1 read / coin counter write: 0xED00
wire cs_in1 = mem_access & (cpu_A[15:8] == 8'hED);

// IN2 read: 0xEE00
wire cs_in2 = mem_access & (cpu_A[15:8] == 8'hEE);

// MCU: 0xEF00 (security chip; MB8841 on original HW, returns 0 on bootleg)
wire cs_mcu = mem_access & (cpu_A[15:8] == 8'hEF);

//--------------------------------------------------------- CPU Data Mux -------------------------------------------------------//

wire [7:0] rom_D;
wire [7:0] blitbank_D;
wire [7:0] workram_D;
wire [7:0] mcu_dout;            // 0xEF00 read data (MCU R0 latch, or 0 on bootleg)

wire [7:0] cpu_Din =
    cs_any_rom     ? rom_D :
    cs_blitbank    ? blitbank_D :
    (cs_workram & ~n_rd) ? workram_D :
    cs_dsw         ? dsw0 :
    cs_in0         ? {3'b000, in0} :
    // All 8 IN1 bits reach the CPU; bits 7:5 read as 0.
    cs_in1         ? in1 :
    cs_in2         ? in2 :
    cs_mcu         ? mcu_dout :    // MB8841 R0 (original HW) or 0x00 (bootleg)
    8'hFF;

//-------------------------------------------------------- Program ROMs --------------------------------------------------------//

wire [7:0] rom0_D, rom1_D, rom2_D, rom3_D, rom4_D, rom5_D;

assign rom_D = (cpu_A[15:12] == 4'h0) ? rom0_D :
               (cpu_A[15:12] == 4'h1) ? rom1_D :
               (cpu_A[15:12] == 4'h2) ? rom2_D :
               (cpu_A[15:12] == 4'h3) ? rom3_D :
               (cpu_A[15:12] == 4'h4) ? rom4_D :
               (cpu_A[15:12] == 4'h5) ? rom5_D :
               8'hFF;

assign rom_cpu_a = cpu_A[11:0];
assign rom0_D = rom0_d;
assign rom1_D = rom1_d;
assign rom2_D = rom2_d;
assign rom3_D = rom3_d;
assign rom4_D = rom4_d;
assign rom5_D = rom5_d;

//------------------------------------------------------- Blitter ROMs --------------------------------------------------------//

// Blitter has 4 x 4KB ROMs, banked into 0xC000-0xDFFF via bank select (video_control[8])
// One contiguous 8K window is banked over the 16K image, and
// the image loads v0,v2,v1,v3, so blit0=v0 blit1=v2 blit2=v1 blit3=v3:
//   entry 0 (base+0000): C000=blit0(v0)  D000=blit1(v2)
//   entry 1 (base+2000): C000=blit2(v1)  D000=blit3(v3)

wire [7:0] blit0_D, blit1_D, blit2_D, blit3_D;
wire blit_bank_hi = (video_control[8] & 8'h05) == 0;   // (data & 0x05) ? 0 : 1

assign blitbank_D = cpu_A[12] ?
    (blit_bank_hi ? blit3_D : blit1_D) :   // D000-DFFF: v3 / v2
    (blit_bank_hi ? blit2_D : blit0_D);    // C000-CFFF: v1 / v0

assign blit0_D = blit0_d;
assign blit1_D = blit1_d;
assign blit2_D = blit2_d;
assign blit3_D = blit3_d;

//------------------------------------------------------------ RAM ------------------------------------------------------------//

// Work RAM (0xE000-0xE3FF, 1KB)
assign pr_i[0].a_addr = {5'd0, cpu_A[9:0]}; assign pr_i[0].a_d = cpu_Dout; assign pr_i[0].a_we = cs_workram & ~n_wr;
assign pr_i[0].b_addr = {5'd0, hs_address[9:0]}; assign pr_i[0].b_d = hs_data_in; assign pr_i[0].b_we = hs_write;
assign workram_D = pr_o[0].a_q;
assign hs_data_out = pr_o[0].b_q;

//--------------------------------------------------- Video Control Registers --------------------------------------------------//

// video_control[0..10], written at 0xE800-0xE80A
// Only bits [3:0] of the address select the register (mirrored with 0x03F0)
reg [7:0] video_control [0:10];
integer vc_i;
initial begin
    for (vc_i = 0; vc_i < 11; vc_i = vc_i + 1)
        video_control[vc_i] = 8'd0;
end

// Trigger for blitter execution (directly from Step 4)
reg blitter_start = 0;

always_ff @(posedge clk_10m) begin
    blitter_start <= 0;
    if(cs_vidctrl & ~n_wr) begin
        if(cpu_A[3:0] <= 4'd10)
            video_control[cpu_A[3:0]] <= cpu_Dout;
        if(cpu_A[3:0] == 4'd5)
            blitter_start <= 1;  // Writing to reg 5 triggers DMA blit
    end
end

//------------------------------------------------------- Sound Latch ---------------------------------------------------------//

reg [7:0] slatch = 8'd0;
reg       slatch_wr_pulse = 0;
always_ff @(posedge clk_10m) begin
    slatch_wr_pulse <= 0;
    if(cs_in0 & ~n_wr) begin
        slatch <= cpu_Dout;
        slatch_wr_pulse <= 1;
    end
end
assign sound_latch = slatch;
assign sound_latch_wr = slatch_wr_pulse;

//------------------------------------------------------- Bootleg NMI ---------------------------------------------------------//

// The bootleg has no MCU. It pulses NMI at reset to make the game boot.
// On original HW (mcu_present) the MB8841 drives NMI instead (see MCU block below) — this pulse is unused.
reg [7:0] nmi_boot_cnt = 8'd0;
reg n_nmi_boot = 1'b1;
always_ff @(posedge clk_10m) begin
    if(!reset) begin
        nmi_boot_cnt <= 8'd255;
        n_nmi_boot <= 1'b1;
    end
    else if(nmi_boot_cnt > 0 && cen_2m5) begin
        nmi_boot_cnt <= nmi_boot_cnt - 8'd1;
        if(nmi_boot_cnt == 8'd32)
            n_nmi_boot <= 1'b0;
        else if(nmi_boot_cnt == 8'd16)
            n_nmi_boot <= 1'b1;
    end
end

// NMI source select: MB8841 (R3.3) on original HW, bootleg boot pulse otherwise. (mcu_nmi_n: MCU block below.)
wire n_nmi = mcu_present ? mcu_nmi_n : n_nmi_boot;

//-------------------------------------------------------- MB8841 MCU ---------------------------------------------------------//
// Original Kangaroo (TVG-1-CPU-B, IC29) fits an MB8841 used for protection: besides the boot NMI it times the big
// ape's appearances. Wiring:
//   CPU wr 0xEF00 -> main_data;  CPU rd 0xEF00 <- R0 port latch
//   K port = 0xF & (R2.0 ? main_data : F) & (~R3.0 ? protrom[addr] : F)
//   O port (oh:ol) -> protrom A0-A7, R3.1 -> A8 (A9, A10 = GND);  R3.3 -> main-CPU NMI
// MCU clock = 10 MHz / 4 = 2.5 MHz, held in reset when not fitted. The R inputs read back the output latches (nothing
// drives the R pins externally); /IRQ and /TC are not driven.

// `ena` is one MB88 machine cycle. MAME converts pin clocks at (clocks+5)/6, so the
// 2.5 MHz pin rate is divided by 6. The /32 timer prescaler lives inside the mb88.sv wrapper.
localparam int MCU_CEN_DIV = 6;
reg [2:0] mcu_div_cnt = 3'd0;
always @(posedge clk_10m)
    if (cen_2m5) mcu_div_cnt <= (mcu_div_cnt == MCU_CEN_DIV[2:0] - 3'd1) ? 3'd0 : mcu_div_cnt + 3'd1;
wire mcu_ena       = cen_2m5 & ~pause & (mcu_div_cnt == MCU_CEN_DIV[2:0] - 3'd1);
wire mcu_reset_n   = reset & mcu_present;     // hold in reset unless MB8841 is fitted

wire [10:0] mcu_rom_addr;
wire  [7:0] mcu_rom_q;
wire  [3:0] mcu_ol, mcu_oh;
wire  [7:0] mcu_o = {mcu_oh, mcu_ol};         // combined O port = protrom A0-A7
wire  [3:0] r0_out, r1_out, r2_out, r3_out;

reg  [7:0] main_data = 8'd0;                  // CPU write to 0xEF00 (mcu_w)
always_ff @(posedge clk_10m)
    if (cs_mcu & ~n_wr) main_data <= cpu_Dout;

wire [10:0] protrom_addr = {2'b00, r3_out[1], mcu_o};   // A8 = R3.1, A0-A7 = O
wire  [7:0] protrom_q;

wire  [3:0] mcu_k = 4'hF
                  & ( r2_out[0] ? main_data[3:0] : 4'hF)   // gated by R2.0
                  & (~r3_out[0] ? protrom_q[3:0] : 4'hF);  // gated by ~R3.0

wire mcu_nmi_n = ~r3_out[3];                  // R3.3 asserts NMI (active high) -> n_nmi low
assign mcu_dout = mcu_present ? {4'h0, r0_out} : 8'h00;

assign {r0_out, r1_out, r2_out, r3_out} = {mb88_0_o.r_out[3:0], mb88_0_o.r_out[7:4], mb88_0_o.r_out[11:8], mb88_0_o.r_out[15:12]};
assign {mcu_oh, mcu_ol} = mb88_0_o.o;
assign mcu_rom_addr = mb88_0_o.rom_a;

// MCU program ROM (dispatcher block: index 6 000-7FF)
assign mcu_prog_a = mcu_rom_addr;
assign mcu_rom_q = mcu_prog_d;

// MCU protection PROM (dispatcher block: index 6 800-FFF)
assign mcu_prot_a = protrom_addr;
assign protrom_q = mcu_prot_d;

//-------------------------------------------------------- VBlank IRQ ----------------------------------------------------------//

// Standard IM1 interrupt, RST 38h every vblank
// IRQ fires on vblank rising edge
reg n_irq = 1'b1;
reg vblank_last = 0;
always_ff @(posedge clk_10m) begin
    if(!reset) begin
        n_irq <= 1'b1;
        vblank_last <= 0;
    end
    else begin
        vblank_last <= video_vblank;
        // Assert IRQ on rising edge of vblank
        if(video_vblank & ~vblank_last)
            n_irq <= 1'b0;
        // Auto-clear: Z80 IM1 acknowledges via M1+IORQ
        if(~n_m1 & ~n_iorq)
            n_irq <= 1'b1;
    end
end

//-------------------------------------------------------- Video Timing --------------------------------------------------------//

// Kangaroo video timing from MAME:
// screen.set_raw(10_MHz_XTAL, 320*2, 0*2, 256*2, 260, 8, 248);
// Total: 640 pixel clocks horizontal (at 5 MHz that's 320 positions at 10 MHz)
// But the screen uses 10 MHz as raw pixel clock with 640 total, 512 visible
// Vertical: 260 lines total, visible 8-248 (240 lines)
//
// We run the pixel counter at 10 MHz (ce_pix = cen_5m for output,
// but the counters tick every clk_10m)

reg [9:0] h_cnt = 10'd0;  // 0-639
reg [8:0] v_cnt = 9'd0;   // 0-259

always_ff @(posedge clk_10m) begin
    if(!reset) begin
        h_cnt <= 0;
        v_cnt <= 0;
    end
    else begin
        if(h_cnt == 10'd639) begin
            h_cnt <= 0;
            if(v_cnt == 9'd259)
                v_cnt <= 0;
            else
                v_cnt <= v_cnt + 9'd1;
        end
        else
            h_cnt <= h_cnt + 10'd1;
    end
end

// Sync and blank generation
// Visible: x = 0*2 to 256*2-1 = 0 to 511, y = 8 to 247
// The scanout pipeline is 2 clk_10m cycles deep, so hblank/hsync are delayed to match.
// This is a latency match, not a window shift; the v axis has no such latency, so
// vblank/vsync stay combinational and the vblank IRQ uses the undelayed video_vblank.
wire video_hblank_raw = (h_cnt >= 10'd512);
// ==============================================================================
// DIAG-REVERT-2026-09-01 -- ANALOG/CRT SYNC PLACEMENT (provisional, awaiting HW report)
//
// The horizontal BLANKING BUDGET here is correct and copied from MAME
// (kangaroo.cpp: set_raw(10_MHz_XTAL, 320*2, 0*2, 256*2, 260, 8, 248) -> htotal 640,
// active 512, so 128 clocks / 12.8 us of blanking). What was wrong is where the sync
// pulse sat INSIDE that budget -- set_raw specifies the blanking window but says
// nothing about sync position, so that part was invented:
//
//   old:  front 512..559 = 48 clk = 4.8 us
//         sync  560..623 = 64 clk = 6.4 us
//         back  624..639 = 16 clk = 1.6 us   <-- runt
//
// A 15 kHz tube wants roughly front 1.5 / sync 4.7 / back 5.7 us, with the BACK porch
// the longest of the three: it is what the monitor's clamp settles on and what sets
// horizontal image position. Here it was the shortest by a factor of three. HDMI never
// sees this (ascal re-times off DE); the analog output hands the porches straight to
// the monitor. Same defect class as Vastar's 2026-09-01 raster fix.
//
//   new:  front 512..535 = 24 clk = 2.4 us   (h_center = 0)
//         sync  536..583 = 48 clk = 4.8 us
//         back  584..639 = 56 clk = 5.6 us
//
// Base is 536 rather than 528 so the OSD Screen Centering control has symmetric room:
// h_center spans +-8 pixels = +-16 h_cnt counts, giving a front porch of 8..38 clk
// (0.8..3.8 us) and a back porch of 72..42 clk (7.2..4.2 us). Every setting stays in
// spec, and the default lands within a few hundred ns of the 1.5 / 4.7 / 5.7 us
// a 15 kHz tube expects.
//
// UNCHANGED: htotal 640, pixel clock 10 MHz, line rate 15.625 kHz, frame rate 60.1 Hz,
// active area, total blanking, and all vertical timing. Only the sync pulse moved, so
// the HDMI output is bit-identical.
//
// TO REVERT: uncomment the original line below, delete the DIAG line.
// // wire video_hsync_raw  = (h_cnt >= 10'd560) & (h_cnt < 10'd624);  // ~64 clocks
// ==============================================================================
wire [9:0] hs_start = 10'd536 + {{5{h_center[3]}}, h_center, 1'b0};  // DIAG: x2, +-16 clk
wire [9:0] hs_end   = hs_start + 10'd48;                             // DIAG: 48 clk = 4.8 us
wire video_hsync_raw  = (h_cnt >= hs_start) & (h_cnt < hs_end);      // DIAG
reg [1:0] hblank_sr = 2'b11;
reg [1:0] hsync_sr  = 2'b00;
always_ff @(posedge clk_10m) begin
    hblank_sr <= {hblank_sr[0], video_hblank_raw};
    hsync_sr  <= {hsync_sr[0],  video_hsync_raw};
end
assign video_hblank = hblank_sr[1];
assign video_hsync  = hsync_sr[1];
assign video_vblank = (v_cnt < 9'd8) | (v_cnt >= 9'd248);
// DIAG-REVERT-2026-09-01: vsync made adjustable. vblank is v_cnt 248..259, so the
// 4-line pulse must start in 248..255; base 252 with a 3-bit two's complement offset
// gives exactly that range and cannot land on a visible line.
// Original, uncomment to restore:
// assign video_vsync  = (v_cnt >= 9'd252) & (v_cnt < 9'd256);     // ~4 lines
wire [8:0] vs_start = 9'd252 + {{6{v_center[2]}}, v_center};    // DIAG: +-4 lines
wire [8:0] vs_end   = vs_start + 9'd4;                          // DIAG
assign video_vsync  = (v_cnt >= vs_start) & (v_cnt < vs_end);   // DIAG

//--------------------------------------------------------- Video RAM ----------------------------------------------------------//

// Kangaroo VRAM: 16384 addresses × 32 bits (4 bytes per word, 2 planes × 4 pixels)
// Two 16-bit halves (lo = bytes 0,1, hi = bytes 2,3), each held as two byte lanes of the RAM pool
// Port A = CPU/blitter read-modify-write
// Port B = video scanout (read-only)

wire [15:0] vram_lo_qa, vram_hi_qa;   // Port A read data (CPU/blitter side)
wire [15:0] vram_lo_qb, vram_hi_qb;   // Port B read data (scanout side)
reg  [13:0] vram_addr_a;
reg  [15:0] vram_lo_da, vram_hi_da;
reg         vram_we_a;
wire [13:0] vram_addr_b;               // Scanout address (active accent accent driven by compositing logic)

assign pr_i[1].a_addr = {1'd0, vram_addr_a}; assign pr_i[1].a_d = vram_lo_da[7:0]; assign pr_i[1].a_we = vram_we_a;
assign pr_i[1].b_addr = {1'd0, vram_addr_b}; assign pr_i[1].b_d = 8'd0; assign pr_i[1].b_we = 1'b0;
assign pr_i[2].a_addr = {1'd0, vram_addr_a}; assign pr_i[2].a_d = vram_lo_da[15:8]; assign pr_i[2].a_we = vram_we_a;
assign pr_i[2].b_addr = {1'd0, vram_addr_b}; assign pr_i[2].b_d = 8'd0; assign pr_i[2].b_we = 1'b0;
assign vram_lo_qa = {pr_o[2].a_q, pr_o[1].a_q};
assign vram_lo_qb = {pr_o[2].b_q, pr_o[1].b_q};

assign pr_i[3].a_addr = {1'd0, vram_addr_a}; assign pr_i[3].a_d = vram_hi_da[7:0]; assign pr_i[3].a_we = vram_we_a;
assign pr_i[3].b_addr = {1'd0, vram_addr_b}; assign pr_i[3].b_d = 8'd0; assign pr_i[3].b_we = 1'b0;
assign pr_i[4].a_addr = {1'd0, vram_addr_a}; assign pr_i[4].a_d = vram_hi_da[15:8]; assign pr_i[4].a_we = vram_we_a;
assign pr_i[4].b_addr = {1'd0, vram_addr_b}; assign pr_i[4].b_d = 8'd0; assign pr_i[4].b_we = 1'b0;
assign vram_hi_qa = {pr_o[4].a_q, pr_o[3].a_q};
assign vram_hi_qb = {pr_o[4].b_q, pr_o[3].b_q};

// Mirror instances, written identically on port A, so plane B gets its own same-latency
// read port: plane A reads vram_lo/hi:B and plane B vram_lo2/hi2:B, aligned to one column.
wire [15:0] vram2_lo_qb, vram2_hi_qb;   // plane-B mirror scanout read data
wire [13:0] vram_addr_b2;               // plane B scanout address (mirror port B)

assign pr_i[5].a_addr = {1'd0, vram_addr_a}; assign pr_i[5].a_d = vram_lo_da[7:0]; assign pr_i[5].a_we = vram_we_a;
assign pr_i[5].b_addr = {1'd0, vram_addr_b2}; assign pr_i[5].b_d = 8'd0; assign pr_i[5].b_we = 1'b0;
assign pr_i[6].a_addr = {1'd0, vram_addr_a}; assign pr_i[6].a_d = vram_lo_da[15:8]; assign pr_i[6].a_we = vram_we_a;
assign pr_i[6].b_addr = {1'd0, vram_addr_b2}; assign pr_i[6].b_d = 8'd0; assign pr_i[6].b_we = 1'b0;
assign vram2_lo_qb = {pr_o[6].b_q, pr_o[5].b_q};
assign pr_i[7].a_addr = {1'd0, vram_addr_a}; assign pr_i[7].a_d = vram_hi_da[7:0]; assign pr_i[7].a_we = vram_we_a;
assign pr_i[7].b_addr = {1'd0, vram_addr_b2}; assign pr_i[7].b_d = 8'd0; assign pr_i[7].b_we = 1'b0;
assign pr_i[8].a_addr = {1'd0, vram_addr_a}; assign pr_i[8].a_d = vram_hi_da[15:8]; assign pr_i[8].a_we = vram_we_a;
assign pr_i[8].b_addr = {1'd0, vram_addr_b2}; assign pr_i[8].b_d = 8'd0; assign pr_i[8].b_we = 1'b0;
assign vram2_hi_qb = {pr_o[8].b_q, pr_o[7].b_q};

//------------------------------------------------ VRAM Expand/Mask Functions --------------------------------------------------//

// Video RAM write expansion — pure combinational functions
// Expand 8-bit CPU data to 32-bit (DCBADCBA → 4 bytes)
function [31:0] expand_data;
    input [7:0] data;
    reg [31:0] e;
    begin
        e = 32'd0;
        if (data[0]) e = e | 32'h00000055;
        if (data[4]) e = e | 32'h000000aa;
        if (data[1]) e = e | 32'h00005500;
        if (data[5]) e = e | 32'h0000aa00;
        if (data[2]) e = e | 32'h00550000;
        if (data[6]) e = e | 32'h00aa0000;
        if (data[3]) e = e | 32'h55000000;
        if (data[7]) e = e | 32'haa000000;
        expand_data = e;
    end
endfunction

// Build layer mask from 4-bit mask value
function [31:0] build_layermask;
    input [3:0] mask;
    reg [31:0] m;
    begin
        m = 32'd0;
        if (mask[3]) m = m | 32'h30303030;
        if (mask[2]) m = m | 32'hc0c0c0c0;
        if (mask[1]) m = m | 32'h03030303;
        if (mask[0]) m = m | 32'h0c0c0c0c;
        build_layermask = m;
    end
endfunction

//------------------------------------------------------ Blitter ROM -----------------------------------------------------------//

// 16KB blitter ROM (dispatcher ROM block): the blitter reads it here
wire [7:0] blitrom_qa;
reg  [13:0] blitrom_addr_a;


assign blitrom_a = blitrom_addr_a;
assign blitrom_qa = blitrom_d;

//------------------------------------------------------ DMA Blitter -----------------------------------------------------------//

// Pipelined read-modify-write state machine:
//   IDLE     — wait for blitter_start or CPU VRAM write
//   RMW_READ — present address to VRAM port A, wait 1 cycle for read data
//   RMW_WRITE— compute new value, write back to VRAM port A
//   BLIT_SETUP — load blitter parameters
//   BLIT_READ  — present blitrom address, wait for ROM data
//   BLIT_RMW_RD — present VRAM dest address, wait for old data
//   BLIT_RMW_WR_LO — write low-half blit result to VRAM
//   BLIT_RMW_RD2 — re-read VRAM for high-half blit
//   BLIT_RMW_WR_HI — write high-half blit result, advance to next pixel

localparam ST_IDLE        = 4'd0;
localparam ST_CPU_RMW_RD  = 4'd1;
localparam ST_CPU_RMW_WR  = 4'd2;
localparam ST_BLIT_SETUP  = 4'd3;
localparam ST_BLIT_ROMRD  = 4'd4;
localparam ST_BLIT_RMW_RD = 4'd5;
localparam ST_BLIT_RMW_WR_LO = 4'd6;
localparam ST_BLIT_RMW_RD2   = 4'd7;
localparam ST_BLIT_RMW_WR_HI = 4'd8;
localparam ST_BLIT_NEXT   = 4'd9;
localparam ST_CPU_RMW_RD2 = 4'd10;
localparam ST_BLIT_ROWSTART = 4'd11;
// blitrom_mem is dpram_dc: 2 clocks address-to-data, so the ROM reads need settle states.
localparam ST_BLIT_WAIT_LO  = 4'd12;
localparam ST_BLIT_WAIT_HI  = 4'd13;

reg [3:0]  vram_state = ST_IDLE;
reg [7:0]  blit_width;
reg [7:0]  blit_height;
reg [7:0]  blit_x_cnt;
reg [7:0]  blit_y_cnt;
reg [15:0] blit_cur_src;
reg [15:0] blit_cur_dst;
reg [7:0]  blit_adj_mask;
// The reference blitter finishes inside the $E805 write, so software issues
// the next trigger a few instructions later. Ours takes ~1200 clocks for a 28x7 sprite,
// so a trigger arriving mid-blit is queued rather than dropped. Stalling the CPU is not
// an option here: this blitter is ~6 clocks/pixel.
reg        blit_pend = 0;
reg [7:0]  pend_w, pend_h, pend_mask;
reg [15:0] pend_src, pend_dst;
reg [7:0]  blit_rom_data_lo;
reg [7:0]  blit_rom_data_hi;

// Registered copies of CPU write params (captured in IDLE)
reg [13:0] cpu_wr_addr;
reg [7:0]  cpu_wr_data;
reg [3:0]  cpu_wr_mask;

// Read-modify-write intermediates
reg [31:0] rmw_old_word;
reg [31:0] rmw_new_word;
reg [31:0] rmw_expdata;
reg [31:0] rmw_layermask;

always_ff @(posedge clk_10m) begin
    if (!reset) begin
        vram_state <= ST_IDLE;
        vram_we_a <= 0;
    end
    else begin
        vram_we_a <= 0;  // Default: no write

        // Snapshot a trigger arriving mid-blit and run it when the current blit finishes.
        // Kept in this always block so blit_pend has a single driver.
        if (blitter_start && vram_state != ST_IDLE) begin
            blit_pend <= 1'b1;
            pend_w    <= video_control[4];
            pend_h    <= video_control[5];
            pend_src  <= {video_control[1], video_control[0]};
            pend_dst  <= {video_control[3], video_control[2]};
            pend_mask <= video_control[8];
        end

        case (vram_state)
            ST_IDLE: begin
                if (blitter_start || blit_pend) begin
                    // Take a queued trigger if one is waiting.
                    blit_width   <= blitter_start ? video_control[4] : pend_w;
                    blit_height  <= blitter_start ? video_control[5] : pend_h;
                    blit_cur_src <= blitter_start ? {video_control[1], video_control[0]} : pend_src;
                    blit_cur_dst <= blitter_start ? {video_control[3], video_control[2]} : pend_dst;
                    blit_x_cnt  <= 0;
                    blit_y_cnt  <= 0;
                    blit_adj_mask <= blitter_start ? video_control[8] : pend_mask;
                    if (!blitter_start) blit_pend <= 1'b0;   // consumed the queued one
                    vram_state <= ST_BLIT_SETUP;
                end
                else if (cs_videoram & ~n_wr) begin
                    // CPU VRAM write — start RMW cycle
                    cpu_wr_addr <= cpu_A[13:0];
                    cpu_wr_data <= cpu_Dout;
                    cpu_wr_mask <= video_control[8][3:0];
                    vram_addr_a <= cpu_A[13:0];  // Present read address
                    vram_state <= ST_CPU_RMW_RD;
                end
            end

            //--- CPU VRAM write (3-cycle RMW: addr → wait → read+compute → write) ---
            ST_CPU_RMW_RD: begin
                // Address was presented last cycle. dpram output will be valid NEXT cycle.
                // Pre-compute expand/mask while waiting for RAM.
                rmw_expdata  <= expand_data(cpu_wr_data);
                rmw_layermask <= build_layermask(cpu_wr_mask);
                vram_state <= ST_CPU_RMW_RD2;
            end

            ST_CPU_RMW_RD2: begin
                // NOW the dpram output is valid — latch it
                rmw_old_word <= {vram_hi_qa, vram_lo_qa};
                vram_state <= ST_CPU_RMW_WR;
            end

            ST_CPU_RMW_WR: begin
                rmw_new_word = (rmw_old_word & ~rmw_layermask) | (rmw_expdata & rmw_layermask);
                vram_addr_a <= cpu_wr_addr;
                vram_lo_da <= rmw_new_word[15:0];
                vram_hi_da <= rmw_new_word[31:16];
                vram_we_a  <= 1;
                vram_state <= ST_IDLE;
            end

            //--- Blitter DMA ---
            ST_BLIT_SETUP: begin
                // Adjust mask: OR top/bottom 2-bit pairs during DMA
                if (blit_adj_mask[3:2] != 0) blit_adj_mask[3:2] <= 2'b11;
                if (blit_adj_mask[1:0] != 0) blit_adj_mask[1:0] <= 2'b11;
                // Start first pixel: present low-half ROM addr
                blitrom_addr_a <= {1'b0, blit_cur_src[12:0]};
                vram_state <= ST_BLIT_WAIT_LO;
            end

            // Settle state: the LOW-half ROM read needs 2 clocks (addr-reg + read).
            ST_BLIT_WAIT_LO: begin
                vram_state <= ST_BLIT_ROMRD;
            end

            ST_BLIT_ROMRD: begin
                // LOW-half ROM data valid; present the HIGH-half and VRAM read addresses.
                blit_rom_data_lo <= blitrom_qa;
                blitrom_addr_a <= {1'b1, blit_cur_src[12:0]};
                vram_addr_a <= (blit_cur_dst[13:0] + {6'd0, blit_x_cnt}) & 14'h3FFF;
                vram_state <= ST_BLIT_WAIT_HI;
            end

            // Settle state: the HIGH-half ROM and VRAM reads need 2 clocks.
            ST_BLIT_WAIT_HI: begin
                vram_state <= ST_BLIT_RMW_RD;
            end

            ST_BLIT_RMW_RD: begin
                // HIGH-half ROM and VRAM read-back both valid, on the same source pixel as LOW.
                blit_rom_data_hi <= blitrom_qa;
                rmw_old_word     <= {vram_hi_qa, vram_lo_qa};
                vram_state <= ST_BLIT_RMW_WR_LO;
            end

            // No longer reached: the VRAM capture is merged into ST_BLIT_ROMRD above.
            ST_BLIT_RMW_RD2: begin
                rmw_old_word <= {vram_hi_qa, vram_lo_qa};
                vram_state <= ST_BLIT_RMW_WR_LO;
            end

            ST_BLIT_RMW_WR_LO: begin
                // clear pixel first
                rmw_expdata   = 32'h00000000;
                rmw_layermask = build_layermask(blit_adj_mask[3:0]);
                // Apply low-half blit: LOW-half ROM pairs with mask & 0x05
                rmw_expdata   = expand_data(blit_rom_data_lo);
                rmw_layermask = build_layermask(blit_adj_mask[3:0] & 4'b0101);
                rmw_new_word  = (rmw_old_word & ~rmw_layermask) | (rmw_expdata & rmw_layermask);
                // Now apply high-half blit: HIGH-half ROM pairs with mask & 0x0a
                rmw_expdata   = expand_data(blit_rom_data_hi);
                rmw_layermask = build_layermask(blit_adj_mask[3:0] & 4'b1010);
                rmw_new_word  = (rmw_new_word & ~rmw_layermask) | (rmw_expdata & rmw_layermask);
                // Write back
                vram_addr_a <= (blit_cur_dst[13:0] + {6'd0, blit_x_cnt}) & 14'h3FFF;
                vram_lo_da  <= rmw_new_word[15:0];
                vram_hi_da  <= rmw_new_word[31:16];
                vram_we_a   <= 1;
                vram_state  <= ST_BLIT_NEXT;
            end

            ST_BLIT_NEXT: begin
                // Advance to next pixel
                blit_cur_src <= blit_cur_src + 16'd1;
                if (blit_x_cnt == blit_width) begin
                    blit_x_cnt <= 0;
                    if (blit_y_cnt == blit_height) begin
                        vram_state <= ST_IDLE;  // Done
                    end
                    else begin
                        blit_y_cnt  <= blit_y_cnt + 8'd1;
                        blit_cur_dst <= blit_cur_dst + 16'd256;
                        // Start next row: read ROM for first pixel
                        blitrom_addr_a <= {1'b0, (blit_cur_src + 16'd1) & 16'h1FFF};
                        vram_state <= ST_BLIT_ROWSTART;
                    end
                end
                else begin
                    blit_x_cnt <= blit_x_cnt + 8'd1;
                    // Start next pixel: present LOW-half ROM addr
                    blitrom_addr_a <= {1'b0, (blit_cur_src + 16'd1) & 16'h1FFF};
                    vram_state <= ST_BLIT_WAIT_LO;
                end
            end

            ST_BLIT_ROWSTART: begin
                // blit_cur_dst is now settled — proceed to ROM read
                vram_state <= ST_BLIT_ROMRD;
            end

            default: vram_state <= ST_IDLE;
        endcase
    end
end

//----------------------------------------------- Pixel Compositing (screen_update) --------------------------------------------//

// Screen-update variables derived from the video_control registers
wire [7:0] scrolly = video_control[6];
wire [7:0] scrollx = video_control[7];
wire [2:0] maska = (video_control[10] & 8'h28) >> 3;
wire [2:0] maskb =  video_control[10][2:0];
// FLIP A / FLIP B (video_control[9] bits 5/4), XORed with the OSD
// CRT Flip so it reuses the game's own mirror rather than adding a second one.
wire [7:0] xora = (video_control[9][5] ^ crt_flip) ? 8'hFF : 8'h00;
wire [7:0] xorb = (video_control[9][4] ^ crt_flip) ? 8'hFF : 8'h00;
wire       enaa = video_control[9][3];
wire       enab = video_control[9][2];
wire       pria = ~video_control[9][1];
wire       prib = ~video_control[9][0];

// Current scanout position (used for address)
wire [8:0] scan_x = h_cnt[9:1];
wire [7:0] scan_y = v_cnt[7:0];

// Scanout is native: 256 source columns 1:1, the doubling happens in arcade_video.
wire [7:0] effxa = scrollx + (scan_x[7:0] ^ xora);
wire [7:0] effya = scrolly + (scan_y ^ xora);
wire [7:0] effxb = scan_x[7:0] ^ xorb;
wire [7:0] effyb = scan_y ^ xorb;

// Scanout pipeline: both planes are read every cycle on their own same-latency ports, and
// the slice indices are delayed one cycle to match the DPRAM read, so the planes stay aligned.

reg [31:0] scan_word_a, scan_word_b;
reg [1:0]  scan_effxa_slice, scan_effxb_slice;

wire [13:0] scan_addr_a_w = {effxa[7:2], effya};
wire [13:0] scan_addr_b_w = {effxb[7:2], effyb};

assign vram_addr_b  = scan_addr_a_w;   // plane A read port (vram_lo/hi:B)
assign vram_addr_b2 = scan_addr_b_w;   // plane B read port (vram_lo2/hi2:B)

reg [1:0] effxa_slice_hold, effxb_slice_hold;

always_ff @(posedge clk_10m) begin
    // capture this cycle's slice indices (for the addresses presented this cycle)
    effxa_slice_hold <= effxa[1:0];
    effxb_slice_hold <= effxb[1:0];
    // latch both planes together: q_b holds data for the address presented LAST cycle (1-cycle DPRAM
    // latency), and the matching last-cycle slice → plane A and plane B aligned to the SAME column.
    scan_word_a      <= {vram_hi_qb,  vram_lo_qb};
    scan_word_b      <= {vram2_hi_qb, vram2_lo_qb};
    scan_effxa_slice <= effxa_slice_hold;
    scan_effxb_slice <= effxb_slice_hold;
end

// Extract pixel bytes from latched 32-bit words
wire [7:0] vram_slice_a = (scan_effxa_slice == 2'd0) ? scan_word_a[7:0] :
                          (scan_effxa_slice == 2'd1) ? scan_word_a[15:8] :
                          (scan_effxa_slice == 2'd2) ? scan_word_a[23:16] :
                                                       scan_word_a[31:24];

wire [7:0] vram_slice_b = (scan_effxb_slice == 2'd0) ? scan_word_b[7:0] :
                          (scan_effxb_slice == 2'd1) ? scan_word_b[15:8] :
                          (scan_effxb_slice == 2'd2) ? scan_word_b[23:16] :
                                                       scan_word_b[31:24];

wire [3:0] pixa_raw = vram_slice_a[3:0];   // Plane A = low nibble
wire [3:0] pixb_raw = vram_slice_b[7:4];   // Plane B = high nibble

// Priority compositing
// Even pixels (first of pair): full brightness, no KOS1 masking
// Odd pixels (second of pair): apply KOS1 color mask for Z=0 pixels
// arcade_video samples the core's RGB once per h_cnt at ce_pix_2x, so consecutive display
// pixels share scan_x and h_cnt[0] is the doubled-pixel parity driving the KOS1 alternation.
wire is_odd_pixel = h_cnt[0];

wire [3:0] pixa_masked = (is_odd_pixel && !(pixa_raw[3])) ? (pixa_raw & {1'b0, maska}) : pixa_raw;
wire [3:0] pixb_masked = (is_odd_pixel && !(pixb_raw[3])) ? (pixb_raw & {1'b0, maskb}) : pixb_raw;

wire [3:0] pixa_final = is_odd_pixel ? pixa_masked : pixa_raw;
wire [3:0] pixb_final = is_odd_pixel ? pixb_masked : pixb_raw;

reg [2:0] final_color;
always_comb begin
    final_color = 3'd0;
    if (enaa && (pria || pixb_raw == 0))
        final_color = final_color | pixa_final[2:0];
    if (enab && (prib || pixa_final == 0))
        final_color = final_color | pixb_final[2:0];
end

// Output — BGR 3-bit palette
wire active_video = ~video_hblank & ~video_vblank;
assign video_r = active_video ? {final_color[2], final_color[2], final_color[2]} : 3'd0;
assign video_g = active_video ? {final_color[1], final_color[1], final_color[1]} : 3'd0;
assign video_b = active_video ? {final_color[0], final_color[0]} : 2'd0;

// pooled CPU inputs, assigned after every signal they read is declared
assign z80_0_i.reset_n = reset; assign z80_0_i.ce = cen_2m5 & ~pause; assign z80_0_i.int_n = n_irq; assign z80_0_i.nmi_n = n_nmi;
assign z80_0_i.di = cpu_Din;
assign mb88_0_i.ena = mcu_ena; assign mb88_0_i.reset_n = mcu_reset_n; assign mb88_0_i.k = mcu_k;
assign mb88_0_i.r_in = {r3_out, r2_out, r1_out, r0_out};   // R ports read back their own latches
assign mb88_0_i.irq_n = 1'b1; assign mb88_0_i.tc_n = 1'b1; assign mb88_0_i.si_n = 1'b1; assign mb88_0_i.rom_d = mcu_rom_q;

endmodule
