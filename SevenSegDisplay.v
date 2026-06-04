`timescale 1ns / 1ps

module SevenSegDisplay (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [15:0] score_bcd,
    input  wire [1:0]  lives,

    output wire [6:0]  HEX0,
    output wire [6:0]  HEX1,
    output wire [6:0]  HEX2,
    output wire [6:0]  HEX3,
    output wire [6:0]  HEX4,
    output wire [6:0]  HEX5,
    output wire [6:0]  HEX6,
    output wire [6:0]  HEX7
);

    //============================================================
    // DE2-115 七段数码管：低电平点亮
    // 位序：{g,f,e,d,c,b,a}
    //============================================================
    function [6:0] bcd_to_seg;
        input [3:0] num;
        begin
            case (num)
                4'd0: bcd_to_seg = 7'b1000000;
                4'd1: bcd_to_seg = 7'b1111001;
                4'd2: bcd_to_seg = 7'b0100100;
                4'd3: bcd_to_seg = 7'b0110000;
                4'd4: bcd_to_seg = 7'b0011001;
                4'd5: bcd_to_seg = 7'b0010010;
                4'd6: bcd_to_seg = 7'b0000010;
                4'd7: bcd_to_seg = 7'b1111000;
                4'd8: bcd_to_seg = 7'b0000000;
                4'd9: bcd_to_seg = 7'b0010000;
                default: bcd_to_seg = 7'b1111111;
            endcase
        end
    endfunction

    wire [6:0] blank;
    assign blank = 7'b1111111;

    //============================================================
    // 显示安排：
    // HEX0：分数个位
    // HEX1：分数十位
    // HEX2：分数百位
    // HEX3：分数千位
    // HEX4：生命值
    // HEX5~HEX7：熄灭
    //============================================================
    assign HEX0 = rst_n ? bcd_to_seg(score_bcd[3:0])   : blank;
    assign HEX1 = rst_n ? bcd_to_seg(score_bcd[7:4])   : blank;
    assign HEX2 = rst_n ? bcd_to_seg(score_bcd[11:8])  : blank;
    assign HEX3 = rst_n ? bcd_to_seg(score_bcd[15:12]) : blank;

    assign HEX4 = rst_n ? bcd_to_seg({2'b00, lives})   : blank;

    assign HEX5 = blank;
    assign HEX6 = blank;
    assign HEX7 = blank;

endmodule
