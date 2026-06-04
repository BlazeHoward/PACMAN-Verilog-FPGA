# ============================================================================
# PACMAN3.sdc - 针对 Cyclone IV E + 50MHz 输入 + PLL 100MHz/25MHz 游戏时钟
# ============================================================================

# --------------------------------------------------
# 1. 基时钟约束 (50MHz 晶振输入)
# --------------------------------------------------
create_clock -name clk_50M -period 20.000 \
    -waveform {0.000 10.000} \
    [get_ports clk_50M]

# --------------------------------------------------
# 2. 自动派生 PLL 输出时钟 (clk0=100MHz, clk1=25MHz)
# --------------------------------------------------
derive_pll_clocks -create_base_clocks

# --------------------------------------------------
# 3. 时钟不确定性 (自动计算 jitter + skew)
# --------------------------------------------------
derive_clock_uncertainty

# --------------------------------------------------
# 4. 输入延迟约束 (排除时钟和复位)
# --------------------------------------------------
set_input_delay -clock clk_50M -max 3.0 \
    [remove_from_collection [all_inputs] [get_ports {clk_50M rst_n sw_pause key_up key_down key_left key_right}]]
set_input_delay -clock clk_50M -min 1.0 \
    [remove_from_collection [all_inputs] [get_ports {clk_50M rst_n sw_pause key_up key_down key_left key_right}]]

# 按键和开关单独约束 (机械按键抖动大，放宽要求)
set_input_delay -clock clk_50M -max 5.0 \
    [get_ports {sw_pause key_up key_down key_left key_right}]
set_input_delay -clock clk_50M -min 0.0 \
    [get_ports {sw_pause key_up key_down key_left key_right}]

# --------------------------------------------------
# 5. 输出延迟约束 (VGA 信号)
# --------------------------------------------------
set_output_delay -clock clk_50M -max 2.0 [all_outputs]
set_output_delay -clock clk_50M -min -0.5 [all_outputs]

# VGA 时钟输出特殊处理 (PLL clk1 25MHz 直接驱动)
set_output_delay -clock [get_clocks {u_pll|u_pll_ip|altpll_component|auto_generated|pll1|clk[1]}] \
    -max 2.0 [get_ports vga_clk_out]

# --------------------------------------------------
# 6. 伪路径约束
# --------------------------------------------------
# 异步复位到所有寄存器不设时序要求
set_false_path -from [get_ports rst_n] -to [all_registers]

# 复位到组合输出也不检查
set_false_path -from [get_ports rst_n] -to [all_outputs]

# --------------------------------------------------
# 7. 多周期路径 (游戏逻辑每 4 拍更新一次，对应 25MHz)
# --------------------------------------------------
# 如果游戏主状态机明确用 clk0 (100MHz) 但每 N 拍更新，可设多周期
# 先注释掉，确认你的游戏时钟用法后再开
# set_multicycle_path -setup 4 -hold 3 \
#     -from [get_registers {*game_state*}] \
#     -to [get_registers {*game_state*}]

# --------------------------------------------------
# 8. 禁止 Quartus 把 rst_n 当时钟 (关键！)
# --------------------------------------------------
set_clock_groups -exclusive -group [get_clocks clk_50M] \
    -group [get_clocks {*rst_n*}]

# 或者更直接：删除 Quartus 自动推导的 rst_n 时钟
# 这个在 derive_clocks 之后执行
remove_clock [get_clocks rst_n]