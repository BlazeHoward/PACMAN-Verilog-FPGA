`timescale 1ns / 1ps
`include "game_defines.v"

//============================================================
// PS/2 接收模块（保持原样）
//============================================================
module PS2_Receiver (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ps2_clk,
    input  wire       ps2_dat,

    output reg  [7:0] scan_code,
    output reg        code_valid
);

    reg [2:0] ps2_clk_sync;
    reg [2:0] ps2_dat_sync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ps2_clk_sync <= 3'b111;
            ps2_dat_sync <= 3'b111;
        end else begin
            ps2_clk_sync <= {ps2_clk_sync[1:0], ps2_clk};
            ps2_dat_sync <= {ps2_dat_sync[1:0], ps2_dat};
        end
    end

    wire ps2_clk_fall = (ps2_clk_sync[2:1] == 2'b10);
    wire ps2_dat_s    = ps2_dat_sync[2];

    reg [3:0]  bit_cnt;
    reg [10:0] frame;
    reg [17:0] timeout_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_cnt     <= 4'd0;
            frame       <= 11'd0;
            scan_code   <= 8'd0;
            code_valid  <= 1'b0;
            timeout_cnt <= 18'd0;
        end else begin
            code_valid <= 1'b0;

            if (ps2_clk_fall) begin
                timeout_cnt <= 18'd0;
                frame[bit_cnt] <= ps2_dat_s;

                if (bit_cnt == 4'd10) begin
                    bit_cnt <= 4'd0;

                    if ((frame[0] == 1'b0) &&
                        (ps2_dat_s == 1'b1) &&
                        ((^({frame[8:1], frame[9]})) == 1'b1)) begin
                        scan_code  <= frame[8:1];
                        code_valid <= 1'b1;
                    end
                end else begin
                    bit_cnt <= bit_cnt + 4'd1;
                end
            end else begin
                if (bit_cnt != 4'd0) begin
                    if (timeout_cnt >= 18'd200_000) begin
                        bit_cnt     <= 4'd0;
                        timeout_cnt <= 18'd0;
                    end else begin
                        timeout_cnt <= timeout_cnt + 18'd1;
                    end
                end else begin
                    timeout_cnt <= 18'd0;
                end
            end
        end
    end

endmodule


//============================================================
// PS/2 键盘控制模块
// 修改点：
// 1. 新增 dir_pulse_sent 锁存，防止 typematic repeat 导致连跳
// 2. 方向键 break 时清零 dir_pulse_sent
// 3. 方向键 make 时只在 dir_pulse_sent==0 才发脉冲
//============================================================
module PS2_Keyboard_Controller (
    input  wire       clk,
    input  wire       rst_n,

    input  wire       ps2_clk,
    input  wire       ps2_dat,

    output reg  [1:0] dir_out,
    output reg        start_pulse,
    output reg        pause_pulse,
    output reg        dir_pulse,
    output reg        dir_pressed,

    output wire [7:0] debug_scan_code,
    output wire       debug_code_valid
);

    wire [7:0] scan_code;
    wire       code_valid;

    assign debug_scan_code  = scan_code;
    assign debug_code_valid = code_valid;

    PS2_Receiver u_ps2_receiver (
        .clk        (clk),
        .rst_n      (rst_n),
        .ps2_clk    (ps2_clk),
        .ps2_dat    (ps2_dat),
        .scan_code  (scan_code),
        .code_valid (code_valid)
    );

    localparam SC_EXT   = 8'hE0;
    localparam SC_BREAK = 8'hF0;

    localparam SC_W     = 8'h1D;
    localparam SC_A     = 8'h1C;
    localparam SC_S     = 8'h1B;
    localparam SC_D     = 8'h23;

    localparam SC_UP    = 8'h75;
    localparam SC_DOWN  = 8'h72;
    localparam SC_LEFT  = 8'h6B;
    localparam SC_RIGHT = 8'h74;

    localparam SC_ENTER = 8'h5A;
    localparam SC_SPACE = 8'h29;
    localparam SC_P     = 8'h4D;

    reg ext_seen;
    reg break_seen;

    reg enter_down;
    reg space_down;
    reg p_down;

    //============================================================
    // 新增：方向键脉冲已发送锁存
    // 防止 PS/2 键盘 typematic repeat（自动重发）导致菜单连跳
    //============================================================
    reg dir_pulse_sent;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dir_out     <= `DIR_RIGHT;
            start_pulse <= 1'b0;
            pause_pulse <= 1'b0;
            dir_pulse   <= 1'b0;
            dir_pressed <= 1'b0;
            dir_pulse_sent <= 1'b0;  // 新增

            ext_seen    <= 1'b0;
            break_seen  <= 1'b0;

            enter_down  <= 1'b0;
            space_down  <= 1'b0;
            p_down      <= 1'b0;
        end else begin
            start_pulse <= 1'b0;
            pause_pulse <= 1'b0;
            dir_pulse   <= 1'b0;

            if (code_valid) begin
                if (scan_code == SC_EXT) begin
                    ext_seen <= 1'b1;
                end else if (scan_code == SC_BREAK) begin
                    break_seen <= 1'b1;
                end else begin
                    //========================================================
                    // 松开按键
                    //========================================================
                    if (break_seen) begin
                        if (!ext_seen) begin
                            case (scan_code)
                                SC_ENTER: enter_down <= 1'b0;
                                SC_SPACE: space_down <= 1'b0;
                                SC_P:     p_down     <= 1'b0;
                                // 新增：松开 WASD 时清零脉冲锁存
                                SC_W, SC_A, SC_S, SC_D: begin
                                    dir_pressed <= 1'b0;
                                    dir_pulse_sent <= 1'b0;
                                end
                                default: ;
                            endcase
                        end else begin
                            case (scan_code)
                                // 新增：松开方向键时清零脉冲锁存
                                SC_UP, SC_DOWN, SC_LEFT, SC_RIGHT: begin
                                    dir_pressed <= 1'b0;
                                    dir_pulse_sent <= 1'b0;
                                end
                                default: ;
                            endcase
                        end

                        ext_seen   <= 1'b0;
                        break_seen <= 1'b0;
                    end

                    //========================================================
                    // 按下按键
                    //========================================================
                    else begin
                        if (ext_seen) begin
                            case (scan_code)
                                // 修改：只在首次按下时产生 dir_pulse，防止重发连跳
                                SC_UP:    begin
                                    dir_out <= `DIR_UP;
                                    if (!dir_pulse_sent) begin dir_pulse <= 1'b1; dir_pulse_sent <= 1'b1; end
                                    dir_pressed <= 1'b1;
                                end
                                SC_DOWN:  begin
                                    dir_out <= `DIR_DOWN;
                                    if (!dir_pulse_sent) begin dir_pulse <= 1'b1; dir_pulse_sent <= 1'b1; end
                                    dir_pressed <= 1'b1;
                                end
                                SC_LEFT:  begin
                                    dir_out <= `DIR_LEFT;
                                    if (!dir_pulse_sent) begin dir_pulse <= 1'b1; dir_pulse_sent <= 1'b1; end
                                    dir_pressed <= 1'b1;
                                end
                                SC_RIGHT: begin
                                    dir_out <= `DIR_RIGHT;
                                    if (!dir_pulse_sent) begin dir_pulse <= 1'b1; dir_pulse_sent <= 1'b1; end
                                    dir_pressed <= 1'b1;
                                end
                                default: ;
                            endcase

                            ext_seen <= 1'b0;
                        end else begin
                            case (scan_code)
                                // 修改：只在首次按下时产生 dir_pulse，防止重发连跳
                                SC_W: begin
                                    dir_out <= `DIR_UP;
                                    if (!dir_pulse_sent) begin dir_pulse <= 1'b1; dir_pulse_sent <= 1'b1; end
                                    dir_pressed <= 1'b1;
                                end
                                SC_S: begin
                                    dir_out <= `DIR_DOWN;
                                    if (!dir_pulse_sent) begin dir_pulse <= 1'b1; dir_pulse_sent <= 1'b1; end
                                    dir_pressed <= 1'b1;
                                end
                                SC_A: begin
                                    dir_out <= `DIR_LEFT;
                                    if (!dir_pulse_sent) begin dir_pulse <= 1'b1; dir_pulse_sent <= 1'b1; end
                                    dir_pressed <= 1'b1;
                                end
                                SC_D: begin
                                    dir_out <= `DIR_RIGHT;
                                    if (!dir_pulse_sent) begin dir_pulse <= 1'b1; dir_pulse_sent <= 1'b1; end
                                    dir_pressed <= 1'b1;
                                end

                                SC_ENTER: begin
                                    if (!enter_down) begin
                                        start_pulse <= 1'b1;
                                        enter_down  <= 1'b1;
                                    end
                                end

                                SC_SPACE: begin
                                    if (!space_down) begin
                                        pause_pulse <= 1'b1;
                                        space_down  <= 1'b1;
                                    end
                                end

                                SC_P: begin
                                    if (!p_down) begin
                                        pause_pulse <= 1'b1;
                                        p_down      <= 1'b1;
                                    end
                                end

                                default: ;
                            endcase
                        end
                    end
                end
            end
        end
    end

endmodule
