`timescale 1ns / 1ps
`include "game_defines.v"

module Ghost (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        move_en,
    input  wire        ai_mode,
    input  wire [4:0]  pac_x,
    input  wire [4:0]  pac_y,
    input  wire [4:0]  target_x,  // AI 战术目标 X
    input  wire [4:0]  target_y,  // AI 战术目标 Y
    input  wire [15:0] random_num,
    input  wire        power_active,
    input  wire        reset_pos,
    input  wire        respawn_wait,
    input  wire [2:0]  next_map_data,
    input  wire [4:0]  curr_width,
    input  wire [4:0]  curr_height,
    input  wire [4:0]  spawn_x,
    input  wire [4:0]  spawn_y,
    output reg  [4:0]  ghost_x,
    output reg  [4:0]  ghost_y,
    output reg  [4:0]  next_x,
    output reg  [4:0]  next_y,
    output reg         move_req
);

    localparam DIR_UP    = 2'd0;
    localparam DIR_DOWN  = 2'd1;
    localparam DIR_LEFT  = 2'd2;
    localparam DIR_RIGHT = 2'd3;

    localparam [4:0] HIDE_POS = 5'd31;
    localparam [4:0] RESPAWN_TICKS = 5'd12;

    reg [1:0] dir_reg;
    reg [1:0] random_dir;
    reg       dead_mode;
    reg [4:0] respawn_cnt;
    
    // 🌟 新增：高级 AI 防抖与状态寄存器
    reg [3:0] step_cnt;       // 记录直行的步数
    reg       hit_wall_flag;  // 记录是否连续撞墙（用于死胡同逃脱）

    //==================================================
    // 智能寻路：撞墙时的“最佳垂直转向”决策引擎
    //==================================================
    wire target_is_up    = (ghost_y > target_y);
    wire target_is_down  = (ghost_y < target_y);
    wire target_is_left  = (ghost_x > target_x);
    wire target_is_right = (ghost_x < target_x);

    reg [1:0] best_turn_dir;
    always @(*) begin
        if (power_active) begin
            // 逃跑模式：被药丸吓到，撞墙后盲目乱窜
            case (dir_reg)
                DIR_UP, DIR_DOWN:    best_turn_dir = random_num[0] ? DIR_LEFT : DIR_RIGHT;
                DIR_LEFT, DIR_RIGHT: best_turn_dir = random_num[0] ? DIR_UP : DIR_DOWN;
            endcase
        end else begin
            // 猎杀模式：撞墙后，在两个垂直方向中选最能靠近目标的那个
            case (dir_reg)
                DIR_LEFT, DIR_RIGHT: begin // X轴走不通了，看Y轴
                    if (target_is_up)        best_turn_dir = DIR_UP;
                    else if (target_is_down) best_turn_dir = DIR_DOWN;
                    else                     best_turn_dir = random_num[0] ? DIR_UP : DIR_DOWN;
                end
                DIR_UP, DIR_DOWN: begin    // Y轴走不通了，看X轴
                    if (target_is_left)      best_turn_dir = DIR_LEFT;
                    else if (target_is_right)best_turn_dir = DIR_RIGHT;
                    else                     best_turn_dir = random_num[0] ? DIR_LEFT : DIR_RIGHT;
                end
            endcase
        end
    end

    //==================================================
    // 坐标推演逻辑
    //==================================================
    always @(*) begin
        if (dead_mode) begin
            next_x = HIDE_POS; next_y = HIDE_POS;
        end else begin
            next_x = ghost_x;  next_y = ghost_y;
            case (dir_reg)
                DIR_UP:    begin next_y = (ghost_y > 5'd0) ? (ghost_y - 5'd1) : ghost_y; end
                DIR_DOWN:  begin next_y = (ghost_y < curr_height - 5'd1) ? (ghost_y + 5'd1) : ghost_y; end
                DIR_LEFT:  begin next_x = (ghost_x > 5'd0) ? (ghost_x - 5'd1) : ghost_x; end
                DIR_RIGHT: begin next_x = (ghost_x < curr_width - 5'd1) ? (ghost_x + 5'd1) : ghost_x; end
                default:   begin next_x = ghost_x; next_y = ghost_y; end
            endcase
        end
    end

    //==================================================
    // 核心移动与大脑判断
    //==================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ghost_x <= spawn_x; ghost_y <= spawn_y; move_req <= 1'b0; dead_mode <= 1'b0;
            respawn_cnt <= 5'd0; random_dir <= DIR_LEFT; dir_reg <= DIR_UP;
            step_cnt <= 4'd0; hit_wall_flag <= 1'b0;
        end else begin
            move_req <= 1'b0;
            
            // --- 重置与死亡逻辑（保持原样） ---
            if (reset_pos) begin
                if (respawn_wait) begin
                    dead_mode <= 1'b1; respawn_cnt <= RESPAWN_TICKS; ghost_x <= HIDE_POS; ghost_y <= HIDE_POS;
                end else begin
                    dead_mode <= 1'b0; respawn_cnt <= 5'd0; ghost_x <= spawn_x; ghost_y <= spawn_y;
                end
                random_dir <= random_num[1:0]; dir_reg <= random_num[1:0]; step_cnt <= 0; hit_wall_flag <= 0;
            end
            else if (dead_mode) begin
                ghost_x <= HIDE_POS; ghost_y <= HIDE_POS; move_req <= 1'b0;
                if (move_en) begin
                    if (respawn_cnt <= 5'd1) begin
                        dead_mode <= 1'b0; respawn_cnt <= 5'd0; ghost_x <= spawn_x; ghost_y <= spawn_y;
                        random_dir <= random_num[1:0]; dir_reg <= random_num[1:0]; step_cnt <= 0; hit_wall_flag <= 0;
                    end else begin
                        respawn_cnt <= respawn_cnt - 5'd1;
                    end
                end
            end
            
            // --- 🌟 真正的猎杀者 AI 逻辑 ---
            else if (move_en) begin
                
                // 【情况A：前方畅通无阻】
                if (next_map_data != `MAP_WALL && next_x < curr_width && next_y < curr_height) begin
                    ghost_x  <= next_x;
                    ghost_y  <= next_y;
                    move_req <= 1'b1;
                    hit_wall_flag <= 1'b0; // 成功往前走，洗清撞墙嫌疑
                    
                    if (ai_mode) begin
                        // 路口偷瞄机制：走一段长路后，有小概率尝试往目标方向抄近道 (让它看起来像在主动找你)
                        if (step_cnt > 4'd5 && random_num[3:2] == 2'd0) begin
                            if ((dir_reg == DIR_LEFT || dir_reg == DIR_RIGHT) && (target_is_up || target_is_down)) begin
                                 dir_reg  <= target_is_up ? DIR_UP : DIR_DOWN;
                                 step_cnt <= 0;
                            end
                            else if ((dir_reg == DIR_UP || dir_reg == DIR_DOWN) && (target_is_left || target_is_right)) begin
                                 dir_reg  <= target_is_left ? DIR_LEFT : DIR_RIGHT;
                                 step_cnt <= 0;
                            end
                        end else begin
                            if (step_cnt < 4'd15) step_cnt <= step_cnt + 1'b1;
                        end
                    end
                end 
                
                // 【情况B：撞到南墙了！】
                else begin
                    step_cnt <= 0;
                    if (!ai_mode) begin
                        dir_reg <= random_num[3:2] ^ random_num[1:0]; // 瞎逛模式
                    end else begin
                        if (hit_wall_flag) begin
                            // 绝技：死角逃生！连续撞墙说明拐错进了死胡同，直接利用位运算 180度调头！
                            dir_reg <= dir_reg ^ 2'b01; 
                            hit_wall_flag <= 1'b0;
                        end else begin
                            // 正常拐弯：顺着墙壁寻找离玩家最近的方向
                            dir_reg <= best_turn_dir;
                            hit_wall_flag <= 1'b1; // 标记刚撞过墙
                        end
                    end
                end
            end
        end
    end
endmodule