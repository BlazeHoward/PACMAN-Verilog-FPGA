`timescale 1ns / 1ps
`include "game_defines.v"

module VGA_Renderer #(
    parameter BLOCK_SIZE = 16
)(
    input  wire        clk_100M,
    input  wire        rst_n,
    input  wire [1:0]  difficulty,

    output wire [4:0]  vga_addr_x,
    output wire [4:0]  vga_addr_y,
    input  wire [2:0]  vga_map_data,

    input  wire [4:0]  pac_x, pac_y,
	 input  wire [1:0]  pac_dir,
    input  wire [4:0]  ghost0_x, ghost0_y,
    input  wire [4:0]  ghost1_x, ghost1_y,
    input  wire [4:0]  ghost2_x, ghost2_y,
    input  wire [4:0]  ghost3_x, ghost3_y,
    input  wire        power_active,
	 input  wire [9:0]  power_counter,
    input  wire        pill_blink,
    input  wire [2:0]  game_state,

    // 新增：菜单选择与分数显示
    input  wire [1:0]  menu_sel,
    input  wire [15:0] score_bcd,

    output wire        vga_clk_out,
    output wire        vga_hs,
    output wire        vga_vs,
    output wire        vga_blank_n,
    output wire        vga_sync_n,
    output reg  [7:0]  vga_r,
    output reg  [7:0]  vga_g,
    output reg  [7:0]  vga_b
);

    //========================================================================
    // 1. 100MHz -> 25MHz VGA 像素节拍（保持原样）
    //========================================================================
    reg [1:0] clk_div;
    wire pixel_en = (clk_div == 2'b11);

    always @(posedge clk_100M or negedge rst_n) begin
        if (!rst_n)
            clk_div <= 2'd0;
        else
            clk_div <= clk_div + 2'd1;
    end

    assign vga_clk_out = clk_div[1];

    //========================================================================
    // 2. VGA 640x480@60Hz 时序参数（保持原样）
    //========================================================================
    localparam H_SYNC  = 96;
    localparam H_BACK  = 48;
    localparam H_DISP  = 640;
    localparam H_FRONT = 16;
    localparam H_TOTAL = 800;

    localparam V_SYNC  = 2;
    localparam V_BACK  = 33;
    localparam V_DISP  = 480;
    localparam V_FRONT = 10;
    localparam V_TOTAL = 525;

    //========================================================================
    // 3. 游戏地图尺寸（保持原样）
    //========================================================================
    localparam TILE_SHIFT = 4;
    localparam TILE_SIZE  = 16;

    wire [9:0] game_w = (difficulty == 2'd2) ? 10'd304 :
                        (difficulty == 2'd1) ? 10'd240 : 10'd128;

    wire [9:0] game_h = (difficulty == 2'd2) ? 10'd336 :
                        (difficulty == 2'd1) ? 10'd240 : 10'd128;

    wire [9:0] offset_x = (10'd640 - game_w) >> 1;
    wire [9:0] offset_y = (10'd480 - game_h) >> 1;

    //========================================================================
    // 4. VGA 扫描计数器（保持原样）
    //========================================================================
    reg [9:0] h_cnt;
    reg [9:0] v_cnt;

    always @(posedge clk_100M or negedge rst_n) begin
        if (!rst_n) begin
            h_cnt <= 10'd0;
            v_cnt <= 10'd0;
        end else if (pixel_en) begin
            if (h_cnt == H_TOTAL - 1) begin
                h_cnt <= 10'd0;
                if (v_cnt == V_TOTAL - 1)
                    v_cnt <= 10'd0;
                else
                    v_cnt <= v_cnt + 10'd1;
            end else begin
                h_cnt <= h_cnt + 10'd1;
            end
        end
    end

    //========================================================================
    // 5. VGA 同步信号（保持原样）
    //========================================================================
    reg vga_hs_r;
    reg vga_vs_r;
    reg video_en_r;

    always @(posedge clk_100M or negedge rst_n) begin
        if (!rst_n) begin
            vga_hs_r   <= 1'b1;
            vga_vs_r   <= 1'b1;
            video_en_r <= 1'b0;
        end else if (pixel_en) begin
            vga_hs_r <= (h_cnt >= H_SYNC);
            vga_vs_r <= (v_cnt >= V_SYNC);
            video_en_r <= (h_cnt >= H_SYNC + H_BACK) &&
                          (h_cnt <  H_SYNC + H_BACK + H_DISP) &&
                          (v_cnt >= V_SYNC + V_BACK) &&
                          (v_cnt <  V_SYNC + V_BACK + V_DISP);
        end
    end

    
    //========================================================================
    // 6. 屏幕像素坐标 -> 地图格子坐标（保持原样）
    //========================================================================
    wire [9:0] pixel_x = video_en_r ? (h_cnt - H_SYNC - H_BACK) : 10'd0;
    wire [9:0] pixel_y = video_en_r ? (v_cnt - V_SYNC - V_BACK) : 10'd0;

    wire in_game_area = (pixel_x >= offset_x) && (pixel_x < offset_x + game_w) &&
                        (pixel_y >= offset_y) && (pixel_y < offset_y + game_h);

    wire [9:0] local_x = in_game_area ? (pixel_x - offset_x) : 10'd0;
    wire [9:0] local_y = in_game_area ? (pixel_y - offset_y) : 10'd0;

    wire [4:0] grid_x = in_game_area ? (local_x >> TILE_SHIFT) : 5'd0;
    wire [4:0] grid_y = in_game_area ? (local_y >> TILE_SHIFT) : 5'd0;

    assign vga_addr_x = grid_x;
    assign vga_addr_y = grid_y;

	 // 根据难度计算地图尺寸，用于边界强制补墙
    wire [4:0] curr_width  = (difficulty == 2'd2) ? 5'd19 : (difficulty == 2'd1) ? 5'd15 : 5'd8;
    wire [4:0] curr_height = (difficulty == 2'd2) ? 5'd21 : (difficulty == 2'd1) ? 5'd15 : 5'd8;
    //========================================================================
    // 6.5 硬件级平滑插值器 (Chaser Camera)
    //========================================================================
    reg [9:0] d_pac_x, d_pac_y;
    reg [9:0] d_gh0_x, d_gh0_y;
    reg [9:0] d_gh1_x, d_gh1_y;
    reg [9:0] d_gh2_x, d_gh2_y;
    reg [9:0] d_gh3_x, d_gh3_y;

    wire [9:0] t_pac_x = pac_x * 10'd16;  wire [9:0] t_pac_y = pac_y * 10'd16;
    wire [9:0] t_gh0_x = ghost0_x * 10'd16; wire [9:0] t_gh0_y = ghost0_y * 10'd16;
    wire [9:0] t_gh1_x = ghost1_x * 10'd16; wire [9:0] t_gh1_y = ghost1_y * 10'd16;
    wire [9:0] t_gh2_x = ghost2_x * 10'd16; wire [9:0] t_gh2_y = ghost2_y * 10'd16;
    wire [9:0] t_gh3_x = ghost3_x * 10'd16; wire [9:0] t_gh3_y = ghost3_y * 10'd16;

    // 根据难度动态推导幽灵的速度追赶步长：2代表全速，1代表半速
    wire [9:0] step_gh0 = (difficulty == 2'd0) ? 10'd1 : 10'd2;
    wire [9:0] step_gh1 = (difficulty == 2'd2) ? 10'd2 : 10'd1;
    wire [9:0] step_gh2 = 10'd1;
    wire [9:0] step_gh3 = 10'd1;

    always @(posedge vga_vs_r or negedge rst_n) begin
        if (!rst_n) begin
            d_pac_x <= 10'd16; d_pac_y <= 10'd16;
            d_gh0_x <= 10'd16; d_gh0_y <= 10'd16; d_gh1_x <= 10'd16; d_gh1_y <= 10'd16;
            d_gh2_x <= 10'd16; d_gh2_y <= 10'd16; d_gh3_x <= 10'd16; d_gh3_y <= 10'd16;
        end else begin
            // 距离大于32（跨图瞬移/复活），瞬间对齐；否则平滑追赶（消除抖动）
            if (t_pac_x > d_pac_x + 32 || d_pac_x > t_pac_x + 32) d_pac_x <= t_pac_x;
            else if (t_pac_x > d_pac_x) d_pac_x <= d_pac_x + ((t_pac_x - d_pac_x >= 10'd2) ? 10'd2 : 10'd1);
            else if (d_pac_x > t_pac_x) d_pac_x <= d_pac_x - ((d_pac_x - t_pac_x >= 10'd2) ? 10'd2 : 10'd1);

            if (t_pac_y > d_pac_y + 32 || d_pac_y > t_pac_y + 32) d_pac_y <= t_pac_y;
            else if (t_pac_y > d_pac_y) d_pac_y <= d_pac_y + ((t_pac_y - d_pac_y >= 10'd2) ? 10'd2 : 10'd1);
            else if (d_pac_y > t_pac_y) d_pac_y <= d_pac_y - ((d_pac_y - t_pac_y >= 10'd2) ? 10'd2 : 10'd1);

            if (t_gh0_x > d_gh0_x + 32 || d_gh0_x > t_gh0_x + 32) d_gh0_x <= t_gh0_x;
            else if (t_gh0_x > d_gh0_x) d_gh0_x <= d_gh0_x + ((t_gh0_x - d_gh0_x >= step_gh0) ? step_gh0 : 10'd1);
            else if (d_gh0_x > t_gh0_x) d_gh0_x <= d_gh0_x - ((d_gh0_x - t_gh0_x >= step_gh0) ? step_gh0 : 10'd1);
            if (t_gh0_y > d_gh0_y + 32 || d_gh0_y > t_gh0_y + 32) d_gh0_y <= t_gh0_y;
            else if (t_gh0_y > d_gh0_y) d_gh0_y <= d_gh0_y + ((t_gh0_y - d_gh0_y >= step_gh0) ? step_gh0 : 10'd1);
            else if (d_gh0_y > t_gh0_y) d_gh0_y <= d_gh0_y - ((d_gh0_y - t_gh0_y >= step_gh0) ? step_gh0 : 10'd1);

            if (t_gh1_x > d_gh1_x + 32 || d_gh1_x > t_gh1_x + 32) d_gh1_x <= t_gh1_x;
            else if (t_gh1_x > d_gh1_x) d_gh1_x <= d_gh1_x + ((t_gh1_x - d_gh1_x >= step_gh1) ? step_gh1 : 10'd1);
            else if (d_gh1_x > t_gh1_x) d_gh1_x <= d_gh1_x - ((d_gh1_x - t_gh1_x >= step_gh1) ? step_gh1 : 10'd1);
            if (t_gh1_y > d_gh1_y + 32 || d_gh1_y > t_gh1_y + 32) d_gh1_y <= t_gh1_y;
            else if (t_gh1_y > d_gh1_y) d_gh1_y <= d_gh1_y + ((t_gh1_y - d_gh1_y >= step_gh1) ? step_gh1 : 10'd1);
            else if (d_gh1_y > t_gh1_y) d_gh1_y <= d_gh1_y - ((d_gh1_y - t_gh1_y >= step_gh1) ? step_gh1 : 10'd1);

            if (t_gh2_x > d_gh2_x + 32 || d_gh2_x > t_gh2_x + 32) d_gh2_x <= t_gh2_x;
            else if (t_gh2_x > d_gh2_x) d_gh2_x <= d_gh2_x + ((t_gh2_x - d_gh2_x >= step_gh2) ? step_gh2 : 10'd1);
            else if (d_gh2_x > t_gh2_x) d_gh2_x <= d_gh2_x - ((d_gh2_x - t_gh2_x >= step_gh2) ? step_gh2 : 10'd1);
            if (t_gh2_y > d_gh2_y + 32 || d_gh2_y > t_gh2_y + 32) d_gh2_y <= t_gh2_y;
            else if (t_gh2_y > d_gh2_y) d_gh2_y <= d_gh2_y + ((t_gh2_y - d_gh2_y >= step_gh2) ? step_gh2 : 10'd1);
            else if (d_gh2_y > t_gh2_y) d_gh2_y <= d_gh2_y - ((d_gh2_y - t_gh2_y >= step_gh2) ? step_gh2 : 10'd1);

            if (t_gh3_x > d_gh3_x + 32 || d_gh3_x > t_gh3_x + 32) d_gh3_x <= t_gh3_x;
            else if (t_gh3_x > d_gh3_x) d_gh3_x <= d_gh3_x + ((t_gh3_x - d_gh3_x >= step_gh3) ? step_gh3 : 10'd1);
            else if (d_gh3_x > t_gh3_x) d_gh3_x <= d_gh3_x - ((d_gh3_x - t_gh3_x >= step_gh3) ? step_gh3 : 10'd1);
            if (t_gh3_y > d_gh3_y + 32 || d_gh3_y > t_gh3_y + 32) d_gh3_y <= t_gh3_y;
            else if (t_gh3_y > d_gh3_y) d_gh3_y <= d_gh3_y + ((t_gh3_y - d_gh3_y >= step_gh3) ? step_gh3 : 10'd1);
            else if (d_gh3_y > t_gh3_y) d_gh3_y <= d_gh3_y - ((d_gh3_y - t_gh3_y >= step_gh3) ? step_gh3 : 10'd1);
        end
    end

    //========================================================================
    // 7. 新的严格对齐流水线 (升级为支持透明与重叠的 Sprite 架构)
    //========================================================================
    reg [9:0] pixel_x_r, pixel_y_r;
    reg [4:0] grid_x_r, grid_y_r;
    reg [3:0] tile_px_r, tile_py_r;
    reg [3:0] pac_px_r, pac_py_r;
    reg is_pac_r, is_gh0_r, is_gh1_r, is_gh2_r, is_gh3_r;
    reg in_game_area_r, video_en_r2, vga_hs_r2, vga_vs_r2;
    reg [1:0] menu_sel_r;
    reg [15:0] score_bcd_r;
    reg [2:0] game_state_r;
    reg power_active_r, pill_blink_r;
	 reg [9:0] power_counter_r;         // <--- 新增：倒计时寄存器
    reg [23:0] rom_ghost_r, rom_wall_r;

    // 动态边框判定：判断当前扫描点是否在角色的插值坐标矩形内
    wire [9:0] cur_local_x = in_game_area ? (pixel_x - offset_x) : 10'd0;
    wire [9:0] cur_local_y = in_game_area ? (pixel_y - offset_y) : 10'd0;
    wire in_pac = in_game_area && (cur_local_x >= d_pac_x) && (cur_local_x < d_pac_x + 16) && (cur_local_y >= d_pac_y) && (cur_local_y < d_pac_y + 16);
    wire in_gh0 = in_game_area && (cur_local_x >= d_gh0_x) && (cur_local_x < d_gh0_x + 16) && (cur_local_y >= d_gh0_y) && (cur_local_y < d_gh0_y + 16);
    wire in_gh1 = in_game_area && (cur_local_x >= d_gh1_x) && (cur_local_x < d_gh1_x + 16) && (cur_local_y >= d_gh1_y) && (cur_local_y < d_gh1_y + 16);
    wire in_gh2 = in_game_area && (cur_local_x >= d_gh2_x) && (cur_local_x < d_gh2_x + 16) && (cur_local_y >= d_gh2_y) && (cur_local_y < d_gh2_y + 16);
    wire in_gh3 = in_game_area && (cur_local_x >= d_gh3_x) && (cur_local_x < d_gh3_x + 16) && (cur_local_y >= d_gh3_y) && (cur_local_y < d_gh3_y + 16);

    // 纹理寻址复用器 (如果重叠，Ghost0 优先于 Ghost1 提取像素)
    wire [3:0] rom_px = in_gh0 ? (cur_local_x - d_gh0_x) : in_gh1 ? (cur_local_x - d_gh1_x) :
                        in_gh2 ? (cur_local_x - d_gh2_x) : in_gh3 ? (cur_local_x - d_gh3_x) : cur_local_x[3:0];
    wire [3:0] rom_py = in_gh0 ? (cur_local_y - d_gh0_y) : in_gh1 ? (cur_local_y - d_gh1_y) :
                        in_gh2 ? (cur_local_y - d_gh2_y) : in_gh3 ? (cur_local_y - d_gh3_y) : cur_local_y[3:0];
    wire [7:0] tex_addr = {rom_py, rom_px};
    wire [7:0] wall_addr = {local_y[3:0], local_x[3:0]}; // 背景墙壁强制网格对齐

    wire [23:0] rom_ghost_raw, rom_wall_raw;
    rom_wall   u_rom_wall   (.clock(clk_100M), .address(wall_addr), .q(rom_wall_raw));
    rom_ghost  u_rom_ghost  (.clock(clk_100M), .address(tex_addr),  .q(rom_ghost_raw));

    always @(posedge clk_100M or negedge rst_n) begin
        if (!rst_n) begin
            video_en_r2 <= 1'b0; vga_hs_r2 <= 1'b1; vga_vs_r2 <= 1'b1;
        end else if (pixel_en) begin
            pixel_x_r <= pixel_x; pixel_y_r <= pixel_y;
            grid_x_r  <= grid_x;  grid_y_r  <= grid_y;
            tile_px_r <= local_x[3:0]; tile_py_r <= local_y[3:0];
            
            // 计算相对吃豆人自身的亚像素偏差，供动态几何绘画使用
            pac_px_r <= cur_local_x - d_pac_x;
            pac_py_r <= cur_local_y - d_pac_y;
            
            is_pac_r <= in_pac; is_gh0_r <= in_gh0; is_gh1_r <= in_gh1;
            is_gh2_r <= in_gh2; is_gh3_r <= in_gh3;
            
            in_game_area_r <= in_game_area;
            video_en_r2 <= video_en_r; vga_hs_r2 <= vga_hs_r; vga_vs_r2 <= vga_vs_r;
            menu_sel_r <= menu_sel; score_bcd_r <= score_bcd;
            game_state_r <= game_state; power_active_r <= power_active; pill_blink_r <= pill_blink;
				power_counter_r <= power_counter; // <--- 新增：同步倒计时数据
            rom_ghost_r <= rom_ghost_raw; rom_wall_r <= rom_wall_raw;
        end
    end
    wire [2:0] vga_map_data_r = vga_map_data; 
	 // ==========================================
    // 补回丢失的 VGA 物理引脚同步信号！
    // ==========================================
    assign vga_hs      = vga_hs_r2;
    assign vga_vs      = vga_vs_r2;
    assign vga_blank_n = video_en_r2;
    assign vga_sync_n  = 1'b0;

    //========================================================================
    // 8. 吃豆人全动态几何渲染逻辑（完美支持亚像素系统）
    //========================================================================
    reg [4:0] frame_cnt;
    always @(posedge vga_vs_r2 or negedge rst_n) begin
        if (!rst_n) frame_cnt <= 5'd0;
        else frame_cnt <= frame_cnt + 1'b1;
    end
    wire mouth_open = frame_cnt[3];

    // 利用刚在流水线里算好的相对坐标 pac_px_r 重新计算圆方程
    wire signed [5:0] cx = ({1'b0, pac_px_r} << 1) - 15;
    wire signed [5:0] cy = ({1'b0, pac_py_r} << 1) - 15;
    wire is_pac_body = ((cx * cx + cy * cy) <= 225); 

    reg is_mouth;
    always @(*) begin
        is_mouth = 1'b0;
        if (mouth_open && is_pac_r) begin
            case (pac_dir) 
                `DIR_RIGHT: if (pac_px_r >= 8 && (pac_py_r >= 8 ? (pac_py_r - 8) : (8 - pac_py_r)) <= (pac_px_r - 8)) is_mouth = 1'b1;
                `DIR_LEFT:  if (pac_px_r <= 7 && (pac_py_r >= 8 ? (pac_py_r - 8) : (8 - pac_py_r)) <= (7 - pac_px_r)) is_mouth = 1'b1;
                `DIR_DOWN:  if (pac_py_r >= 8 && (pac_px_r >= 8 ? (pac_px_r - 8) : (8 - pac_px_r)) <= (pac_py_r - 8)) is_mouth = 1'b1;
                `DIR_UP:    if (pac_py_r <= 7 && (pac_px_r >= 8 ? (pac_px_r - 8) : (8 - pac_px_r)) <= (7 - pac_py_r)) is_mouth = 1'b1;
                default: is_mouth = 1'b0;
            endcase
        end
    end

    reg is_eye;
    always @(*) begin
        is_eye = 1'b0;
        if (is_pac_r) begin
            case (pac_dir)
                `DIR_RIGHT: if (pac_px_r >= 8  && pac_px_r <= 9  && pac_py_r >= 3 && pac_py_r <= 4) is_eye = 1'b1;
                `DIR_LEFT:  if (pac_px_r >= 6  && pac_px_r <= 7  && pac_py_r >= 3 && pac_py_r <= 4) is_eye = 1'b1;
                `DIR_UP:    if (pac_px_r >= 10 && pac_px_r <= 11 && pac_py_r >= 6 && pac_py_r <= 7) is_eye = 1'b1;
                `DIR_DOWN:  if (pac_px_r >= 4  && pac_px_r <= 5  && pac_py_r >= 8 && pac_py_r <= 9) is_eye = 1'b1;
                default: is_eye = 1'b0;
            endcase
        end
    end
    //========================================================================
    // 9. 颜色与绘制函数（保持原有 dot/pill 函数，新增文字参数）
    //========================================================================
    localparam COLOR_DOT    = 24'hFFD1A4;
    localparam COLOR_PILL   = 24'h00FF88; // 青绿色能量豆，醒目
    localparam COLOR_BG     = 24'h000000;
    localparam COLOR_GO_BG  = 24'h330000;
	 localparam COLOR_WALL_BRIGHT = 24'h00FFFF; // 亮青色墙壁
    localparam COLOR_WIN    = 24'h00FF00;
    localparam COLOR_SCARED = 24'h2222FF;

    // 新增：菜单/结束界面颜色
    localparam COLOR_TITLE     = 24'hFFE000; // 金黄
    localparam COLOR_HIGHLIGHT = 24'h00FF00; // 亮绿
    localparam COLOR_TEXT      = 24'hFFFFFF; // 白
    localparam COLOR_MENU_BG   = 24'h000000; // 纯黑
    localparam COLOR_GO_TEXT   = 24'hFF0000; // 红
    localparam COLOR_WIN_TEXT  = 24'h00FF00; // 绿

    // 新增：文字绘制参数（4x4 放大，字符宽20，高28，间隙4，总宽24）
    localparam CHAR_SCALE   = 4;
    localparam CHAR_W       = 5 * CHAR_SCALE;   // 20
    localparam CHAR_H       = 7 * CHAR_SCALE;   // 28
    localparam CHAR_GAP     = 4;
    localparam CHAR_TOTAL_W = CHAR_W + CHAR_GAP; // 24

    function [23:0] draw_dot;
        input [3:0] px;
        input [3:0] py;
        begin
            draw_dot = (px >= 4'd6 && px <= 4'd9 &&
                        py >= 4'd6 && py <= 4'd9) ? COLOR_DOT : COLOR_BG;
        end
    endfunction

    function [23:0] draw_pill;
        input [3:0] px;
        input [3:0] py;
        input       blink;
        reg [3:0] dx;
        reg [3:0] dy;
        begin
            // 计算到中心 (8,8) 的曼哈顿距离，菱形即低分辨率下的"圆"
            dx = (px > 4'd8) ? (px - 4'd8) : (4'd8 - px);
            dy = (py > 4'd8) ? (py - 4'd8) : (4'd8 - py);

            if (blink)
                draw_pill = ((dx + dy) <= 4'd6) ? COLOR_PILL : COLOR_BG;
            else
                draw_pill = ((dx + dy) <= 4'd3) ? COLOR_PILL : COLOR_BG;
        end
    endfunction

     //========================================================================
    // 新增：5x7 像素字体列模式函数（bit6=顶行，bit0=底行）
    // 修复：重写 S/L/H 的笔画，提高 4x 放大后的辨识度
    //========================================================================
        //========================================================================
    // 5x7 像素字体列模式函数（bit6=顶行，bit0=底行）
    // 修复：全部字符重写为标准 5x7 图案，消除笔画错位和孤立像素
    //========================================================================
    function [6:0] char_pat;
        input [7:0] ch;
        input [2:0] col;
        begin
            case (ch)
                "A": case(col) 3'd0: char_pat=7'b0111110; 3'd1: char_pat=7'b1001000; 3'd2: char_pat=7'b1001000; 3'd3: char_pat=7'b1001000; 3'd4: char_pat=7'b0111110; default: char_pat=7'b0000000; endcase
                "B": case(col) 3'd0: char_pat=7'b1111110; 3'd1: char_pat=7'b1001001; 3'd2: char_pat=7'b1001001; 3'd3: char_pat=7'b1001001; 3'd4: char_pat=7'b0110110; default: char_pat=7'b0000000; endcase
                "C": case(col) 3'd0: char_pat=7'b0111110; 3'd1: char_pat=7'b1000001; 3'd2: char_pat=7'b1000001; 3'd3: char_pat=7'b1000001; 3'd4: char_pat=7'b0100010; default: char_pat=7'b0000000; endcase
                "D": case(col) 3'd0: char_pat=7'b1111110; 3'd1: char_pat=7'b1000001; 3'd2: char_pat=7'b1000001; 3'd3: char_pat=7'b1000001; 3'd4: char_pat=7'b0111110; default: char_pat=7'b0000000; endcase
                "E": case(col) 3'd0: char_pat=7'b1111111; 3'd1: char_pat=7'b1001001; 3'd2: char_pat=7'b1001001; 3'd3: char_pat=7'b1001001; 3'd4: char_pat=7'b1000001; default: char_pat=7'b0000000; endcase
                "F": case(col) 3'd0: char_pat=7'b1111111; 3'd1: char_pat=7'b1001000; 3'd2: char_pat=7'b1001000; 3'd3: char_pat=7'b1001000; 3'd4: char_pat=7'b1000000; default: char_pat=7'b0000000; endcase
                "G": case(col) 3'd0: char_pat=7'b0111110; 3'd1: char_pat=7'b1000001; 3'd2: char_pat=7'b1001001; 3'd3: char_pat=7'b1001001; 3'd4: char_pat=7'b0111110; default: char_pat=7'b0000000; endcase
                "H": case(col) 3'd0: char_pat=7'b1111111; 3'd1: char_pat=7'b0001000; 3'd2: char_pat=7'b0001000; 3'd3: char_pat=7'b0001000; 3'd4: char_pat=7'b1111111; default: char_pat=7'b0000000; endcase
                "I": case(col) 3'd0: char_pat=7'b0000000; 3'd1: char_pat=7'b1000001; 3'd2: char_pat=7'b1111111; 3'd3: char_pat=7'b1000001; 3'd4: char_pat=7'b0000000; default: char_pat=7'b0000000; endcase
                "J": case(col) 3'd0: char_pat=7'b0000000; 3'd1: char_pat=7'b0000001; 3'd2: char_pat=7'b0000001; 3'd3: char_pat=7'b1000001; 3'd4: char_pat=7'b0111110; default: char_pat=7'b0000000; endcase
                "K": case(col) 3'd0: char_pat=7'b1111111; 3'd1: char_pat=7'b0010010; 3'd2: char_pat=7'b0100100; 3'd3: char_pat=7'b1001000; 3'd4: char_pat=7'b1000000; default: char_pat=7'b0000000; endcase
                "L": case(col) 3'd0: char_pat=7'b1111111; 3'd1: char_pat=7'b0000001; 3'd2: char_pat=7'b0000001; 3'd3: char_pat=7'b0000001; 3'd4: char_pat=7'b0000001; default: char_pat=7'b0000000; endcase
                "M": case(col) 3'd0: char_pat=7'b1111111; 3'd1: char_pat=7'b0100010; 3'd2: char_pat=7'b0010100; 3'd3: char_pat=7'b0100010; 3'd4: char_pat=7'b1111111; default: char_pat=7'b0000000; endcase
                "N": case(col) 3'd0: char_pat=7'b1111111; 3'd1: char_pat=7'b0100000; 3'd2: char_pat=7'b0011000; 3'd3: char_pat=7'b0000100; 3'd4: char_pat=7'b1111111; default: char_pat=7'b0000000; endcase
                "O": case(col) 3'd0: char_pat=7'b0111110; 3'd1: char_pat=7'b1000001; 3'd2: char_pat=7'b1000001; 3'd3: char_pat=7'b1000001; 3'd4: char_pat=7'b0111110; default: char_pat=7'b0000000; endcase
                "P": case(col) 3'd0: char_pat=7'b1111111; 3'd1: char_pat=7'b1001000; 3'd2: char_pat=7'b1001000; 3'd3: char_pat=7'b1001000; 3'd4: char_pat=7'b0110000; default: char_pat=7'b0000000; endcase
                "Q": case(col) 3'd0: char_pat=7'b0111110; 3'd1: char_pat=7'b1000001; 3'd2: char_pat=7'b1001001; 3'd3: char_pat=7'b1001001; 3'd4: char_pat=7'b0110110; default: char_pat=7'b0000000; endcase
                "R": case(col) 3'd0: char_pat=7'b1111111; 3'd1: char_pat=7'b1001010; 3'd2: char_pat=7'b1001100; 3'd3: char_pat=7'b1000001; 3'd4: char_pat=7'b0110000; default: char_pat=7'b0000000; endcase
                "S": case(col) 3'd0: char_pat=7'b0110010; 3'd1: char_pat=7'b1001001; 3'd2: char_pat=7'b1001001; 3'd3: char_pat=7'b1001001; 3'd4: char_pat=7'b0100110; default: char_pat=7'b0000000; endcase
                "T": case(col) 3'd0: char_pat=7'b1000000; 3'd1: char_pat=7'b1000000; 3'd2: char_pat=7'b1111111; 3'd3: char_pat=7'b1000000; 3'd4: char_pat=7'b1000000; default: char_pat=7'b0000000; endcase
                "U": case(col) 3'd0: char_pat=7'b1111110; 3'd1: char_pat=7'b0000001; 3'd2: char_pat=7'b0000001; 3'd3: char_pat=7'b0000001; 3'd4: char_pat=7'b1111110; default: char_pat=7'b0000000; endcase
                "V": case(col) 3'd0: char_pat=7'b1111000; 3'd1: char_pat=7'b0000110; 3'd2: char_pat=7'b0000001; 3'd3: char_pat=7'b0000110; 3'd4: char_pat=7'b1111000; default: char_pat=7'b0000000; endcase
                "W": case(col) 3'd0: char_pat=7'b1111110; 3'd1: char_pat=7'b0000001; 3'd2: char_pat=7'b0011100; 3'd3: char_pat=7'b0000001; 3'd4: char_pat=7'b1111110; default: char_pat=7'b0000000; endcase
                "X": case(col) 3'd0: char_pat=7'b1111111; 3'd1: char_pat=7'b0001000; 3'd2: char_pat=7'b0010100; 3'd3: char_pat=7'b0001000; 3'd4: char_pat=7'b1111111; default: char_pat=7'b0000000; endcase
                "Y": case(col) 3'd0: char_pat=7'b1100000; 3'd1: char_pat=7'b0010000; 3'd2: char_pat=7'b0001111; 3'd3: char_pat=7'b0010000; 3'd4: char_pat=7'b1100000; default: char_pat=7'b0000000; endcase
                // 修复 Z：完美的顶部横线、对角线和底部横线
                "Z": case(col) 3'd0: char_pat=7'b1000011; 3'd1: char_pat=7'b1000101; 3'd2: char_pat=7'b1001001; 3'd3: char_pat=7'b1010001; 3'd4: char_pat=7'b1100001; default: char_pat=7'b0000000; endcase
                "-": case(col) 3'd0: char_pat=7'b0001000; 3'd1: char_pat=7'b0001000; 3'd2: char_pat=7'b0001000; 3'd3: char_pat=7'b0001000; 3'd4: char_pat=7'b0001000; default: char_pat=7'b0000000; endcase
                ":": case(col) 3'd0: char_pat=7'b0000000; 3'd1: char_pat=7'b0000000; 3'd2: char_pat=7'b0100100; 3'd3: char_pat=7'b0000000; 3'd4: char_pat=7'b0000000; default: char_pat=7'b0000000; endcase
                "0": case(col) 3'd0: char_pat=7'b0111110; 3'd1: char_pat=7'b1000001; 3'd2: char_pat=7'b1000001; 3'd3: char_pat=7'b1000001; 3'd4: char_pat=7'b0111110; default: char_pat=7'b0000000; endcase
                "1": case(col) 3'd0: char_pat=7'b0000000; 3'd1: char_pat=7'b0100001; 3'd2: char_pat=7'b1111111; 3'd3: char_pat=7'b0000000; 3'd4: char_pat=7'b0000000; default: char_pat=7'b0000000; endcase
                "2": case(col) 3'd0: char_pat=7'b0100011; 3'd1: char_pat=7'b1001010; 3'd2: char_pat=7'b1001001; 3'd3: char_pat=7'b1010001; 3'd4: char_pat=7'b0100001; default: char_pat=7'b0000000; endcase
                "3": case(col) 3'd0: char_pat=7'b0100010; 3'd1: char_pat=7'b1000001; 3'd2: char_pat=7'b1001001; 3'd3: char_pat=7'b1010001; 3'd4: char_pat=7'b0100010; default: char_pat=7'b0000000; endcase
                "4": case(col) 3'd0: char_pat=7'b0001100; 3'd1: char_pat=7'b0010100; 3'd2: char_pat=7'b0100100; 3'd3: char_pat=7'b1111111; 3'd4: char_pat=7'b0001000; default: char_pat=7'b0000000; endcase
                "5": case(col) 3'd0: char_pat=7'b1110010; 3'd1: char_pat=7'b1010001; 3'd2: char_pat=7'b1010001; 3'd3: char_pat=7'b1001110; 3'd4: char_pat=7'b1000000; default: char_pat=7'b0000000; endcase
                "6": case(col) 3'd0: char_pat=7'b0111110; 3'd1: char_pat=7'b1001001; 3'd2: char_pat=7'b1001001; 3'd3: char_pat=7'b1001001; 3'd4: char_pat=7'b0001110; default: char_pat=7'b0000000; endcase
                "7": case(col) 3'd0: char_pat=7'b1000000; 3'd1: char_pat=7'b1000111; 3'd2: char_pat=7'b1001000; 3'd3: char_pat=7'b1010000; 3'd4: char_pat=7'b1100000; default: char_pat=7'b0000000; endcase
                "8": case(col) 3'd0: char_pat=7'b0110110; 3'd1: char_pat=7'b1001001; 3'd2: char_pat=7'b1001001; 3'd3: char_pat=7'b1001001; 3'd4: char_pat=7'b0110110; default: char_pat=7'b0000000; endcase
                "9": case(col) 3'd0: char_pat=7'b0110000; 3'd1: char_pat=7'b1001001; 3'd2: char_pat=7'b1001001; 3'd3: char_pat=7'b1001110; 3'd4: char_pat=7'b0110000; default: char_pat=7'b0000000; endcase
                default: char_pat = 7'b0000000;
            endcase
        end
    endfunction

    //========================================================================
    // 新增：通用文字像素颜色函数（22字符版本，共29个参数）
    //========================================================================
    function [23:0] text_color;
        input [9:0] px;
        input [9:0] py;
        input [9:0] bx;
        input [9:0] by;
        input [7:0] s0, s1, s2, s3, s4, s5, s6, s7, s8, s9;
        input [7:0] s10, s11, s12, s13, s14, s15, s16, s17, s18, s19;
        input [7:0] s20, s21;
        input [4:0] len;
        input [23:0] fg;
        input [23:0] bg;
        reg [9:0] rel_x;
        reg [9:0] rel_y;
        reg [4:0] idx;
        reg [2:0] col;
        reg [2:0] row;
        reg [7:0] ch;
        reg [6:0] pat;
        reg on;
        begin
            rel_x = px - bx;
            rel_y = py - by;
            idx = rel_x / CHAR_TOTAL_W;
            col = (rel_x - idx * CHAR_TOTAL_W) >> 2;
            row = rel_y >> 2;

            if (px < bx || py < by || rel_x >= len * CHAR_TOTAL_W || rel_y >= CHAR_H || col >= 5)
                on = 1'b0;
            else begin
                case (idx)
                    5'd0:  ch = s0;   5'd1:  ch = s1;   5'd2:  ch = s2;   5'd3:  ch = s3;
                    5'd4:  ch = s4;   5'd5:  ch = s5;   5'd6:  ch = s6;   5'd7:  ch = s7;
                    5'd8:  ch = s8;   5'd9:  ch = s9;   5'd10: ch = s10;  5'd11: ch = s11;
                    5'd12: ch = s12;  5'd13: ch = s13;  5'd14: ch = s14;  5'd15: ch = s15;
                    5'd16: ch = s16;  5'd17: ch = s17;  5'd18: ch = s18;  5'd19: ch = s19;
                    5'd20: ch = s20;  5'd21: ch = s21;
                    default: ch = " ";
                endcase
                pat = char_pat(ch, col);
                if (row < 7)
                    on = pat[6-row];
                else
                    on = 1'b0;
            end
            text_color = on ? fg : bg;
        end
    endfunction

    
    //========================================================================
    // 10. 最终渲染输出
    //========================================================================
    reg [23:0] pixel_color;
    // 分数 BCD 转 ASCII 数字（组合逻辑）
    wire [7:0] score_d3 = 8'h30 + score_bcd_r[15:12];
    wire [7:0] score_d2 = 8'h30 + score_bcd_r[11:8];
    wire [7:0] score_d1 = 8'h30 + score_bcd_r[7:4];
    wire [7:0] score_d0 = 8'h30 + score_bcd_r[3:0];

	// 🌟 修正：因为是正向计时，所以总长100步的话，走到 > 70 步才开始闪烁（最后 2 秒）
    // 🌟 假设你的总步数是 50，倒数 30 步（2秒）开始闪烁，那就是走到 > 20 的时候！
    wire is_ending = (power_active_r && power_counter_r < 10'd30);
    wire [23:0] cur_scared_color = (is_ending && frame_cnt[3]) ? 24'hFFFFFF : COLOR_SCARED;
    always @(*) begin
        pixel_color = COLOR_BG;

        if (!video_en_r2) begin
            pixel_color = COLOR_BG;
        end else begin
            case (game_state_r)

                //================================================
                // STATE_MENU / STATE_IDLE：菜单界面
                //================================================
                `STATE_MENU,
                `STATE_IDLE: begin
                    pixel_color = COLOR_MENU_BG;

                    // 标题 "PAC-MAN"：base_x=236, base_y=100
                    pixel_color = text_color(pixel_x_r, pixel_y_r, 236, 100,
                        "P","A","C","-","M","A","N"," "," "," ",
                        " "," "," "," "," "," "," "," "," "," ",
                        " "," ",
                        5'd7, COLOR_TITLE, pixel_color);

                    // SIMPLE：base_x=248, base_y=200
                    pixel_color = text_color(pixel_x_r, pixel_y_r, 248, 200,
                        "S","I","M","P","L","E"," "," "," "," ",
                        " "," "," "," "," "," "," "," "," "," ",
                        " "," ",
                        5'd6, (menu_sel_r==0) ? COLOR_HIGHLIGHT : COLOR_TEXT, pixel_color);

                    // MEDIUM：base_x=248, base_y=240
                    pixel_color = text_color(pixel_x_r, pixel_y_r, 248, 240,
                        "M","E","D","I","U","M"," "," "," "," ",
                        " "," "," "," "," "," "," "," "," "," ",
                        " "," ",
                        5'd6, (menu_sel_r==1) ? COLOR_HIGHLIGHT : COLOR_TEXT, pixel_color);

                    // HARD：base_x=272, base_y=280
                    pixel_color = text_color(pixel_x_r, pixel_y_r, 272, 280,
                        "H","A","R","D"," "," "," "," "," "," ",
                        " "," "," "," "," "," "," "," "," "," ",
                        " "," ",
                        5'd4, (menu_sel_r==2) ? COLOR_HIGHLIGHT : COLOR_TEXT, pixel_color);
								// 🌟 新增：你们组员的名字/缩写（放在底部，亮青色字体）
                    // 🌟 新增：团队名称 "TEAM PSC CZY WZY WS"
                    // 严格拆分：每个双引号里只能有一个字母或一个空格
                    pixel_color = text_color(pixel_x_r, pixel_y_r, 50, 400,
                        "T","E","A","M"," ","P","S","C"," ","C",
                        "Z","Y"," ","W","Z","Y"," ","W","S"," ",
                        " "," ",
                        5'd19, 24'h00FFFF, pixel_color);
                end

                //================================================
                // STATE_READY：准备开始
                //================================================
                `STATE_READY: begin
                    pixel_color = COLOR_MENU_BG;

                    // "PRESS ENTER TO START"：base_x=80, base_y=220
                    pixel_color = text_color(pixel_x_r, pixel_y_r, 80, 220,
                        "P","R","E","S","S"," ","E","N","T","E",
                        "R"," ","T","O"," ","S","T","A","R","T",
                        " "," ",
                        5'd20, COLOR_TEXT, pixel_color);
                end

                //================================================
                // STATE_GAME_OVER：结束界面
                //================================================
                `STATE_GAME_OVER: begin
                    pixel_color = COLOR_GO_BG;

                    // "GAME OVER"：base_x=212, base_y=140
                    pixel_color = text_color(pixel_x_r, pixel_y_r, 212, 140,
                        "G","A","M","E"," ","O","V","E","R"," ",
                        " "," "," "," "," "," "," "," "," "," ",
                        " "," ",
                        5'd9, COLOR_GO_TEXT, pixel_color);

                    // "SCORE: "：base_x=188, base_y=220
                    pixel_color = text_color(pixel_x_r, pixel_y_r, 188, 220,
                        "S","C","O","R","E",":"," "," "," "," ",
                        " "," "," "," "," "," "," "," "," "," ",
                        " "," ",
                        5'd7, COLOR_TEXT, pixel_color);

                    // 4位分数：base_x=356, base_y=220
                    pixel_color = text_color(pixel_x_r, pixel_y_r, 356, 220,
                        score_d3, score_d2, score_d1, score_d0,
                        " "," "," "," "," "," ",
                        " "," "," "," "," "," "," "," "," "," ",
                        " "," ",
                        5'd4, COLOR_TEXT, pixel_color);

                    // "PRESS ENTER TO RESTART"：base_x=80, base_y=340
                    pixel_color = text_color(pixel_x_r, pixel_y_r, 80, 340,
                        "P","R","E","S","S"," ","E","N","T","E",
                        "R"," ","T","O"," ","R","E","S","T","A",
                        "R","T",
                        5'd22, COLOR_TEXT, pixel_color);
                end

                //================================================
                // STATE_WIN：胜利界面
                //================================================
                `STATE_WIN: begin
                    pixel_color = COLOR_MENU_BG;

                    // "YOU WIN"：base_x=236, base_y=140
                    pixel_color = text_color(pixel_x_r, pixel_y_r, 236, 140,
                        "Y","O","U"," ","W","I","N"," "," "," ",
                        " "," "," "," "," "," "," "," "," "," ",
                        " "," ",
                        5'd7, COLOR_WIN_TEXT, pixel_color);

                    // "SCORE: "：base_x=188, base_y=220
                    pixel_color = text_color(pixel_x_r, pixel_y_r, 188, 220,
                        "S","C","O","R","E",":"," "," "," "," ",
                        " "," "," "," "," "," "," "," "," "," ",
                        " "," ",
                        5'd7, COLOR_TEXT, pixel_color);

                    // 4位分数
                    pixel_color = text_color(pixel_x_r, pixel_y_r, 356, 220,
                        score_d3, score_d2, score_d1, score_d0,
                        " "," "," "," "," "," ",
                        " "," "," "," "," "," "," "," "," "," ",
                        " "," ",
                        5'd4, COLOR_TEXT, pixel_color);

                    // "PRESS ENTER TO RESTART"：base_x=80, base_y=340
                    pixel_color = text_color(pixel_x_r, pixel_y_r, 80, 340,
                        "P","R","E","S","S"," ","E","N","T","E",
                        "R"," ","T","O"," ","R","E","S","T","A",
                        "R","T",
                        5'd22, COLOR_TEXT, pixel_color);
                end

               //================================================
                // 10. 游戏与死亡态地图渲染 (真正的透明图层 Z-Index 引擎)
                //================================================
                `STATE_DEAD,
                `STATE_PLAYING,
                `STATE_POWER_MODE: begin
                    if (in_game_area_r) begin
                        
                        // 🌟 新增闪烁逻辑：当倒计时小于 15 时，利用 frame_cnt[                               实现蓝白交替闪烁
                       
                        // ⭐️ 优先级 1：吃豆人实体部分 (如果是嘴巴或外圈区域，则变透明，交给下层处理)
                        if (is_pac_r && is_pac_body && !is_eye && !is_mouth) begin
                            pixel_color = 24'hFFFF00; 
                        end
                        // ⭐️ 优先级 2：幽灵 (忽略它贴图中原本纯黑的背景 24'h000000，实现真正的透明叠加穿越！)
                        else if (is_gh0_r && rom_ghost_r != 24'h000000) begin
                            pixel_color = (rom_ghost_r == 24'hFF0000 && power_active_r) ? cur_scared_color : rom_ghost_r;
                        end
                        else if (is_gh1_r && rom_ghost_r != 24'h000000) begin
                            pixel_color = (rom_ghost_r == 24'hFF0000 && power_active_r) ? cur_scared_color : 
                                          (rom_ghost_r == 24'hFF0000) ? 24'hFFB8FF : rom_ghost_r;
                        end
                        else if (is_gh2_r && rom_ghost_r != 24'h000000) begin
                            pixel_color = (rom_ghost_r == 24'hFF0000 && power_active_r) ? cur_scared_color : 
                                          (rom_ghost_r == 24'hFF0000) ? 24'h00FFFF : rom_ghost_r;
                        end
                        else if (is_gh3_r && rom_ghost_r != 24'h000000) begin
                            pixel_color = (rom_ghost_r == 24'hFF0000 && power_active_r) ? cur_scared_color : 
                                          (rom_ghost_r == 24'hFF0000) ? 24'hFFB852 : rom_ghost_r;
                        end
                        // ⭐️ 优先级 3：强制外围边框 (地图底层墙壁遮罩)
                        else if ((grid_x_r == 5'd0) || (grid_x_r == curr_width - 5'd1) ||
                                 (grid_y_r == 5'd0) || (grid_y_r == curr_height - 5'd1)) begin
                            if (tile_px_r == 4'd0 || tile_px_r == 4'd15 || tile_py_r == 4'd0 || tile_py_r == 4'd15)
                                pixel_color = COLOR_WALL_BRIGHT;
                            else
                                pixel_color = COLOR_BG;
                        end
                        // ⭐️ 优先级 4：普通地图背景豆子和内墙
                        else begin
                            case (vga_map_data_r)
                                `MAP_EMPTY: pixel_color = COLOR_BG;
                                `MAP_DOT:   pixel_color = draw_dot(tile_px_r, tile_py_r);
                                `MAP_PILL:  pixel_color = draw_pill(tile_px_r, tile_py_r, pill_blink_r);
                                `MAP_WALL:  pixel_color = (rom_wall_r != COLOR_BG) ? COLOR_WALL_BRIGHT : COLOR_BG;
                                default:    pixel_color = COLOR_BG;
                            endcase
                        end

                    end else begin
                        pixel_color = COLOR_BG;
                    end
                end
                
                default: pixel_color = 24'hFF0000;
            endcase
        end

        vga_r = pixel_color[23:16];
        vga_g = pixel_color[15:8];
        vga_b = pixel_color[7:0];
    end

endmodule