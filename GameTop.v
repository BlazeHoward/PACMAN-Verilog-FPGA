`timescale 1ns / 1ps
`include "game_defines.v"

module GameTop (
    input  wire        clk_50M,
    input  wire        rst_n,

    input  wire        key_up,
    input  wire        key_down,
    input  wire        key_left,
    input  wire        key_right,

    input  wire        sw_start,
    input  wire        sw_pause,
    input  wire [1:0]  difficulty,

    input  wire        ps2_clk,
    input  wire        ps2_dat,

    output wire        vga_clk_out,
    output wire        vga_hs,
    output wire        vga_vs,
    output wire        vga_blank_n,
    output wire        vga_sync_n,
    output wire [7:0]  vga_r,
    output wire [7:0]  vga_g,
    output wire [7:0]  vga_b,

    output wire [6:0]  HEX0,
    output wire [6:0]  HEX1,
    output wire [6:0]  HEX2,
    output wire [6:0]  HEX3,
    output wire [6:0]  HEX4,
    output wire [6:0]  HEX5,
    output wire [6:0]  HEX6,
    output wire [6:0]  HEX7,

    output wire        AUD_XCK,
    output wire        AUD_BCLK,
    output wire        AUD_DACLRCK,
    output wire        AUD_DACDAT,
    output wire        I2C_SCLK,
    inout  wire        I2C_SDAT
);

    //============================================================
    // 时钟与复位
    //============================================================
    wire clk_25M;
    wire clk_100M;
    wire clk_sys;
    wire pll_locked;

    ClockPLL u_pll (
        .clk_50M  (clk_50M),
        .rst_n    (rst_n),
        .clk_25M  (clk_25M),
        .clk_100M (clk_100M),
        .clk_sys  (clk_sys),
        .locked   (pll_locked)
    );

    wire sys_rst_n = rst_n & pll_locked;

    assign vga_clk_out = clk_25M;

    //============================================================
    // 难度选择锁存（保留拨码开关作为默认值）
    //============================================================
    reg [1:0]  difficulty_reg;
    reg [23:0] diff_lock_cnt;
    reg        diff_locked;

    always @(posedge clk_100M or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            difficulty_reg <= 2'd0;
            diff_lock_cnt  <= 24'd0;
            diff_locked    <= 1'b0;
        end else if (!diff_locked) begin
            if (diff_lock_cnt >= 24'd5_000_000) begin
                difficulty_reg <= difficulty;
                diff_locked    <= 1'b1;
            end else begin
                diff_lock_cnt <= diff_lock_cnt + 1'b1;
            end
        end else if (game_state == `STATE_MENU && start_pulse) begin
            difficulty_reg <= menu_sel;
        end
    end

    //============================================================
    // 菜单导航：3态状态机
    // IDLE     -> 等待 dir_pulse，收到后立即切换，进入150ms冷却
    // COOLDOWN -> 150ms内屏蔽所有脉冲（防机械抖动连跳）
    // REPEAT   -> 冷却结束后若仍按住，每100ms自动重复；松开回IDLE
    //============================================================
    reg [1:0] menu_sel;
    reg       menu_sel_init;

    reg [1:0]  menu_nav_state;
    reg [23:0] nav_timer;

    localparam NAV_IDLE      = 2'd0;
    localparam NAV_COOLDOWN  = 2'd1;
    localparam NAV_REPEAT    = 2'd2;

    localparam MENU_COOLDOWN     = 24'd15_000_000; // 150ms 消抖冷却
    localparam NAV_REPEAT_PERIOD = 24'd10_000_000; // 100ms 长按重复周期

    always @(posedge clk_100M or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            menu_sel       <= 2'd0;
            menu_sel_init  <= 1'b0;
            menu_nav_state <= NAV_IDLE;
            nav_timer      <= 24'd0;
        end else begin
            // 初始化：拨码开关值作为默认高亮
            if (!menu_sel_init && diff_locked) begin
                menu_sel       <= difficulty_reg;
                menu_sel_init  <= 1'b1;
                menu_nav_state <= NAV_IDLE;
                nav_timer      <= 24'd0;
            end else if (game_state == `STATE_WIN || game_state == `STATE_GAME_OVER) begin
                menu_sel       <= difficulty_reg;
                menu_nav_state <= NAV_IDLE;
                nav_timer      <= 24'd0;
            end else if (game_state == `STATE_MENU) begin
                case (menu_nav_state)

                    //------------------------------------------------
                    // IDLE：等待首次脉冲
                    //------------------------------------------------
                    NAV_IDLE: begin
                        if (keyboard_dir_pulse) begin
                            case (keyboard_dir)
                                `DIR_UP:   menu_sel <= (menu_sel == 2'd0) ? 2'd2 : menu_sel - 2'd1;
                                `DIR_DOWN: menu_sel <= (menu_sel == 2'd2) ? 2'd0 : menu_sel + 2'd1;
                                default: ;
                            endcase
                            menu_nav_state <= NAV_COOLDOWN;
                            nav_timer      <= 24'd0;
                        end
                    end

                    //------------------------------------------------
                    // COOLDOWN：150ms强制冷却，屏蔽所有脉冲
                    //------------------------------------------------
                    NAV_COOLDOWN: begin
                        if (nav_timer >= MENU_COOLDOWN) begin
                            nav_timer <= 24'd0;
                            // 冷却结束，检查按键是否仍按住
                            if (keyboard_dir_pressed)
                                menu_nav_state <= NAV_REPEAT;
                            else
                                menu_nav_state <= NAV_IDLE;
                        end else begin
                            nav_timer <= nav_timer + 1'b1;
                        end
                    end

                    //------------------------------------------------
                    // REPEAT：长按连续滚动，每100ms切换一次
                    //------------------------------------------------
                    NAV_REPEAT: begin
                        if (!keyboard_dir_pressed) begin
                            // 按键已松开，回到待机
                            menu_nav_state <= NAV_IDLE;
                            nav_timer      <= 24'd0;
                        end else if (nav_timer >= NAV_REPEAT_PERIOD) begin
                            // 重复周期到，继续切换
                            nav_timer <= 24'd0;
                            case (keyboard_dir)
                                `DIR_UP:   menu_sel <= (menu_sel == 2'd0) ? 2'd2 : menu_sel - 2'd1;
                                `DIR_DOWN: menu_sel <= (menu_sel == 2'd2) ? 2'd0 : menu_sel + 2'd1;
                                default: ;
                            endcase
                        end else begin
                            nav_timer <= nav_timer + 1'b1;
                        end
                    end

                    default: menu_nav_state <= NAV_IDLE;
                endcase
            end else begin
                // 非菜单状态，导航状态机复位
                menu_nav_state <= NAV_IDLE;
                nav_timer      <= 24'd0;
            end
        end
    end

    //============================================================
    // 游戏 Tick (修改为匹配 8 帧平滑插值的完美周期)
    //============================================================
    localparam [26:0] MOVE_TICK_DIV = 27'd13_440_000; // 原为 16_666_666

    reg [26:0] tick_cnt;
    reg        move_en;

    always @(posedge clk_100M or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            tick_cnt <= 27'd0;
            move_en  <= 1'b0;
        end else if (tick_cnt >= MOVE_TICK_DIV - 27'd1) begin
            tick_cnt <= 27'd0;
            move_en  <= 1'b1;
        end else begin
            tick_cnt <= tick_cnt + 27'd1;
            move_en  <= 1'b0;
        end
    end

    //============================================================
    // 共享信号声明
    //============================================================
    wire [4:0] curr_width;
    wire [4:0] curr_height;

    wire [4:0] vga_addr_x;
    wire [4:0] vga_addr_y;
    wire [2:0] vga_map_data;

    wire [2:0] logic_rd_data;
    wire       refresh_done;

    wire [4:0] pac_spawn_x;
    wire [4:0] pac_spawn_y;
    wire [4:0] ghost_spawn_x;
    wire [4:0] ghost_spawn_y;

    wire [4:0] pac_x;
    wire [4:0] pac_y;
	 wire [1:0] pac_dir;              // 新增：串联方向信号
    wire [4:0] pac_next_x;
    wire [4:0] pac_next_y;
    wire       pac_move_req;
    wire       dot_eat;
    wire       pill_eat;

    wire [4:0] ghost0_x;
    wire [4:0] ghost0_y;
    wire [4:0] ghost0_next_x;
    wire [4:0] ghost0_next_y;
    wire       ghost0_move_req;

    wire [4:0] ghost1_x;
    wire [4:0] ghost1_y;
    wire [4:0] ghost1_next_x;
    wire [4:0] ghost1_next_y;
    wire       ghost1_move_req;

    wire [4:0] ghost2_x;
    wire [4:0] ghost2_y;
    wire [4:0] ghost2_next_x;
    wire [4:0] ghost2_next_y;
    wire       ghost2_move_req;

    wire [4:0] ghost3_x;
    wire [4:0] ghost3_y;
    wire [4:0] ghost3_next_x;
    wire [4:0] ghost3_next_y;
    wire       ghost3_move_req;

    reg pac_death;
    reg ghost_eat;
    reg reset_pac;
    reg reset_ghost0;
    reg reset_ghost1;
    reg reset_ghost2;
    reg reset_ghost3;

    reg ghost0_respawn_wait;
    reg ghost1_respawn_wait;
    reg ghost2_respawn_wait;
    reg ghost3_respawn_wait;

    reg [4:0] pac_prev_x;
    reg [4:0] pac_prev_y;

    reg [4:0] ghost0_prev_x;
    reg [4:0] ghost0_prev_y;
    reg [4:0] ghost1_prev_x;
    reg [4:0] ghost1_prev_y;
    reg [4:0] ghost2_prev_x;
    reg [4:0] ghost2_prev_y;
    reg [4:0] ghost3_prev_x;
    reg [4:0] ghost3_prev_y;

    reg collision_check_pending;

    wire       power_active;
    wire [9:0] power_counter;
    wire       game_win;
    wire       game_over;
    wire [2:0] game_state;
    wire [15:0] score;
    wire [1:0] lives;
    wire       reset_positions;
    wire       score_reset_pulse;
    wire [15:0] score_bcd;

    //============================================================
    // PS/2 键盘输入
    //============================================================
    wire [1:0] keyboard_dir;
    wire       keyboard_start_pulse;
    wire       keyboard_pause_pulse;
    wire       keyboard_dir_pulse;
    wire       keyboard_dir_pressed;

    PS2_Keyboard_Controller u_keyboard (
        .clk           (clk_100M),
        .rst_n         (sys_rst_n),
        .ps2_clk       (ps2_clk),
        .ps2_dat       (ps2_dat),
        .dir_out       (keyboard_dir),
        .dir_pulse     (keyboard_dir_pulse),
        .dir_pressed   (keyboard_dir_pressed),
        .start_pulse   (keyboard_start_pulse),
        .pause_pulse   (keyboard_pause_pulse)
    );

    wire [1:0] key_dir;
    wire       start_pulse;
    wire       pause_pulse;

    assign key_dir     = keyboard_dir;
    assign start_pulse = keyboard_start_pulse;
    assign pause_pulse = keyboard_pause_pulse;

    //============================================================
    // 暂停状态
    //============================================================
    reg paused_by_key;

    always @(posedge clk_100M or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            paused_by_key <= 1'b0;
        end else begin
            if (game_state == `STATE_MENU ||
                game_state == `STATE_READY ||
                game_state == `STATE_WIN ||
                game_state == `STATE_GAME_OVER ||
                game_state == `STATE_DEAD) begin
                paused_by_key <= 1'b0;
            end else if (pause_pulse) begin
                paused_by_key <= ~paused_by_key;
            end
        end
    end

    wire paused = paused_by_key | sw_pause;

    //============================================================
    // 只有 PLAYING / POWER_MODE 时角色才允许移动
    //============================================================
    wire game_running = (game_state == `STATE_PLAYING) ||
                        (game_state == `STATE_POWER_MODE);

    wire game_update_en = move_en & ~paused & game_running;

   //============================================================
    // [改动 1 开始] 幽灵独立速度分频器（难度感知）
    //============================================================
    reg [1:0] g0_div_cnt;
    reg [1:0] g1_div_cnt;
    reg [1:0] g2_div_cnt;
    reg [1:0] g3_div_cnt;

    wire [1:0] g0_cfg = (difficulty_reg == 2'd0) ? 2'd1 : 2'd0; 
    wire [1:0] g1_cfg = (difficulty_reg == 2'd2) ? 2'd0 : 2'd1;
    wire [1:0] g2_cfg = 2'd1;
    wire [1:0] g3_cfg = 2'd1;

    // 🌟 修复关键：将 tick 信号改为 wire，消除 1 拍延迟！所有人和检测同时触发！
    wire g0_tick = game_update_en && (g0_div_cnt >= g0_cfg);
    wire g1_tick = game_update_en && (g1_div_cnt >= g1_cfg);
    wire g2_tick = game_update_en && (g2_div_cnt >= g2_cfg);
    wire g3_tick = game_update_en && (g3_div_cnt >= g3_cfg);

    always @(posedge clk_100M or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            g0_div_cnt <= 2'd0;
            g1_div_cnt <= 2'd0;
            g2_div_cnt <= 2'd0;
            g3_div_cnt <= 2'd0;
        end else if (game_update_en) begin
            if (g0_div_cnt >= g0_cfg) g0_div_cnt <= 2'd0; else g0_div_cnt <= g0_div_cnt + 2'd1;
            if (g1_div_cnt >= g1_cfg) g1_div_cnt <= 2'd0; else g1_div_cnt <= g1_div_cnt + 2'd1;
            if (g2_div_cnt >= g2_cfg) g2_div_cnt <= 2'd0; else g2_div_cnt <= g2_div_cnt + 2'd1;
            if (g3_div_cnt >= g3_cfg) g3_div_cnt <= 2'd0; else g3_div_cnt <= g3_div_cnt + 2'd1;
        end
    end
    // [改动 1 结束]
    //============================================================
    // 幽灵启用策略
    //============================================================
    localparam [4:0] GHOST_HIDE_POS = 5'd31;

    wire ghost0_active = 1'b1;
    wire ghost1_active = (difficulty_reg != 2'd0);
    wire ghost2_active = (difficulty_reg == 2'd2);
    wire ghost3_active = (difficulty_reg == 2'd2);

    wire [4:0] ghost1_spawn_x = (difficulty_reg == 2'd1) ? 5'd13 :
                                 (difficulty_reg == 2'd2) ? 5'd1  : GHOST_HIDE_POS;
    wire [4:0] ghost1_spawn_y = (difficulty_reg == 2'd1) ? 5'd1  :
                                 (difficulty_reg == 2'd2) ? 5'd1  : GHOST_HIDE_POS;

    wire [4:0] ghost2_spawn_x = (difficulty_reg == 2'd2) ? 5'd17 : GHOST_HIDE_POS;
    wire [4:0] ghost2_spawn_y = (difficulty_reg == 2'd2) ? 5'd1  : GHOST_HIDE_POS;

    wire [4:0] ghost3_spawn_x = (difficulty_reg == 2'd2) ? 5'd17 : GHOST_HIDE_POS;
    wire [4:0] ghost3_spawn_y = (difficulty_reg == 2'd2) ? 5'd19 : GHOST_HIDE_POS;

    wire [4:0] ghost0_draw_x = ghost0_active ? ghost0_x : GHOST_HIDE_POS;
    wire [4:0] ghost0_draw_y = ghost0_active ? ghost0_y : GHOST_HIDE_POS;
    wire [4:0] ghost1_draw_x = ghost1_active ? ghost1_x : GHOST_HIDE_POS;
    wire [4:0] ghost1_draw_y = ghost1_active ? ghost1_y : GHOST_HIDE_POS;
    wire [4:0] ghost2_draw_x = ghost2_active ? ghost2_x : GHOST_HIDE_POS;
    wire [4:0] ghost2_draw_y = ghost2_active ? ghost2_y : GHOST_HIDE_POS;
    wire [4:0] ghost3_draw_x = ghost3_active ? ghost3_x : GHOST_HIDE_POS;
    wire [4:0] ghost3_draw_y = ghost3_active ? ghost3_y : GHOST_HIDE_POS;

    //============================================================
    // LFSR 随机数
    //============================================================
    wire [15:0] random_num;

    LFSR u_lfsr (
        .clk        (clk_100M),
        .rst_n      (sys_rst_n),
        .enable     (1'b1),
        .seed       (16'd0),
        .random_num (random_num)
    );
	//============================================================
    // AI司令部 1：散开(Scatter) / 追击(Chase) 全局定时器
    // 开局 7秒各回各角落 -> 20秒死命追击 -> 循环
    //============================================================
    reg [26:0] ai_timer_cnt;
    reg [7:0]  ai_seconds;
    reg        scatter_mode;

    always @(posedge clk_100M or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            ai_timer_cnt <= 0;
            ai_seconds   <= 0;
            scatter_mode <= 1'b1; // 开局先回角落
        end else if (game_state == `STATE_PLAYING && !sw_pause) begin
            if (ai_timer_cnt >= 27'd99_999_999) begin
                ai_timer_cnt <= 0;
                ai_seconds   <= ai_seconds + 1'b1;
                
                // 7秒散开，20秒追赶
                if (scatter_mode && ai_seconds >= 8'd7) begin
                    scatter_mode <= 1'b0;
                    ai_seconds   <= 0;
                end else if (!scatter_mode && ai_seconds >= 8'd20) begin
                    scatter_mode <= 1'b1;
                    ai_seconds   <= 0;
                end
            end else begin
                ai_timer_cnt <= ai_timer_cnt + 1'b1;
            end
        end
    end

    //============================================================
    // AI司令部 2：解算四只幽灵的目标坐标
    //============================================================
    // 四个角落坐标（你可以根据你实际的 MIF 尺寸微调，这是给困难难度的 19x21 准备的）
    wire [4:0] corner0_x = curr_width - 5'd2;  wire [4:0] corner0_y = 5'd1;                 // 红：右上
    wire [4:0] corner1_x = 5'd1;               wire [4:0] corner1_y = 5'd1;                 // 粉：左上
    wire [4:0] corner2_x = curr_width - 5'd2;  wire [4:0] corner2_y = curr_height - 5'd2;   // 青：右下
    wire [4:0] corner3_x = 5'd1;               wire [4:0] corner3_y = curr_height - 5'd2;   // 橙：左下

    // 【粉幽灵 Pinky】: 预判吃豆人前方 3 格截杀
    reg [4:0] pinky_chase_x, pinky_chase_y;
    always @(*) begin
        pinky_chase_x = pac_x; 
        pinky_chase_y = pac_y;
        if (pac_x > pac_prev_x && pac_x < curr_width - 5'd4)  pinky_chase_x = pac_x + 5'd3; // 往右走
        if (pac_x < pac_prev_x && pac_x > 5'd3)               pinky_chase_x = pac_x - 5'd3; // 往左走
        if (pac_y > pac_prev_y && pac_y < curr_height - 5'd4) pinky_chase_y = pac_y + 5'd3; // 往下走
        if (pac_y < pac_prev_y && pac_y > 5'd3)               pinky_chase_y = pac_y - 5'd3; // 往上走
    end

    // 【青幽灵 Inky】: 致命包夹 (以红幽灵为支点，取吃豆人的对称点)
    wire [5:0] inky_tx = (pac_x * 2 > ghost0_x) ? (pac_x * 2 - ghost0_x) : 6'd0;
    wire [5:0] inky_ty = (pac_y * 2 > ghost0_y) ? (pac_y * 2 - ghost0_y) : 6'd0;
    wire [4:0] inky_chase_x = (inky_tx >= curr_width)  ? curr_width - 5'd2  : inky_tx[4:0];
    wire [4:0] inky_chase_y = (inky_ty >= curr_height) ? curr_height - 5'd2 : inky_ty[4:0];

    // 【橙幽灵 Clyde】: 胆小鬼 (用曼哈顿距离判断，距离 < 8 逃跑回角落)
    wire [4:0] clyde_dx = (pac_x > ghost3_x) ? pac_x - ghost3_x : ghost3_x - pac_x;
    wire [4:0] clyde_dy = (pac_y > ghost3_y) ? pac_y - ghost3_y : ghost3_y - pac_y;
    wire [5:0] clyde_dist = clyde_dx + clyde_dy;
    wire [4:0] clyde_chase_x = (clyde_dist > 6'd8) ? pac_x : corner3_x;
    wire [4:0] clyde_chase_y = (clyde_dist > 6'd8) ? pac_y : corner3_y;

    // 最终输出：根据 Scatter/Chase 模式二选一
    wire [4:0] g0_target_x = scatter_mode ? corner0_x : pac_x;           // 红直接追
    wire [4:0] g0_target_y = scatter_mode ? corner0_y : pac_y;
    
    wire [4:0] g1_target_x = scatter_mode ? corner1_x : pinky_chase_x;   // 粉堵路
    wire [4:0] g1_target_y = scatter_mode ? corner1_y : pinky_chase_y;

    wire [4:0] g2_target_x = scatter_mode ? corner2_x : inky_chase_x;    // 青包抄
    wire [4:0] g2_target_y = scatter_mode ? corner2_y : inky_chase_y;

    wire [4:0] g3_target_x = scatter_mode ? corner3_x : clyde_chase_x;   // 橙游走
    wire [4:0] g3_target_y = scatter_mode ? corner3_y : clyde_chase_y;
    wire [15:0] random_ghost1 = random_num ^ 16'h00A5;
    wire [15:0] random_ghost2 = {random_num[7:0], random_num[15:8]} ^ 16'h3C3C;
    wire [15:0] random_ghost3 = {random_num[3:0], random_num[15:4]} ^ 16'h5A5A;

    //============================================================
    // 能量豆刷新脉冲
    //============================================================
    reg pill_eat_r;

    always @(posedge clk_100M or negedge sys_rst_n) begin
        if (!sys_rst_n)
            pill_eat_r <= 1'b0;
        else
            pill_eat_r <= pill_eat;
    end

    wire refresh_pulse = pill_eat && !pill_eat_r;

    //============================================================
    // 地图数据读取轮询
    //============================================================
    reg [2:0] rd_sel;

    always @(posedge clk_100M or negedge sys_rst_n) begin
        if (!sys_rst_n)
            rd_sel <= 3'd0;
        else
            rd_sel <= rd_sel + 3'd1;
    end

    //============================================================
    // 地图雷达 TDM 仲裁器 (修复总线抢占穿墙Bug)
    //============================================================
    reg [4:0] logic_addr_x;
    reg [4:0] logic_addr_y;
    reg       logic_en;
    reg       logic_wr_en_reg;

    // 1. 增加一个“吃豆请求”寄存器，捕获吃豆动作，等专属周期再执行
    reg eat_write_req;
    always @(posedge clk_100M or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            eat_write_req <= 1'b0;
        end else if (dot_eat | pill_eat) begin
            eat_write_req <= 1'b1;     // 捕获到吃豆动作
        end else if (rd_sel == 3'd5) begin
            eat_write_req <= 1'b0;     // 在第5个专属槽位执行完毕后释放
        end
    end

    // 2. 读写彻底分离的轮询状态机
    always @(*) begin
        // 默认值清零，防止锁存器
        logic_addr_x = 5'd0;
        logic_addr_y = 5'd0;
        logic_en     = 1'b0;
        logic_wr_en_reg = 1'b0;

        case (rd_sel)
            3'd0: begin logic_addr_x = pac_next_x;    logic_addr_y = pac_next_y;    logic_en = 1'b1; end
            3'd1: begin logic_addr_x = ghost0_next_x; logic_addr_y = ghost0_next_y; logic_en = 1'b1; end
            3'd2: begin logic_addr_x = ghost1_next_x; logic_addr_y = ghost1_next_y; logic_en = 1'b1; end
            3'd3: begin logic_addr_x = ghost2_next_x; logic_addr_y = ghost2_next_y; logic_en = 1'b1; end
            3'd4: begin logic_addr_x = ghost3_next_x; logic_addr_y = ghost3_next_y; logic_en = 1'b1; end
            // 🌟 专属写槽位：处理吃豆子消除，绝对不干扰前面的 0~4 号探路读取！
            3'd5: begin 
                logic_addr_x = pac_x; 
                logic_addr_y = pac_y; 
                logic_en = eat_write_req; 
                logic_wr_en_reg = eat_write_req; 
            end
            default: ;
        endcase
    end

    //============================================================
    // 迷宫地图 MAP
    //============================================================
    MAP u_map (
        .clk_100M      (clk_100M),
        .rst_n         (sys_rst_n),
        .difficulty    (difficulty_reg),

        .curr_width    (curr_width),
        .curr_height   (curr_height),

        .vga_rd_x      (vga_addr_x),
        .vga_rd_y      (vga_addr_y),
        .vga_rd_data   (vga_map_data),

        .logic_en      (logic_en),
        .logic_wr_en   (logic_wr_en_reg),
        .logic_addr_x  (logic_addr_x),
        .logic_addr_y  (logic_addr_y),
        .logic_rd_data (logic_rd_data),
			
			.map_reset     (score_reset_pulse),
			
        .refresh_pulse (refresh_pulse),
        .random_seed   (random_num),
        .refresh_done  (refresh_done),

        .pac_spawn_x   (pac_spawn_x),
        .pac_spawn_y   (pac_spawn_y),
        .ghost_spawn_x (ghost_spawn_x),
        .ghost_spawn_y (ghost_spawn_y)
    );

    //============================================================
    // MAP 读取返回数据延迟对齐
    //============================================================
    reg [2:0] rd_sel_d1;
    reg [2:0] rd_sel_d2;
    reg [2:0] rd_sel_d3;
    reg [2:0] rd_sel_d4;

    always @(posedge clk_100M or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            rd_sel_d1 <= 3'd0;
            rd_sel_d2 <= 3'd0;
            rd_sel_d3 <= 3'd0;
            rd_sel_d4 <= 3'd0;
        end else begin
            rd_sel_d1 <= rd_sel;
            rd_sel_d2 <= rd_sel_d1;
            rd_sel_d3 <= rd_sel_d2;
            rd_sel_d4 <= rd_sel_d3;
        end
    end

    reg [2:0] pac_map_data_reg;
    reg [2:0] gh0_map_data_reg;
    reg [2:0] gh1_map_data_reg;
    reg [2:0] gh2_map_data_reg;
    reg [2:0] gh3_map_data_reg;

    always @(posedge clk_100M or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            pac_map_data_reg <= 3'd0;
            gh0_map_data_reg <= 3'd0;
            gh1_map_data_reg <= 3'd0;
            gh2_map_data_reg <= 3'd0;
            gh3_map_data_reg <= 3'd0;
        end else begin
            if (rd_sel_d4 == 3'd0) pac_map_data_reg <= logic_rd_data;
            if (rd_sel_d4 == 3'd1) gh0_map_data_reg <= logic_rd_data;
            if (rd_sel_d4 == 3'd2) gh1_map_data_reg <= logic_rd_data;
            if (rd_sel_d4 == 3'd3) gh2_map_data_reg <= logic_rd_data;
            if (rd_sel_d4 == 3'd4) gh3_map_data_reg <= logic_rd_data;
        end
    end

    wire [2:0] pac_map_data = pac_map_data_reg;
    wire [2:0] gh0_map_data = gh0_map_data_reg;
    wire [2:0] gh1_map_data = gh1_map_data_reg;
    wire [2:0] gh2_map_data = gh2_map_data_reg;
    wire [2:0] gh3_map_data = gh3_map_data_reg;

    //============================================================
    // PacMan
    //============================================================
    PacMan u_pacman (
        .clk           (clk_100M),
        .rst_n         (sys_rst_n),
        .move_en       (game_update_en),
        .key_dir       (key_dir),
        .next_map_data (pac_map_data),

        .reset_pos     (reset_pac),
        .spawn_x       (pac_spawn_x),
        .spawn_y       (pac_spawn_y),

        .pac_x         (pac_x),
        .pac_y         (pac_y),
		  .pac_dir       (pac_dir),
        .next_x        (pac_next_x),
        .next_y        (pac_next_y),
        .move_req      (pac_move_req),
        .dot_eat       (dot_eat),
        .pill_eat      (pill_eat)
    );

    //============================================================
    // Ghost 0~3
    // [改动 2 开始] 将 .move_en 从 game_update_en 改为各自独立的 gX_tick
    //============================================================
    Ghost u_ghost0 (
        .clk           (clk_100M), .rst_n         (sys_rst_n),
        .move_en       (g0_tick), .ai_mode       (1'b1),
        .pac_x         (pac_x), .pac_y         (pac_y),
        .random_num    (random_num), .power_active  (power_active),
        .reset_pos     (reset_ghost0), .respawn_wait  (ghost0_respawn_wait),
        .next_map_data (gh0_map_data), .curr_width    (curr_width),
        .curr_height   (curr_height), .spawn_x       (ghost_spawn_x),
        .spawn_y       (ghost_spawn_y),
        .ghost_x       (ghost0_x), .ghost_y       (ghost0_y),
        .next_x        (ghost0_next_x), .next_y        (ghost0_next_y),
		  .target_x      (g0_target_x), // 🌟 接上目标线
        .target_y      (g0_target_y), // 🌟 接上目标线
        .move_req      (ghost0_move_req)
    );

    Ghost u_ghost1 (
        .clk           (clk_100M), .rst_n         (sys_rst_n),
        .move_en       (g1_tick & ghost1_active), .ai_mode       (1'b1),
        .pac_x         (pac_x), .pac_y         (pac_y),
        .random_num    (random_ghost1), .power_active  (power_active),
        .reset_pos     (reset_ghost1), .respawn_wait  (ghost1_respawn_wait),
        .next_map_data (gh1_map_data), .curr_width    (curr_width),
        .curr_height   (curr_height), .spawn_x       (ghost1_spawn_x),
        .spawn_y       (ghost1_spawn_y),
        .ghost_x       (ghost1_x), .ghost_y       (ghost1_y),
        .next_x        (ghost1_next_x), .next_y        (ghost1_next_y),
		  .target_x      (g1_target_x), // 🌟 接上目标线
        .target_y      (g1_target_y), // 🌟 接上目标线
        .move_req      (ghost1_move_req)
    );

    Ghost u_ghost2 (
        .clk           (clk_100M), .rst_n         (sys_rst_n),
        .move_en       (g2_tick & ghost2_active), .ai_mode       (1'b1),
        .pac_x         (pac_x), .pac_y         (pac_y),
        .random_num    (random_ghost2), .power_active  (power_active),
        .reset_pos     (reset_ghost2), .respawn_wait  (ghost2_respawn_wait),
        .next_map_data (gh2_map_data), .curr_width    (curr_width),
        .curr_height   (curr_height), .spawn_x       (ghost2_spawn_x),
        .spawn_y       (ghost2_spawn_y),
        .ghost_x       (ghost2_x), .ghost_y       (ghost2_y),
        .next_x        (ghost2_next_x), .next_y        (ghost2_next_y),
		  .target_x      (g2_target_x), // 🌟 接上目标线
        .target_y      (g2_target_y), // 🌟 接上目标线
        .move_req      (ghost2_move_req)
    );

    Ghost u_ghost3 (
        .clk           (clk_100M), .rst_n         (sys_rst_n),
        .move_en       (g3_tick & ghost3_active), .ai_mode       (1'b1),
        .pac_x         (pac_x), .pac_y         (pac_y),
        .random_num    (random_ghost3), .power_active  (power_active),
        .reset_pos     (reset_ghost3), .respawn_wait  (ghost3_respawn_wait),
        .next_map_data (gh3_map_data), .curr_width    (curr_width),
        .curr_height   (curr_height), .spawn_x       (ghost3_spawn_x),
        .spawn_y       (ghost3_spawn_y),
        .ghost_x       (ghost3_x), .ghost_y       (ghost3_y),
        .next_x        (ghost3_next_x), .next_y        (ghost3_next_y),
		  .target_x      (g3_target_x), // 🌟 接上目标线
        .target_y      (g3_target_y), // 🌟 接上目标线
        .move_req      (ghost3_move_req)
    );
    // [改动 2 结束]

    //============================================================
    // 碰撞检测组合逻辑
    //============================================================
    wire hit_ghost0_same = (pac_x == ghost0_x) && (pac_y == ghost0_y);
    wire hit_ghost1_same = (pac_x == ghost1_x) && (pac_y == ghost1_y);
    wire hit_ghost2_same = (pac_x == ghost2_x) && (pac_y == ghost2_y);
    wire hit_ghost3_same = (pac_x == ghost3_x) && (pac_y == ghost3_y);

    wire hit_ghost0_swap = (pac_prev_x == ghost0_x) && (pac_prev_y == ghost0_y) &&
                           (ghost0_prev_x == pac_x) && (ghost0_prev_y == pac_y);
    wire hit_ghost1_swap = (pac_prev_x == ghost1_x) && (pac_prev_y == ghost1_y) &&
                           (ghost1_prev_x == pac_x) && (ghost1_prev_y == pac_y);
    wire hit_ghost2_swap = (pac_prev_x == ghost2_x) && (pac_prev_y == ghost2_y) &&
                           (ghost2_prev_x == pac_x) && (ghost2_prev_y == pac_y);
    wire hit_ghost3_swap = (pac_prev_x == ghost3_x) && (pac_prev_y == ghost3_y) &&
                           (ghost3_prev_x == pac_x) && (ghost3_prev_y == pac_y);

    wire hit_ghost0 = ghost0_active && (hit_ghost0_same || hit_ghost0_swap);
    wire hit_ghost1 = ghost1_active && (hit_ghost1_same || hit_ghost1_swap);
    wire hit_ghost2 = ghost2_active && (hit_ghost2_same || hit_ghost2_swap);
    wire hit_ghost3 = ghost3_active && (hit_ghost3_same || hit_ghost3_swap);

    wire hit_any_ghost = hit_ghost0 || hit_ghost1 || hit_ghost2 || hit_ghost3;

    //============================================================
    // 碰撞检测与事件生成
    //============================================================
    always @(posedge clk_100M or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            pac_death   <= 1'b0;
            ghost_eat   <= 1'b0;
            reset_pac    <= 1'b0;
            reset_ghost0 <= 1'b0;
            reset_ghost1 <= 1'b0;
            reset_ghost2 <= 1'b0;
            reset_ghost3 <= 1'b0;
            ghost0_respawn_wait <= 1'b0;
            ghost1_respawn_wait <= 1'b0;
            ghost2_respawn_wait <= 1'b0;
            ghost3_respawn_wait <= 1'b0;
            pac_prev_x <= 5'd0;
            pac_prev_y <= 5'd0;
            ghost0_prev_x <= 5'd0; ghost0_prev_y <= 5'd0;
            ghost1_prev_x <= 5'd0; ghost1_prev_y <= 5'd0;
            ghost2_prev_x <= 5'd0; ghost2_prev_y <= 5'd0;
            ghost3_prev_x <= 5'd0; ghost3_prev_y <= 5'd0;
            collision_check_pending <= 1'b0;
        end else begin
            pac_death   <= 1'b0;
            ghost_eat   <= 1'b0;
            reset_pac    <= 1'b0;
            reset_ghost0 <= 1'b0;
            reset_ghost1 <= 1'b0;
            reset_ghost2 <= 1'b0;
            reset_ghost3 <= 1'b0;
            ghost0_respawn_wait <= 1'b0;
            ghost1_respawn_wait <= 1'b0;
            ghost2_respawn_wait <= 1'b0;
            ghost3_respawn_wait <= 1'b0;

            if (reset_positions) begin
                reset_pac    <= 1'b1;
                reset_ghost0 <= 1'b1;
                reset_ghost1 <= 1'b1;
                reset_ghost2 <= 1'b1;
                reset_ghost3 <= 1'b1;
                collision_check_pending <= 1'b0;
                pac_prev_x <= pac_spawn_x; pac_prev_y <= pac_spawn_y;
                ghost0_prev_x <= ghost_spawn_x; ghost0_prev_y <= ghost_spawn_y;
                ghost1_prev_x <= ghost_spawn_x; ghost1_prev_y <= ghost_spawn_y;
                ghost2_prev_x <= ghost_spawn_x; ghost2_prev_y <= ghost_spawn_y;
                ghost3_prev_x <= ghost_spawn_x; ghost3_prev_y <= ghost_spawn_y;
            end else if (game_update_en) begin
                pac_prev_x <= pac_x; pac_prev_y <= pac_y;
                ghost0_prev_x <= ghost0_x; ghost0_prev_y <= ghost0_y;
                ghost1_prev_x <= ghost1_x; ghost1_prev_y <= ghost1_y;
                ghost2_prev_x <= ghost2_x; ghost2_prev_y <= ghost2_y;
                ghost3_prev_x <= ghost3_x; ghost3_prev_y <= ghost3_y;
                collision_check_pending <= 1'b1;
            end else if (collision_check_pending) begin
                collision_check_pending <= 1'b0;
                if (hit_any_ghost) begin
                    if (power_active) begin
                        ghost_eat <= 1'b1;
                        if (hit_ghost0) begin reset_ghost0 <= 1'b1; ghost0_respawn_wait <= 1'b1; end
                        if (hit_ghost1) begin reset_ghost1 <= 1'b1; ghost1_respawn_wait <= 1'b1; end
                        if (hit_ghost2) begin reset_ghost2 <= 1'b1; ghost2_respawn_wait <= 1'b1; end
                        if (hit_ghost3) begin reset_ghost3 <= 1'b1; ghost3_respawn_wait <= 1'b1; end
                    end else begin
                        pac_death <= 1'b1;
                        reset_pac <= 1'b1;
                    end
                end
            end
        end
    end

    //============================================================
    // 分数与状态管理
    //============================================================
    ScoreManager u_score (
        .clk               (clk_100M),
        .rst_n             (sys_rst_n),
        .difficulty        (difficulty_reg),
        .start_pulse       (start_pulse),
        .dot_eat           (dot_eat),
        .pill_eat          (pill_eat),
        .ghost_eat         (ghost_eat),
        .pac_death         (pac_death),
        .power_active      (power_active),
        .power_counter     (power_counter),
        .game_win          (game_win),
        .game_over         (game_over),
        .game_state        (game_state),
        .score             (score),
        .lives             (lives),
        .reset_positions   (reset_positions),
        .score_reset_pulse (score_reset_pulse),
        .score_bcd         (score_bcd)
    );

    //============================================================
    // VGA 渲染
    //============================================================
    wire pill_blink = power_active;

    VGA_Renderer u_vga (
        .clk_100M      (clk_100M),
        .rst_n         (sys_rst_n),
        .difficulty    (difficulty_reg),

        .vga_addr_x    (vga_addr_x),
        .vga_addr_y    (vga_addr_y),
        .vga_map_data  (vga_map_data),

        .pac_x         (pac_x), .pac_y         (pac_y),
		  .pac_dir       (pac_dir),
        .ghost0_x      (ghost0_draw_x), .ghost0_y      (ghost0_draw_y),
        .ghost1_x      (ghost1_draw_x), .ghost1_y      (ghost1_draw_y),
        .ghost2_x      (ghost2_draw_x), .ghost2_y      (ghost2_draw_y),
        .ghost3_x      (ghost3_draw_x), .ghost3_y      (ghost3_draw_y),

        .power_active  (power_active),
		  .power_counter (power_counter),
        .pill_blink    (pill_blink),
        .game_state    (game_state),

        .menu_sel      (menu_sel),
        .score_bcd     (score_bcd),

        .vga_clk_out   (),
        .vga_hs        (vga_hs),
        .vga_vs        (vga_vs),
        .vga_blank_n   (vga_blank_n),
        .vga_sync_n    (vga_sync_n),
        .vga_r         (vga_r),
        .vga_g         (vga_g),
        .vga_b         (vga_b)
    );

    //============================================================
    // 七段数码管显示
    //============================================================
    SevenSegDisplay u_seg (
        .clk       (clk_100M),
        .rst_n     (sys_rst_n),
        .score_bcd (score_bcd),
        .lives     (lives),
        .HEX0      (HEX0), .HEX1      (HEX1),
        .HEX2      (HEX2), .HEX3      (HEX3),
        .HEX4      (HEX4), .HEX5      (HEX5),
        .HEX6      (HEX6), .HEX7      (HEX7)
    );

    
    //============================================================
    // 音效/BGM 触发信号跨时钟域展宽（100MHz -> 50MHz）
    // 100MHz 单周期脉冲只有 10ns，50MHz 采样 + 48kHz sample_tick 必然漏检
    // 展宽到 50ms，确保 50MHz 域和 sample_tick 一定能稳定采样
    //============================================================
    reg [23:0] dot_eat_stretch,  pill_eat_stretch;
    reg [23:0] ghost_eat_stretch, death_stretch;
    reg [23:0] start_pulse_stretch;

    always @(posedge clk_100M or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            dot_eat_stretch     <= 24'd0;
            pill_eat_stretch    <= 24'd0;
            ghost_eat_stretch   <= 24'd0;
            death_stretch       <= 24'd0;
            start_pulse_stretch <= 24'd0;
        end else begin
            if (dot_eat)       dot_eat_stretch     <= 24'd5_000_000; // 50ms @ 100MHz
            else if (dot_eat_stretch     > 0) dot_eat_stretch     <= dot_eat_stretch     - 1'b1;

            if (pill_eat)      pill_eat_stretch    <= 24'd5_000_000;
            else if (pill_eat_stretch    > 0) pill_eat_stretch    <= pill_eat_stretch    - 1'b1;

            if (ghost_eat)     ghost_eat_stretch   <= 24'd5_000_000;
            else if (ghost_eat_stretch   > 0) ghost_eat_stretch   <= ghost_eat_stretch   - 1'b1;

            if (pac_death)     death_stretch       <= 24'd5_000_000;
            else if (death_stretch       > 0) death_stretch       <= death_stretch       - 1'b1;

            if (start_pulse)   start_pulse_stretch <= 24'd5_000_000;
            else if (start_pulse_stretch > 0) start_pulse_stretch <= start_pulse_stretch - 1'b1;
        end
    end

    wire dot_eat_sfx    = (dot_eat_stretch     != 0);
    wire pill_eat_sfx   = (pill_eat_stretch    != 0);
    wire ghost_eat_sfx  = (ghost_eat_stretch   != 0);
    wire death_sfx      = (death_stretch       != 0);
    wire play_start_sfx = (start_pulse_stretch != 0);

    //============================================================
    // 音乐模块（BGM + 实时音效）
    //============================================================
    Music_Player u_music (
        .clk_50M     (clk_50M),
        .rst_n       (sys_rst_n),
        .play_start  (play_start_sfx),
        .dot_eat     (dot_eat_sfx),
        .pill_eat    (pill_eat_sfx),
        .ghost_eat   (ghost_eat_sfx),
        .pac_death   (death_sfx),
        .AUD_XCK     (AUD_XCK),
        .AUD_BCLK    (AUD_BCLK),
        .AUD_DACLRCK (AUD_DACLRCK),
        .AUD_DACDAT  (AUD_DACDAT),
        .I2C_SCLK    (I2C_SCLK),
        .I2C_SDAT    (I2C_SDAT)
    );

endmodule