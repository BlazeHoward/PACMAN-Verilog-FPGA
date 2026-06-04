`timescale 1ns / 1ps
`ifndef GAME_DEFINES_1
`include "game_defines.v"
`endif

module MAP #(
    parameter MAX_WIDTH  = 19,
    parameter MAX_HEIGHT = 21
)(
    input  wire        clk_100M,
    input  wire        rst_n,
    input  wire [1:0]  difficulty,

    output reg  [4:0]  curr_width,
    output reg  [4:0]  curr_height,

    input  wire [4:0]  vga_rd_x,
    input  wire [4:0]  vga_rd_y,
    output wire [2:0]  vga_rd_data,
	 
	 input  wire        map_reset,

    input  wire        logic_en,
    input  wire        logic_wr_en,
    input  wire [4:0]  logic_addr_x,
    input  wire [4:0]  logic_addr_y,
    output wire [2:0]  logic_rd_data,

    input  wire        refresh_pulse,
    input  wire [15:0] random_seed,
    output wire        refresh_done,

    output reg  [4:0]  pac_spawn_x,
    output reg  [4:0]  pac_spawn_y,
    output reg  [4:0]  ghost_spawn_x,
    output reg  [4:0]  ghost_spawn_y
);

    //========================================================================
    // 1. 难度参数寄存
    //========================================================================
    reg [1:0] diff_reg;

    always @(posedge clk_100M or negedge rst_n) begin
        if (!rst_n)
            diff_reg <= 2'd0;
        else
            diff_reg <= difficulty;
    end

    //========================================================================
    // 2. 地图尺寸
    //========================================================================
    always @(posedge clk_100M or negedge rst_n) begin
        if (!rst_n) begin
            curr_width  <= 5'd8;
            curr_height <= 5'd8;
        end else begin
            case (diff_reg)
                2'd2: begin
                    curr_width  <= 5'd19;
                    curr_height <= 5'd21;
                end

                2'd1: begin
                    curr_width  <= 5'd15;
                    curr_height <= 5'd15;
                end

                default: begin
                    curr_width  <= 5'd8;
                    curr_height <= 5'd8;
                end
            endcase
        end
    end

    //========================================================================
    // 3. 地址计算参数
    //========================================================================
    localparam MAP_SIMPLE_BASE = 0;
    localparam MAP_MED_BASE    = 64;
    localparam MAP_HARD_BASE   = 289;
    localparam MAP_TOTAL_CELLS = 688;

    //========================================================================
    // 4. BRAM 存储器
    //========================================================================
    (* ram_init_file = "maze_map.mif", ramstyle = "M9K, no_rw_check" *)
    reg [2:0] rom_mem [0:MAP_TOTAL_CELLS-1];

    //========================================================================
    // 5. 流水线地址计算
    //========================================================================
    wire [4:0] vga_y_factor =
        (diff_reg == 2'd2) ? 5'd19 :
        (diff_reg == 2'd1) ? 5'd15 :
                             5'd8;

    wire [4:0] logic_y_factor =
        (diff_reg == 2'd2) ? 5'd19 :
        (diff_reg == 2'd1) ? 5'd15 :
                             5'd8;

    wire [8:0] vga_local_addr_comb  = vga_rd_y * vga_y_factor + vga_rd_x;
    wire [8:0] logic_local_addr_comb = logic_addr_y * logic_y_factor + logic_addr_x;

    // 第一级流水线 P1
    reg [8:0] vga_local_addr_p1;
    reg [8:0] logic_local_addr_p1;
    reg       logic_en_p1;
    reg [4:0] logic_x_p1;
    reg [4:0] logic_y_p1;

    reg [4:0] vga_x_p1;
    reg [4:0] vga_y_p1;

    always @(posedge clk_100M) begin
        vga_local_addr_p1   <= vga_local_addr_comb;
        logic_local_addr_p1 <= logic_local_addr_comb;

        logic_en_p1         <= logic_en;
        logic_x_p1          <= logic_addr_x;
        logic_y_p1          <= logic_addr_y;

        vga_x_p1            <= vga_rd_x;
        vga_y_p1            <= vga_rd_y;
    end

    wire [9:0] vga_addr_comb =
        (diff_reg == 2'd2) ? (MAP_HARD_BASE + vga_local_addr_p1) :
        (diff_reg == 2'd1) ? (MAP_MED_BASE  + vga_local_addr_p1) :
                             (MAP_SIMPLE_BASE + vga_local_addr_p1);

    wire [9:0] logic_addr_comb =
        (diff_reg == 2'd2) ? (MAP_HARD_BASE + logic_local_addr_p1) :
        (diff_reg == 2'd1) ? (MAP_MED_BASE  + logic_local_addr_p1) :
                             (MAP_SIMPLE_BASE + logic_local_addr_p1);

    // 第二级流水线 P2
    reg [9:0] vga_addr_reg;
    reg [9:0] logic_addr_reg;
    reg       logic_en_p2;
    reg [4:0] logic_x_p2;
    reg [4:0] logic_y_p2;
    reg       overlay_vga_p2;
    reg       overlay_logic_p2;

    reg [4:0] vga_x_p2;
    reg [4:0] vga_y_p2;

    always @(posedge clk_100M) begin
        vga_addr_reg     <= vga_addr_comb;
        logic_addr_reg   <= logic_addr_comb;

        logic_en_p2      <= logic_en_p1;
        logic_x_p2       <= logic_x_p1;
        logic_y_p2       <= logic_y_p1;

        overlay_vga_p2   <= overlay[vga_local_addr_p1];
        overlay_logic_p2 <= overlay[logic_local_addr_p1];

        vga_x_p2         <= vga_x_p1;
        vga_y_p2         <= vga_y_p1;
    end

    //========================================================================
    // 6. 流水线第三级 P3
    //========================================================================
    reg [2:0] rom_data_vga_p3;
    reg [2:0] rom_data_logic_p3;
    reg       overlay_bit_vga_p3;
    reg       overlay_bit_logic_p3;
    reg       vga_valid_p3;
    reg       logic_valid_p3;

    reg [4:0] vga_x_p3;
    reg [4:0] vga_y_p3;

    always @(posedge clk_100M) begin
        rom_data_vga_p3      <= rom_mem[vga_addr_reg];
        rom_data_logic_p3    <= rom_mem[logic_addr_reg];

        overlay_bit_vga_p3   <= overlay_vga_p2;
        overlay_bit_logic_p3 <= overlay_logic_p2;

        vga_x_p3             <= vga_x_p2;
        vga_y_p3             <= vga_y_p2;

        vga_valid_p3         <= (vga_x_p2 < curr_width) &&
                                (vga_y_p2 < curr_height);

        logic_valid_p3       <= (logic_x_p2 < curr_width) &&
                                (logic_y_p2 < curr_height) &&
                                logic_en_p2;
    end

    //========================================================================
    // 7. 自动从 maze_map.mif 读取出生点
    //========================================================================
    reg [1:0] spawn_diff_reg;
    reg       pac_spawn_found;
    reg       ghost_spawn_found;

    always @(posedge clk_100M or negedge rst_n) begin
        if (!rst_n) begin
            spawn_diff_reg    <= 2'd0;
            pac_spawn_found   <= 1'b0;
            ghost_spawn_found <= 1'b0;

            // 默认保底值：简单难度
            pac_spawn_x       <= 5'd1;
            pac_spawn_y       <= 5'd1;
            ghost_spawn_x     <= 5'd6;
            ghost_spawn_y     <= 5'd1;
        end else begin
            // 难度变化时，先给一个保底出生点，然后等待 VGA 扫描地图时自动找到 4 和 5
            if (diff_reg != spawn_diff_reg) begin
                spawn_diff_reg    <= diff_reg;
                pac_spawn_found   <= 1'b0;
                ghost_spawn_found <= 1'b0;

                case (diff_reg)
                    2'd2: begin
                        pac_spawn_x   <= 5'd9;
                        pac_spawn_y   <= 5'd9;
                        ghost_spawn_x <= 5'd9;
                        ghost_spawn_y <= 5'd8;
                    end

                    2'd1: begin
                        pac_spawn_x   <= 5'd1;
                        pac_spawn_y   <= 5'd13;
                        ghost_spawn_x <= 5'd7;
                        ghost_spawn_y <= 5'd7;
                    end

                    default: begin
                        pac_spawn_x   <= 5'd1;
                        pac_spawn_y   <= 5'd1;
                        ghost_spawn_x <= 5'd6;
                        ghost_spawn_y <= 5'd1;
                    end
                endcase
            end else begin
                // 这里用的是 rom_data_vga_p3，也就是 MIF 原始地图数据
                // 即使后面输出时把 4/5 替换成 EMPTY，这里仍然能检测到出生点
                if (vga_valid_p3 && !pac_spawn_found &&
                    rom_data_vga_p3 == `MAP_PAC_SPAWN) begin
                    pac_spawn_x     <= vga_x_p3;
                    pac_spawn_y     <= vga_y_p3;
                    pac_spawn_found <= 1'b1;
                end

                if (vga_valid_p3 && !ghost_spawn_found &&
                    rom_data_vga_p3 == `MAP_GHOST_SPAWN) begin
                    ghost_spawn_x     <= vga_x_p3;
                    ghost_spawn_y     <= vga_y_p3;
                    ghost_spawn_found <= 1'b1;
                end
            end
        end
    end

    //========================================================================
    // 8. Overlay 寄存器及辅助函数
    // overlay[x] = 1 表示这个格子的豆子/药丸已经被吃掉，需要显示为空
    //========================================================================
    localparam OVERLAY_SIZE = 19 * 21;
    reg [OVERLAY_SIZE-1:0] overlay;

    function [8:0] get_local_addr;
        input [1:0] diff;
        input [4:0] x;
        input [4:0] y;
        reg [8:0] tmp;
        begin
            case (diff)
                2'd2: tmp = (y << 4) + (y << 1) + y + x; // y*19+x
                2'd1: tmp = (y << 4) - y + x;            // y*15+x
                default: tmp = (y << 3) + x;             // y*8+x
            endcase

            get_local_addr = tmp;
        end
    endfunction

    task init_overlay;
        input [1:0] diff;
        begin
            overlay = 0;

            case (diff)
                2'd1: begin
                    overlay[get_local_addr(2'd1, 5'd2,  5'd2)]  = 0;
                    overlay[get_local_addr(2'd1, 5'd12, 5'd2)]  = 0;
                    overlay[get_local_addr(2'd1, 5'd2,  5'd12)] = 0;
                    overlay[get_local_addr(2'd1, 5'd12, 5'd12)] = 0;
                end

                2'd2: begin
                    overlay[get_local_addr(2'd2, 5'd3,  5'd3)]  = 0;
                    overlay[get_local_addr(2'd2, 5'd15, 5'd3)]  = 0;
                    overlay[get_local_addr(2'd2, 5'd3,  5'd17)] = 0;
                    overlay[get_local_addr(2'd2, 5'd15, 5'd17)] = 0;
                    overlay[get_local_addr(2'd2, 5'd9,  5'd5)]  = 0;
                    overlay[get_local_addr(2'd2, 5'd9,  5'd15)] = 0;
                end

                default: begin
                    overlay = 0;
                end
            endcase
        end
    endtask

    //========================================================================
    // 9. 药丸坐标查找函数
    //========================================================================
    function [4:0] get_med_pill_x;
        input [1:0] idx;
        begin
            case (idx)
                2'd0: get_med_pill_x = 5'd2;
                2'd1: get_med_pill_x = 5'd12;
                2'd2: get_med_pill_x = 5'd2;
                2'd3: get_med_pill_x = 5'd12;
                default: get_med_pill_x = 5'd2;
            endcase
        end
    endfunction

    function [4:0] get_med_pill_y;
        input [1:0] idx;
        begin
            case (idx)
                2'd0: get_med_pill_y = 5'd2;
                2'd1: get_med_pill_y = 5'd2;
                2'd2: get_med_pill_y = 5'd12;
                2'd3: get_med_pill_y = 5'd12;
                default: get_med_pill_y = 5'd2;
            endcase
        end
    endfunction

    function [4:0] get_hard_pill_x;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: get_hard_pill_x = 5'd3;
                3'd1: get_hard_pill_x = 5'd15;
                3'd2: get_hard_pill_x = 5'd3;
                3'd3: get_hard_pill_x = 5'd15;
                3'd4: get_hard_pill_x = 5'd9;
                3'd5: get_hard_pill_x = 5'd9;
                default: get_hard_pill_x = 5'd3;
            endcase
        end
    endfunction

    function [4:0] get_hard_pill_y;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: get_hard_pill_y = 5'd3;
                3'd1: get_hard_pill_y = 5'd3;
                3'd2: get_hard_pill_y = 5'd17;
                3'd3: get_hard_pill_y = 5'd17;
                3'd4: get_hard_pill_y = 5'd5;
                3'd5: get_hard_pill_y = 5'd15;
                default: get_hard_pill_y = 5'd3;
            endcase
        end
    endfunction

    //========================================================================
    // 10. 刷新状态机
    //========================================================================
    reg       refresh_wr_en;
    reg [8:0] refresh_addr;
    reg       refresh_busy;
    reg       refresh_done_reg;
    reg [2:0] refresh_state;

    localparam REF_IDLE     = 3'd0;
    localparam REF_CLEAR    = 3'd1;
    localparam REF_GEN_RAND = 3'd2;
    localparam REF_WRITE    = 3'd3;
    localparam REF_DONE     = 3'd4;

    reg [1:0] med_pill_idx;
    reg [2:0] hard_pill_rand;
    reg [15:0] lfsr;

    wire lfsr_fb = lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10];

    always @(posedge clk_100M or negedge rst_n) begin
        if (!rst_n) begin
            refresh_wr_en    <= 1'b0;
            refresh_addr     <= 9'd0;
            refresh_busy     <= 1'b0;
            refresh_done_reg <= 1'b0;
            refresh_state    <= REF_IDLE;
            med_pill_idx     <= 2'd0;
            hard_pill_rand   <= 3'd0;
            lfsr             <= 16'hACE1;
        end else begin
            lfsr <= {lfsr[14:0], lfsr_fb};

            case (diff_reg)
                2'd0: begin
                    refresh_busy     <= 1'b0;
                    refresh_done_reg <= 1'b0;
                    refresh_state    <= REF_IDLE;
                    refresh_wr_en    <= 1'b0;
                end

                2'd1: begin
                    case (refresh_state)
                        REF_IDLE: begin
                            refresh_wr_en    <= 1'b0;
                            refresh_done_reg <= 1'b0;

                            if (refresh_pulse && !refresh_busy) begin
                                refresh_state <= REF_CLEAR;
                                refresh_busy  <= 1'b1;
                            end
                        end

                        REF_CLEAR: begin
                            refresh_addr <= get_local_addr(
                                2'd1,
                                get_med_pill_x(med_pill_idx),
                                get_med_pill_y(med_pill_idx)
                            );
                            refresh_wr_en <= 1'b1;
                            refresh_state <= REF_GEN_RAND;
                        end

                        REF_GEN_RAND: begin
                            med_pill_idx  <= (med_pill_idx == 2'd3) ? 2'd0 : med_pill_idx + 2'd1;
                            refresh_state <= REF_WRITE;
                        end

                        REF_WRITE: begin
                            refresh_addr <= get_local_addr(
                                2'd1,
                                get_med_pill_x(med_pill_idx),
                                get_med_pill_y(med_pill_idx)
                            );
                            refresh_wr_en <= 1'b1;
                            refresh_state <= REF_DONE;
                        end

                        REF_DONE: begin
                            refresh_wr_en    <= 1'b0;
                            refresh_done_reg <= 1'b1;
                            refresh_busy     <= 1'b0;
                            refresh_state    <= REF_IDLE;
                        end

                        default: begin
                            refresh_wr_en    <= 1'b0;
                            refresh_done_reg <= 1'b0;
                            refresh_busy     <= 1'b0;
                            refresh_state    <= REF_IDLE;
                        end
                    endcase
                end

                2'd2: begin
                    case (refresh_state)
                        REF_IDLE: begin
                            refresh_wr_en    <= 1'b0;
                            refresh_done_reg <= 1'b0;

                            if (refresh_pulse && !refresh_busy) begin
                                hard_pill_rand <= lfsr[2:0];
                                refresh_state  <= REF_CLEAR;
                                refresh_busy   <= 1'b1;
                            end
                        end

                        REF_CLEAR: begin
                            refresh_addr <= get_local_addr(
                                2'd2,
                                get_hard_pill_x(hard_pill_rand),
                                get_hard_pill_y(hard_pill_rand)
                            );
                            refresh_wr_en <= 1'b1;
                            refresh_state <= REF_GEN_RAND;
                        end

                        REF_GEN_RAND: begin
                            hard_pill_rand <= lfsr[2:0];
                            refresh_state  <= REF_WRITE;
                        end

                        REF_WRITE: begin
                            refresh_addr <= get_local_addr(
                                2'd2,
                                get_hard_pill_x(hard_pill_rand),
                                get_hard_pill_y(hard_pill_rand)
                            );
                            refresh_wr_en <= 1'b1;
                            refresh_state <= REF_DONE;
                        end

                        REF_DONE: begin
                            refresh_wr_en    <= 1'b0;
                            refresh_done_reg <= 1'b1;
                            refresh_busy     <= 1'b0;
                            refresh_state    <= REF_IDLE;
                        end

                        default: begin
                            refresh_wr_en    <= 1'b0;
                            refresh_done_reg <= 1'b0;
                            refresh_busy     <= 1'b0;
                            refresh_state    <= REF_IDLE;
                        end
                    endcase
                end

                default: begin
                    refresh_wr_en    <= 1'b0;
                    refresh_done_reg <= 1'b0;
                    refresh_busy     <= 1'b0;
                    refresh_state    <= REF_IDLE;
                end
            endcase
        end
    end

    assign refresh_done = refresh_done_reg;

   //========================================================================
    // 11. Overlay 写操作 (修复重玩不刷新豆子、导致无法胜利的 Bug)
    //========================================================================
    wire [8:0] overlay_logic_addr  = get_local_addr(diff_reg, logic_addr_x, logic_addr_y);
    wire [8:0] overlay_refresh_addr = refresh_addr;

    always @(posedge clk_100M or negedge rst_n) begin
        if (!rst_n) begin
            overlay <= 0;
        end else if (map_reset) begin
            overlay <= 0; // 【核心修复】收到新游戏信号，清空被吃记录，全图豆子瞬间复活！
        end else begin
            if (logic_en && logic_wr_en && overlay_logic_addr < OVERLAY_SIZE) begin
                overlay[overlay_logic_addr] <= 1'b1;
            end else if (refresh_wr_en && overlay_refresh_addr < OVERLAY_SIZE) begin
                overlay[overlay_refresh_addr] <= 1'b0;
            end
        end
    end

    //========================================================================
    // 12. 流水线第四级：合并输出
    //========================================================================
    reg [2:0] vga_rd_data_reg;
    reg [2:0] logic_rd_data_reg;

    wire vga_replace_empty =
        overlay_bit_vga_p3 ||
        (rom_data_vga_p3 == `MAP_PAC_SPAWN) ||
        (rom_data_vga_p3 == `MAP_GHOST_SPAWN);

    wire logic_replace_empty =
        overlay_bit_logic_p3 ||
        (rom_data_logic_p3 == `MAP_PAC_SPAWN) ||
        (rom_data_logic_p3 == `MAP_GHOST_SPAWN);

    always @(posedge clk_100M) begin
        vga_rd_data_reg   <= vga_valid_p3 ?
                             (vga_replace_empty ? `MAP_EMPTY : rom_data_vga_p3) :
                             `MAP_WALL;

        logic_rd_data_reg <= logic_valid_p3 ?
                             (logic_replace_empty ? `MAP_EMPTY : rom_data_logic_p3) :
                             `MAP_WALL;
    end

    assign vga_rd_data   = vga_rd_data_reg;
    assign logic_rd_data = logic_rd_data_reg;

endmodule
