`timescale 1ns / 1ps

module LFSR (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire [15:0] seed,       // 外部种子（例如来自硬件真随机源或固定值）
    output wire [15:0] random_num
);

    reg [15:0] lfsr_reg;
    wire feedback = lfsr_reg[15] ^ lfsr_reg[13] ^ lfsr_reg[12] ^ lfsr_reg[10];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // 复位时：若 seed 非零则加载 seed，否则用固定种子
            if (seed == 16'd0)
                lfsr_reg <= 16'hACE1;
            else
                lfsr_reg <= seed;
        end else if (enable) begin
            if (lfsr_reg == 16'd0)
                lfsr_reg <= 16'd1;
            else
                lfsr_reg <= {lfsr_reg[14:0], feedback};
        end
    end

    assign random_num = lfsr_reg;

endmodule
