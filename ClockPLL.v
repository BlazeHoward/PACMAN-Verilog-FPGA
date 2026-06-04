`timescale 1ns / 1ps

module ClockPLL (
    input  wire clk_50M,
    input  wire rst_n,
    output wire clk_25M,
    output wire clk_100M,
    output wire clk_sys,
    output wire locked
);

    wire clk_25M_int;
    wire clk_100M_int;

    pll_ip_core u_pll_ip (
        .areset (~rst_n),
        .inclk0 (clk_50M),
        .c0     (clk_100M_int),   // c0 输出 100MHz
        .c1     (clk_25M_int),    // c1 输出 25MHz
        .locked (locked)
    );

    assign clk_25M  = clk_25M_int;
    assign clk_100M = clk_100M_int;
    assign clk_sys  = clk_100M_int;

endmodule
