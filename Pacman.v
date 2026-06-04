`timescale 1ns / 1ps
`include "game_defines.v"

module PacMan (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        move_en,
    input  wire [1:0]  key_dir,
    input  wire [2:0]  next_map_data,
    input  wire        reset_pos,
    input  wire [4:0]  spawn_x,
    input  wire [4:0]  spawn_y,
	 output wire [1:0]  pac_dir,
    output reg  [4:0]  pac_x,
    output reg  [4:0]  pac_y,
    output wire [4:0]  next_x,
    output wire [4:0]  next_y,
    output reg         move_req,
    output reg         dot_eat,
    output reg         pill_eat
);

    localparam BLOCK_SHIFT = 3;
    localparam BLOCK_SIZE  = 1 << BLOCK_SHIFT;

    reg [9:0] pixel_x;
    reg [8:0] pixel_y;
    reg [1:0] buffered_dir;
    reg [1:0] current_dir;
    reg [1:0] reset_hold;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) reset_hold <= 0;
        else if (reset_pos) reset_hold <= 2;
        else if (reset_hold > 0) reset_hold <= reset_hold - 1;
    end

    // [改动 1 开始] 增加边界保护，防止无符号下溢穿墙
    // 原：pixel_x - BLOCK_SIZE 在 pixel_x=0 时下溢为极大值
    // 新：只有 pixel_x >= BLOCK_SIZE 时才允许减法，否则保持原位
    wire [9:0] buf_pixel_x = (buffered_dir == `DIR_LEFT  && pixel_x >= BLOCK_SIZE) ? pixel_x - BLOCK_SIZE :
                             (buffered_dir == `DIR_RIGHT) ? pixel_x + BLOCK_SIZE : pixel_x;
    wire [8:0] buf_pixel_y = (buffered_dir == `DIR_UP    && pixel_y >= BLOCK_SIZE) ? pixel_y - BLOCK_SIZE :
                             (buffered_dir == `DIR_DOWN) ? pixel_y + BLOCK_SIZE : pixel_y;

    wire [9:0] cur_pixel_x = (current_dir == `DIR_LEFT  && pixel_x >= BLOCK_SIZE) ? pixel_x - BLOCK_SIZE :
                             (current_dir == `DIR_RIGHT) ? pixel_x + BLOCK_SIZE : pixel_x;
    wire [8:0] cur_pixel_y = (current_dir == `DIR_UP    && pixel_y >= BLOCK_SIZE) ? pixel_y - BLOCK_SIZE :
                             (current_dir == `DIR_DOWN) ? pixel_y + BLOCK_SIZE : pixel_y;
    // [改动 1 结束]

    reg [7:0] query_timer;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) query_timer <= 0;
        else query_timer <= query_timer + 1;
    end

    assign next_x = (query_timer < 128) ? (buf_pixel_x >> BLOCK_SHIFT) : (cur_pixel_x >> BLOCK_SHIFT);
    assign next_y = (query_timer < 128) ? (buf_pixel_y >> BLOCK_SHIFT) : (cur_pixel_y >> BLOCK_SHIFT);

    reg buf_clear, cur_clear;
    reg [2:0] buf_map_data, cur_map_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buf_clear <= 0; cur_clear <= 0;
            buf_map_data <= 0; cur_map_data <= 0;
        end else begin
            if (query_timer == 120) begin
                buf_clear <= (next_map_data != `MAP_WALL);
                buf_map_data <= next_map_data;
            end
            if (query_timer == 250) begin
                cur_clear <= (next_map_data != `MAP_WALL);
                cur_map_data <= next_map_data;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pixel_x      <= (spawn_x << BLOCK_SHIFT);
            pixel_y      <= (spawn_y << BLOCK_SHIFT);
            buffered_dir <= `DIR_UP;
            current_dir  <= `DIR_UP;
            pac_x        <= spawn_x;
            pac_y        <= spawn_y;
            move_req     <= 0;
            dot_eat      <= 0;
            pill_eat     <= 0;
        end else begin
            move_req <= 0;
            dot_eat  <= 0;
            pill_eat <= 0;

            if (reset_pos) begin
                pixel_x      <= (spawn_x << BLOCK_SHIFT);
                pixel_y      <= (spawn_y << BLOCK_SHIFT);
                buffered_dir <= `DIR_UP;
                current_dir  <= `DIR_UP;
                pac_x        <= spawn_x;
                pac_y        <= spawn_y;
                move_req     <= 0;
                dot_eat      <= 0;
                pill_eat     <= 0;
            end else begin
                if (reset_hold > 0) buffered_dir <= `DIR_UP;
                else buffered_dir <= key_dir;

                if (move_en) begin
                    if (buf_clear) begin
                        current_dir <= buffered_dir;
                        pixel_x     <= buf_pixel_x;
                        pixel_y     <= buf_pixel_y;
                        pac_x       <= (buf_pixel_x >> BLOCK_SHIFT);
                        pac_y       <= (buf_pixel_y >> BLOCK_SHIFT);
                        move_req    <= 1;
                        if (buf_map_data == `MAP_DOT)  dot_eat  <= 1;
                        if (buf_map_data == `MAP_PILL) pill_eat <= 1;
                    end
                    else if (cur_clear) begin
                        pixel_x  <= cur_pixel_x;
                        pixel_y  <= cur_pixel_y;
                        pac_x    <= (cur_pixel_x >> BLOCK_SHIFT);
                        pac_y    <= (cur_pixel_y >> BLOCK_SHIFT);
                        move_req <= 1;
                        if (cur_map_data == `MAP_DOT)  dot_eat  <= 1;
                        if (cur_map_data == `MAP_PILL) pill_eat <= 1;
                    end
                end
            end
        end
    end
	 assign pac_dir = current_dir;
endmodule