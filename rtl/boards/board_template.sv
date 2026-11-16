//============================================================================
//  board_template.sv - start a new Kangaroo-core board by copying this file (NOT in files.qip, never compiled).
//  Copyright (C) 2026 Rodimus
//
//  Boards never instantiate a CPU, MCU, sound chip, ROM store or board RAM. They live ONCE in the dispatcher
//  rtl/kangaroo_dispatcher.sv: Z80s z80_0 (main) / z80_1 (sound) on z80r_* buses, MB8841 mb88_0 (mb88_*), AY-3-8910 ay_0
//  (ayr_i_t / ay_o_t), the ROM blocks (program rom0-5 and the CPU's blitter window blit0-3 on rom_cpu_a, the blitter's
//  16K copy, MB8841 program + protection PROM, sound ROM; loaded by ioctl index and address through
//  rtl/ram_rom/rom_loader.sv) and the board RAM pool: dual-port pr 0-8 (1K work RAM, 16K VRAM byte lanes x 8) and the
//  single-port sp 0 (1K sound RAM, port A of pram_i_t).
//  To add a board: copy this file to rtl/boards/<board>/<board>.sv, add it to files.qip + verilator/Makefile,
//  instance it in the dispatcher, put its buses on the pools there and tie what it doesn't use to '0. A RAM bigger
//  than its block = grow the block, never a private dpram_dc / spram. ROM images: load decode by ioctl index and
//  address only, NEVER by a game flag. A RAM / chip that truly can't pool = "// POOL-EXCEPTION: <reason>" on its
//  instance line + a Pool contract row (Claude/ vault note). verilator/common/pool_check.sh (POOL_MODS) enforces it.
//============================================================================

module board_template
(
    input  logic        clk,            // 10 MHz
    input  logic        reset,          // core reset | this board inactive
    input  logic        pause,

    output chip_pool_pkg::z80r_i_t z80_1_i,
    input  chip_pool_pkg::z80r_o_t z80_1_o,
    output chip_pool_pkg::ayr_i_t  ay_0_i,
    input  chip_pool_pkg::ay_o_t   ay_0_o,

    output logic [11:0] snd_rom_a,      // sound ROM block read port
    input  logic  [7:0] snd_rom_d,

    output ram_pool_pkg::pram_i_t  sp_i,
    input  ram_pool_pkg::pram_o_t  sp_o,

    output logic signed [15:0] sound_out
);

assign z80_1_i   = '0;
assign ay_0_i    = '0;
assign snd_rom_a = 12'd0;
assign sp_i      = '0;
assign sound_out = 16'sd0;

endmodule
