`timescale 1ns / 1ps

//============================================================
// Music_Player.v
// DE2-115 / WM8731 音乐模块（BGM + 实时音效）
// 功能：
// 1. 自动通过 I2C 配置 WM8731 音频芯片
// 2. play_start 播放开场音效
// 3. dot_eat / pill_eat / ghost_eat / pac_death 触发实时音效
// 4. BGM 与 SFX 混音后输出到 Line Out / Headphone
//============================================================
module Music_Player (
    input  wire clk_50M,
    input  wire rst_n,
    input  wire play_start,
    input  wire dot_eat,        // 吃普通豆
    input  wire pill_eat,       // 吃药丸
    input  wire ghost_eat,      // 吃幽灵（能量模式）
    input  wire pac_death,      // 被幽灵吃/死亡

    output wire AUD_XCK,
    output reg  AUD_BCLK,
    output reg  AUD_DACLRCK,
    output reg  AUD_DACDAT,

    output wire I2C_SCLK,
    inout  wire I2C_SDAT
);

    //============================================================
    // 1. 生成音频主时钟 AUD_XCK
    //============================================================
    reg [1:0] xck_div;

    always @(posedge clk_50M or negedge rst_n) begin
        if (!rst_n)
            xck_div <= 2'd0;
        else
            xck_div <= xck_div + 2'd1;
    end

    assign AUD_XCK = xck_div[1];

    //============================================================
    // 2. I2C 配置 WM8731
    //============================================================
    wire i2c_config_done;

    Audio_I2C_Config u_i2c_config (
        .clk_50M     (clk_50M),
        .rst_n       (rst_n),
        .I2C_SCLK    (I2C_SCLK),
        .I2C_SDAT    (I2C_SDAT),
        .config_done (i2c_config_done)
    );

    //============================================================
    // 3. 播放控制（BGM）
    //============================================================
    reg play_start_d;
    wire play_start_rise = play_start & ~play_start_d;

    always @(posedge clk_50M or negedge rst_n) begin
        if (!rst_n)
            play_start_d <= 1'b0;
        else
            play_start_d <= play_start;
    end

    reg        music_active;
    reg [3:0]  note_index;
    reg [15:0] note_sample_cnt;
    reg [15:0] tone_div_cnt;
    reg        tone_level;

    localparam signed [15:0] AMP_POS = 16'sd6000;
    localparam signed [15:0] AMP_NEG = -16'sd6000;

    reg signed [15:0] audio_sample;

    //============================================================
    // 4. 音符参数
    //============================================================
    function [15:0] get_note_half_period;
        input [3:0] idx;
        begin
            case (idx)
                4'd0: get_note_half_period = 16'd55;
                4'd1: get_note_half_period = 16'd46;
                4'd2: get_note_half_period = 16'd37;
                4'd3: get_note_half_period = 16'd31;
                4'd4: get_note_half_period = 16'd46;
                4'd5: get_note_half_period = 16'd31;
                4'd6: get_note_half_period = 16'd23;
                default: get_note_half_period = 16'd0;
            endcase
        end
    endfunction

    function [15:0] get_note_duration;
        input [3:0] idx;
        begin
            case (idx)
                4'd0: get_note_duration = 16'd6000;
                4'd1: get_note_duration = 16'd6000;
                4'd2: get_note_duration = 16'd6000;
                4'd3: get_note_duration = 16'd9000;
                4'd4: get_note_duration = 16'd4000;
                4'd5: get_note_duration = 16'd4000;
                4'd6: get_note_duration = 16'd12000;
                default: get_note_duration = 16'd4000;
            endcase
        end
    endfunction

    //============================================================
    // 5. 音频串行输出（I2S 时序生成）
    //============================================================
    reg [3:0]  bclk_div;
    wire       bclk_tick = (bclk_div == 4'd15);

    reg [4:0]  bit_cnt;
    reg        channel;
    reg [15:0] shift_sample;

    wire sample_tick = bclk_tick && (AUD_BCLK == 1'b1) && (bit_cnt == 5'd15) && (channel == 1'b1);

    always @(posedge clk_50M or negedge rst_n) begin
        if (!rst_n) begin
            bclk_div    <= 4'd0;
            AUD_BCLK    <= 1'b0;
            AUD_DACLRCK <= 1'b0;
            AUD_DACDAT  <= 1'b0;
            bit_cnt     <= 5'd0;
            channel     <= 1'b0;
            shift_sample <= 16'd0;
        end else begin
            if (bclk_div == 4'd15) begin
                bclk_div <= 4'd0;
                AUD_BCLK <= ~AUD_BCLK;

                if (AUD_BCLK == 1'b1) begin
                    if (bit_cnt == 5'd0)
                        shift_sample <= final_sample[15:0];   // <--- 改这里：送混音后的数据

                    AUD_DACDAT <= shift_sample[15 - bit_cnt];

                    if (bit_cnt == 5'd15) begin
                        bit_cnt <= 5'd0;
                        channel <= ~channel;
                        AUD_DACLRCK <= ~channel;
                    end else begin
                        bit_cnt <= bit_cnt + 5'd1;
                    end
                end
            end else begin
                bclk_div <= bclk_div + 4'd1;
            end
        end
    end

    //============================================================
    // 6. 根据 sample_tick 更新 BGM 音符和方波
    //============================================================
    always @(posedge clk_50M or negedge rst_n) begin
        if (!rst_n) begin
            music_active    <= 1'b0;
            note_index      <= 4'd0;
            note_sample_cnt <= 16'd0;
            tone_div_cnt    <= 16'd0;
            tone_level      <= 1'b0;
            audio_sample    <= 16'sd0;
        end else begin
            if (play_start_rise && i2c_config_done) begin
                music_active    <= 1'b1;
                note_index      <= 4'd0;
                note_sample_cnt <= 16'd0;
                tone_div_cnt    <= 16'd0;
                tone_level      <= 1'b0;
            end

            if (sample_tick) begin
                if (music_active) begin
                    if (note_sample_cnt >= get_note_duration(note_index)) begin
                        note_sample_cnt <= 16'd0;
                        tone_div_cnt    <= 16'd0;
                        tone_level      <= 1'b0;

                        if (note_index >= 4'd6) begin
                            music_active <= 1'b0;
                            audio_sample <= 16'sd0;
                        end else begin
                            note_index <= note_index + 4'd1;
                        end
                    end else begin
                        note_sample_cnt <= note_sample_cnt + 16'd1;

                        if (get_note_half_period(note_index) == 16'd0) begin
                            audio_sample <= 16'sd0;
                        end else if (tone_div_cnt >= get_note_half_period(note_index)) begin
                            tone_div_cnt <= 16'd0;
                            tone_level   <= ~tone_level;
                            audio_sample <= tone_level ? AMP_NEG : AMP_POS;
                        end else begin
                            tone_div_cnt <= tone_div_cnt + 16'd1;
                            audio_sample <= tone_level ? AMP_POS : AMP_NEG;
                        end
                    end
                end else begin
                    audio_sample <= 16'sd0;
                end
            end
        end
    end

    //============================================================
    // SFX 实时音效生成器（电平检测版）
    // 输入已经是 50ms 展宽电平，sample_tick 每 20μs 来一次，
    // 50ms 内至少遇到 2500 次 sample_tick，必然触发
    //============================================================
    reg [15:0] sfx_timer;
    reg [15:0] sfx_period;
    reg [15:0] sfx_cnt;
    reg        sfx_toggle;
    reg        sfx_active;

    localparam signed [15:0] SFX_AMP = 16'sd5000;

    always @(posedge clk_50M or negedge rst_n) begin
        if (!rst_n) begin
            sfx_active <= 1'b0;
            sfx_timer  <= 16'd0;
            sfx_period <= 16'd0;
            sfx_cnt    <= 16'd0;
            sfx_toggle <= 1'b0;
        end else if (sample_tick) begin
            if (!sfx_active) begin
                // 优先级：death > ghost_eat > pill_eat > dot_eat
                if (pac_death) begin
                    sfx_active <= 1'b1;
                    sfx_timer  <= 16'd12000; // ~246 ms
                    sfx_period <= 16'd49;    // ~500 Hz
                    sfx_cnt    <= 16'd0;
                    sfx_toggle <= 1'b0;
                end else if (ghost_eat) begin
                    sfx_active <= 1'b1;
                    sfx_timer  <= 16'd6000;  // ~123 ms
                    sfx_period <= 16'd24;    // ~1 kHz
                    sfx_cnt    <= 16'd0;
                    sfx_toggle <= 1'b0;
                end else if (pill_eat) begin
                    sfx_active <= 1'b1;
                    sfx_timer  <= 16'd9000;  // ~184 ms
                    sfx_period <= 16'd12;    // ~2 kHz
                    sfx_cnt    <= 16'd0;
                    sfx_toggle <= 1'b0;
                end else if (dot_eat) begin
                    sfx_active <= 1'b1;
                    sfx_timer  <= 16'd4000;  // ~82 ms
                    sfx_period <= 16'd6;     // ~4 kHz
                    sfx_cnt    <= 16'd0;
                    sfx_toggle <= 1'b0;
                end
            end else begin
                if (sfx_timer == 16'd0) begin
                    sfx_active <= 1'b0;
                end else begin
                    sfx_timer <= sfx_timer - 1'b1;
                    if (sfx_cnt >= sfx_period) begin
                        sfx_cnt    <= 16'd0;
                        sfx_toggle <= ~sfx_toggle;
                    end else begin
                        sfx_cnt <= sfx_cnt + 1'b1;
                    end
                end
            end
        end
    end

    wire signed [15:0] sfx_sample = sfx_active ? (sfx_toggle ? SFX_AMP : -SFX_AMP) : 16'sd0;

    //============================================================
    // 8. 混音（BGM + SFX）
    // 两者幅度均较小（<< 6000），相加不会溢出 16bit
    //============================================================
    wire signed [15:0] final_sample = audio_sample + sfx_sample;

endmodule


//============================================================
// WM8731 I2C 配置模块（与原版完全一致）
//============================================================
module Audio_I2C_Config (
    input  wire clk_50M,
    input  wire rst_n,

    output reg  I2C_SCLK,
    inout  wire I2C_SDAT,

    output reg  config_done
);

    reg sdat_oe_low;
    assign I2C_SDAT = sdat_oe_low ? 1'b0 : 1'bz;

    reg [8:0] div_cnt;
    wire i2c_tick = (div_cnt == 9'd249);

    always @(posedge clk_50M or negedge rst_n) begin
        if (!rst_n)
            div_cnt <= 9'd0;
        else if (i2c_tick)
            div_cnt <= 9'd0;
        else
            div_cnt <= div_cnt + 9'd1;
    end

    localparam [7:0] DEV_ADDR = 8'h34;

    reg [3:0] reg_index;
    reg [15:0] config_word;

    always @(*) begin
        case (reg_index)
            4'd0: config_word = {7'd15, 9'h000};
            4'd1: config_word = {7'd0,  9'h017};
            4'd2: config_word = {7'd1,  9'h017};
            4'd3: config_word = {7'd2,  9'h079};
            4'd4: config_word = {7'd3,  9'h079};
            4'd5: config_word = {7'd4,  9'h012};
            4'd6: config_word = {7'd5,  9'h000};
            4'd7: config_word = {7'd6,  9'h000};
            4'd8: config_word = {7'd7,  9'h001};
            4'd9: config_word = {7'd8,  9'h000};
            4'd10: config_word = {7'd9, 9'h001};
            default: config_word = 16'h0000;
        endcase
    end

    reg [7:0] byte0;
    reg [7:0] byte1;
    reg [7:0] byte2;

    reg [4:0] state;
    reg [3:0] bit_cnt;
    reg [1:0] byte_sel;
    reg [7:0] tx_byte;

    localparam S_IDLE       = 5'd0;
    localparam S_START_0    = 5'd1;
    localparam S_START_1    = 5'd2;
    localparam S_SEND_LOW   = 5'd3;
    localparam S_SEND_HIGH  = 5'd4;
    localparam S_ACK_LOW    = 5'd5;
    localparam S_ACK_HIGH   = 5'd6;
    localparam S_STOP_0     = 5'd7;
    localparam S_STOP_1     = 5'd8;
    localparam S_NEXT       = 5'd9;
    localparam S_DONE       = 5'd10;

    always @(*) begin
        byte0 = DEV_ADDR;
        byte1 = config_word[15:8];
        byte2 = config_word[7:0];
        case (byte_sel)
            2'd0: tx_byte = byte0;
            2'd1: tx_byte = byte1;
            2'd2: tx_byte = byte2;
            default: tx_byte = 8'h00;
        endcase
    end

    always @(posedge clk_50M or negedge rst_n) begin
        if (!rst_n) begin
            I2C_SCLK    <= 1'b1;
            sdat_oe_low <= 1'b0;
            config_done <= 1'b0;
            reg_index   <= 4'd0;
            state       <= S_IDLE;
            bit_cnt     <= 4'd7;
            byte_sel    <= 2'd0;
        end else if (i2c_tick) begin
            case (state)
                S_IDLE: begin
                    config_done <= 1'b0;
                    I2C_SCLK    <= 1'b1;
                    sdat_oe_low <= 1'b0;
                    bit_cnt     <= 4'd7;
                    byte_sel    <= 2'd0;
                    state       <= S_START_0;
                end
                S_START_0: begin
                    I2C_SCLK    <= 1'b1;
                    sdat_oe_low <= 1'b0;
                    state       <= S_START_1;
                end
                S_START_1: begin
                    I2C_SCLK    <= 1'b1;
                    sdat_oe_low <= 1'b1;
                    state       <= S_SEND_LOW;
                end
                S_SEND_LOW: begin
                    I2C_SCLK <= 1'b0;
                    sdat_oe_low <= (tx_byte[bit_cnt] == 1'b0) ? 1'b1 : 1'b0;
                    state <= S_SEND_HIGH;
                end
                S_SEND_HIGH: begin
                    I2C_SCLK <= 1'b1;
                    if (bit_cnt == 4'd0) begin
                        bit_cnt <= 4'd7;
                        state   <= S_ACK_LOW;
                    end else begin
                        bit_cnt <= bit_cnt - 4'd1;
                        state   <= S_SEND_LOW;
                    end
                end
                S_ACK_LOW: begin
                    I2C_SCLK    <= 1'b0;
                    sdat_oe_low <= 1'b0;
                    state       <= S_ACK_HIGH;
                end
                S_ACK_HIGH: begin
                    I2C_SCLK <= 1'b1;
                    if (byte_sel == 2'd2) begin
                        byte_sel <= 2'd0;
                        state    <= S_STOP_0;
                    end else begin
                        byte_sel <= byte_sel + 2'd1;
                        state    <= S_SEND_LOW;
                    end
                end
                S_STOP_0: begin
                    I2C_SCLK    <= 1'b0;
                    sdat_oe_low <= 1'b1;
                    state       <= S_STOP_1;
                end
                S_STOP_1: begin
                    I2C_SCLK    <= 1'b1;
                    sdat_oe_low <= 1'b0;
                    state       <= S_NEXT;
                end
                S_NEXT: begin
                    if (reg_index >= 4'd10) begin
                        state <= S_DONE;
                    end else begin
                        reg_index <= reg_index + 4'd1;
                        bit_cnt   <= 4'd7;
                        byte_sel  <= 2'd0;
                        state     <= S_START_0;
                    end
                end
                S_DONE: begin
                    config_done <= 1'b1;
                    I2C_SCLK    <= 1'b1;
                    sdat_oe_low <= 1'b0;
                    state       <= S_DONE;
                end
                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule