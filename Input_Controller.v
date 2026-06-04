`timescale 1ns / 1ps

//====================================================
// 单个按键/开关消抖模块
// 默认认为 raw_in 是低有效：
// raw_in = 1 表示没按
// raw_in = 0 表示按下
//====================================================
module Debounce_Key #(
    parameter CNT_MAX = 20'd999_999     // 100MHz 下约 10ms
)(
    input  wire clk,
    input  wire rst_n,
    input  wire raw_in,
    output reg  key_stable
);

    reg [19:0] cnt;
    reg raw_sync_0;
    reg raw_sync_1;

    // 两级同步，防止异步输入直接进逻辑
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            raw_sync_0 <= 1'b1;
            raw_sync_1 <= 1'b1;
        end else begin
            raw_sync_0 <= raw_in;
            raw_sync_1 <= raw_sync_0;
        end
    end

    // 消抖逻辑
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_stable <= 1'b1;
            cnt        <= 20'd0;
        end else begin
            if (raw_sync_1 == key_stable) begin
                cnt <= 20'd0;
            end else begin
                if (cnt >= CNT_MAX) begin
                    key_stable <= raw_sync_1;
                    cnt        <= 20'd0;
                end else begin
                    cnt <= cnt + 20'd1;
                end
            end
        end
    end

endmodule


//====================================================
// 输入控制模块
//====================================================
module Input_Controller (
    input wire        clk,
    input wire        rst_n,

    input wire        key_raw_up,
    input wire        key_raw_down,
    input wire        key_raw_left,
    input wire        key_raw_right,
    input wire        key_raw_start,
    input wire        key_raw_pause,

    output reg  [1:0] dir_out,
    output reg        start_pulse,
    output reg        pause_pulse
);

    //================================================
    // 方向编码
    //================================================
    localparam DIR_UP    = 2'd0;
    localparam DIR_DOWN  = 2'd1;
    localparam DIR_LEFT  = 2'd2;
    localparam DIR_RIGHT = 2'd3;

    //================================================
    // 1. 对所有输入做消抖
    //================================================
    wire key_up;
    wire key_down;
    wire key_left;
    wire key_right;
    wire key_start;
    wire key_pause;

    Debounce_Key u_db_up (
        .clk        (clk),
        .rst_n      (rst_n),
        .raw_in     (key_raw_up),
        .key_stable (key_up)
    );

    Debounce_Key u_db_down (
        .clk        (clk),
        .rst_n      (rst_n),
        .raw_in     (key_raw_down),
        .key_stable (key_down)
    );

    Debounce_Key u_db_left (
        .clk        (clk),
        .rst_n      (rst_n),
        .raw_in     (key_raw_left),
        .key_stable (key_left)
    );

    Debounce_Key u_db_right (
        .clk        (clk),
        .rst_n      (rst_n),
        .raw_in     (key_raw_right),
        .key_stable (key_right)
    );

    Debounce_Key u_db_start (
        .clk        (clk),
        .rst_n      (rst_n),
        .raw_in     (key_raw_start),
        .key_stable (key_start)
    );

    Debounce_Key u_db_pause (
        .clk        (clk),
        .rst_n      (rst_n),
        .raw_in     (key_raw_pause),
        .key_stable (key_pause)
    );

    //================================================
    // 2. 下降沿检测
    // 低有效按键：
    // key_x 从 1 变成 0，表示“刚刚按下”
    //================================================
    reg key_up_d;
    reg key_down_d;
    reg key_left_d;
    reg key_right_d;
    reg key_start_d;
    reg key_pause_d;

    wire up_press;
    wire down_press;
    wire left_press;
    wire right_press;
    wire start_press;
    wire pause_press;

    assign up_press    = key_up_d    && !key_up;
    assign down_press  = key_down_d  && !key_down;
    assign left_press  = key_left_d  && !key_left;
    assign right_press = key_right_d && !key_right;
    assign start_press = key_start_d && !key_start;
    assign pause_press = key_pause_d && !key_pause;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_up_d    <= 1'b1;
            key_down_d  <= 1'b1;
            key_left_d  <= 1'b1;
            key_right_d <= 1'b1;
            key_start_d <= 1'b1;
            key_pause_d <= 1'b1;
        end else begin
            key_up_d    <= key_up;
            key_down_d  <= key_down;
            key_left_d  <= key_left;
            key_right_d <= key_right;
            key_start_d <= key_start;
            key_pause_d <= key_pause;
        end
    end

    //================================================
    // 3. 方向控制
    // 只在“新按下方向键”的时候改变方向
    //================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dir_out <= DIR_RIGHT;
        end else begin
            if (up_press)
                dir_out <= DIR_UP;
            else if (down_press)
                dir_out <= DIR_DOWN;
            else if (left_press)
                dir_out <= DIR_LEFT;
            else if (right_press)
                dir_out <= DIR_RIGHT;
        end
    end

    //================================================
    // 4. 开始和暂停脉冲
    // 只输出一个 clk 周期
    //================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_pulse <= 1'b0;
            pause_pulse <= 1'b0;
        end else begin
            start_pulse <= start_press;
            pause_pulse <= pause_press;
        end
    end

endmodule
