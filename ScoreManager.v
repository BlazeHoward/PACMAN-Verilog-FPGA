`timescale 1ns / 1ps
`include "game_defines.v"

//====================================================
// ScoreManager 主模块
// 改动说明：
// 1. 上电后进入 STATE_MENU 而非 STATE_IDLE
// 2. 新增 STATE_READY：第一次 Enter 进入 READY，第二次 Enter 进入 PLAYING
// 3. WIN / GAME_OVER 按 Enter 回到 STATE_MENU（可重新选难度）
// 4. STATE_IDLE 保留兼容，行为同 MENU（fallback）
//====================================================
module ScoreManager (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [1:0]  difficulty,

    input  wire        start_pulse,

    input  wire        dot_eat,
    input  wire        pill_eat,
    input  wire        ghost_eat,
    input  wire        pac_death,

    output wire        power_active,
    output wire [9:0]  power_counter,
    output wire        game_win,
    output wire        game_over,
    output wire [2:0]  game_state,

    output wire [15:0] score,
    output wire [1:0]  lives,
    output wire        reset_positions,
    output wire        score_reset_pulse,

    output wire [15:0] score_bcd
);

    //====================================================
    // 游戏内部计时，用于能量豆持续时间递减
    //====================================================
    localparam TICK_DIV_100M = 24'd6_666_666;
    reg [23:0] tick_cnt;
    reg        game_tick;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_cnt  <= 24'd0;
            game_tick <= 1'b0;
        end else if (tick_cnt >= TICK_DIV_100M - 24'd1) begin
            tick_cnt  <= 24'd0;
            game_tick <= 1'b1;
        end else begin
            tick_cnt  <= tick_cnt + 24'd1;
            game_tick <= 1'b0;
        end
    end

    //====================================================
    // 三个难度的豆子总数
    //====================================================
    localparam [9:0] PELLET_SIMPLE = 10'd26;
    localparam [9:0] PELLET_MEDIUM = 10'd113;
    localparam [9:0] PELLET_HARD   = 10'd213;

    wire [9:0] pellet_target;

    assign pellet_target = (difficulty == 2'd0) ? PELLET_SIMPLE :
                           (difficulty == 2'd1) ? PELLET_MEDIUM :
                           (difficulty == 2'd2) ? PELLET_HARD :
                                                   PELLET_SIMPLE;

    //====================================================
    // 分数常量扩展到16位
    //====================================================
    localparam [15:0] SCORE_DOT_16   = {6'd0, `CFG_SCORE_DOT};
    localparam [15:0] SCORE_PILL_16  = {6'd0, `CFG_SCORE_PILL};
    localparam [15:0] SCORE_GHOST_16 = {6'd0, `CFG_SCORE_GHOST};

    //====================================================
    // 状态寄存器
    //====================================================
    reg [2:0]  state;
    reg [15:0] score_reg;
    reg [1:0]  lives_reg;
    reg [9:0]  power_cnt;
    reg        power_act;
    reg        reset_pos;
    reg        score_rst;
    reg        win_reg;
    reg        over_reg;

    reg [9:0] pellet_count;

    assign game_state        = state;
    assign score             = score_reg;
    assign lives             = lives_reg;
    assign power_active      = power_act;
    assign power_counter     = power_cnt;
    assign game_win          = win_reg;
    assign game_over         = over_reg;
    assign reset_positions   = reset_pos;
    assign score_reset_pulse = score_rst;

    bin_to_bcd bcd_inst (
        .bin(score_reg),
        .bcd(score_bcd)
    );

    //====================================================
    // 本周期加分与吃豆数量
    //====================================================
    wire [15:0] score_gain;
    wire [9:0]  pellet_gain;
    wire        eat_last_pellet;

    assign score_gain = (dot_eat                 ? SCORE_DOT_16   : 16'd0) +
                        (pill_eat                ? SCORE_PILL_16  : 16'd0) +
                        ((ghost_eat && power_act) ? SCORE_GHOST_16 : 16'd0);

    assign pellet_gain = (dot_eat  ? 10'd1 : 10'd0) +
                         (pill_eat ? 10'd1 : 10'd0);

    assign eat_last_pellet = (pellet_gain != 10'd0) &&
                             ((pellet_count + pellet_gain) >= pellet_target);

    //====================================================
    // 主状态机
    //====================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= `STATE_MENU;   // 改动：上电进菜单
            score_reg    <= 16'd0;
            lives_reg    <= `CFG_LIVES;
            power_cnt    <= 10'd0;
            power_act    <= 1'b0;
            reset_pos    <= 1'b0;
            score_rst    <= 1'b1;
            win_reg      <= 1'b0;
            over_reg     <= 1'b0;
            pellet_count <= 10'd0;
        end else begin
            reset_pos <= 1'b0;
            score_rst <= 1'b0;
            win_reg   <= 1'b0;
            over_reg  <= 1'b0;

            if (game_tick && power_act && power_cnt > 0)
                power_cnt <= power_cnt - 10'd1;

            case (state)

                //================================================
                // STATE_MENU：菜单待机，全部清零
                //================================================
                `STATE_MENU: begin
                    score_reg    <= 16'd0;
                    lives_reg    <= `CFG_LIVES;
                    power_cnt    <= 10'd0;
                    power_act    <= 1'b0;
                    pellet_count <= 10'd0;
                    score_rst    <= 1'b1;

                    if (start_pulse) begin
                        state     <= `STATE_READY;
                        score_rst <= 1'b0;
                        reset_pos <= 1'b1;   // 预复位角色位置
                    end
                end

                //================================================
                // STATE_READY：等待最终确认
                //================================================
                `STATE_READY: begin
                    if (start_pulse) begin
                        state     <= `STATE_PLAYING;
                        reset_pos <= 1'b1;   // 正式复位并开始
                    end
                end

                //================================================
                // STATE_IDLE：保留兼容，行为同 MENU
                //================================================
                `STATE_IDLE: begin
                    score_reg    <= 16'd0;
                    lives_reg    <= `CFG_LIVES;
                    power_cnt    <= 10'd0;
                    power_act    <= 1'b0;
                    pellet_count <= 10'd0;
                    score_rst    <= 1'b1;

                    if (start_pulse) begin
                        state     <= `STATE_READY;
                        score_rst <= 1'b0;
                        reset_pos <= 1'b1;
                    end
                end

                //================================================
                // 普通游戏状态（以下保持原逻辑不变）
                //================================================
                `STATE_PLAYING: begin
                    if (score_gain != 16'd0)
                        score_reg <= score_reg + score_gain;

                    if (pellet_gain != 10'd0)
                        pellet_count <= pellet_count + pellet_gain;

                    if (pill_eat) begin
                        power_act <= 1'b1;
                        power_cnt <= `CFG_POWER_DURATION;
                        state     <= `STATE_POWER_MODE;
                    end else if (power_act) begin
                        state <= `STATE_POWER_MODE;
                    end

                    if (power_act && power_cnt == 0)
                        power_act <= 1'b0;

                    if (eat_last_pellet) begin
                        state   <= `STATE_WIN;
                        win_reg <= 1'b1;
                    end

                    if (pac_death && !power_act) begin
                        if (lives_reg > 1) begin
                            lives_reg <= lives_reg - 2'd1;
                            state     <= `STATE_DEAD;
                            reset_pos <= 1'b1;
                        end else begin
                            lives_reg <= 2'd0;
                            state     <= `STATE_GAME_OVER;
                            over_reg  <= 1'b1;
                        end
                    end
                end

                `STATE_POWER_MODE: begin
                    if (score_gain != 16'd0)
                        score_reg <= score_reg + score_gain;

                    if (pellet_gain != 10'd0)
                        pellet_count <= pellet_count + pellet_gain;

                    if (pill_eat) begin
                        power_act <= 1'b1;
                        power_cnt <= `CFG_POWER_DURATION;
                    end

                    if (power_cnt == 0 && game_tick) begin
                        power_act <= 1'b0;
                        state     <= `STATE_PLAYING;
                    end

                    if (eat_last_pellet) begin
                        state   <= `STATE_WIN;
                        win_reg <= 1'b1;
                    end
                end

                `STATE_DEAD: begin
                    power_act <= 1'b0;
                    power_cnt <= 10'd0;
                    state     <= `STATE_PLAYING;
                end

                //================================================
                // 胜利 — Enter 回到菜单
                //================================================
                `STATE_WIN: begin
                    power_act <= 1'b0;
                    power_cnt <= 10'd0;

                    if (start_pulse)
                        state <= `STATE_MENU;
                end

                //================================================
                // 游戏结束 — Enter 回到菜单
                //================================================
                `STATE_GAME_OVER: begin
                    power_act <= 1'b0;
                    power_cnt <= 10'd0;

                    if (start_pulse)
                        state <= `STATE_MENU;
                end

                default: begin
                    state <= `STATE_MENU;
                end
            endcase
        end
    end

endmodule


//====================================================
// BCD转换子模块（保持原样）
//====================================================
module bin_to_bcd (
    input  [15:0] bin,
    output [15:0] bcd
);
    reg [15:0] bcd_reg;
    reg [15:0] bin_reg;
    integer i;

    always @(*) begin
        bcd_reg = 16'd0;
        bin_reg = bin;

        for (i = 0; i < 16; i = i + 1) begin
            if (bcd_reg[3:0]   >= 4'd5) bcd_reg[3:0]   = bcd_reg[3:0]   + 4'd3;
            if (bcd_reg[7:4]   >= 4'd5) bcd_reg[7:4]   = bcd_reg[7:4]   + 4'd3;
            if (bcd_reg[11:8]  >= 4'd5) bcd_reg[11:8]  = bcd_reg[11:8]  + 4'd3;
            if (bcd_reg[15:12] >= 4'd5) bcd_reg[15:12] = bcd_reg[15:12] + 4'd3;

            bcd_reg = {bcd_reg[14:0], bin_reg[15]};
            bin_reg = bin_reg << 1;
        end
    end

    assign bcd = bcd_reg;
endmodule
