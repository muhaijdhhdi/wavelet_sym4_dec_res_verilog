`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: pulse_counter_diff_trigger
// Description: 脉冲计数模块（diff_trigger版本）
//              基于"跨越阈值"事件的脉冲计数，支持堆积检测
//
// 设计原理：
//   接收 event_analysis 产生的每周期脉冲数和堆积数
//   在窗口周期内累加，窗口结束时输出总数
//   无需死区时间（跨越阈值是瞬时点事件，不会重复触发）
//
// 双阈值计数（方案A）：
//   - pulse_count：总脉冲数 = Σ(popcount1 + popcount2)
//   - pileup_count：总堆积数 = Σ(popcount2)
//
// 输出行为：
//   pulse_count/pileup_count 在窗口期间保持上一个窗口的值
//   窗口结束时才更新为当前窗口的计数结果
//
// 接口兼容：
//   与原 pulse_counter.v 接口基本兼容，新增 pileup_count 输出
//   移除了 dead_time（不需要）、abs_threshold（不需要）
//
// 流水线延迟：1个时钟周期（累加逻辑）
//////////////////////////////////////////////////////////////////////////////////

module pulse_counter_diff_trigger #(
    parameter COUNTER_WIDTH = 16          // 支持最大65535个脉冲
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          valid_in,
    input  wire [4:0]                    pulse_this_cycle,   // 本周期脉冲数（来自 event_analysis）
    input  wire [4:0]                    pileup_this_cycle,  // 本周期堆积数（来自 event_analysis）
    input  wire [15:0]                   window_cycles,      // 窗口长度（周期数），以12.8ns为单位
    input  wire                          count_enable,       // 计数使能（高电平时窗口自动周期运行）
    
    output reg  [COUNTER_WIDTH-1:0]      pulse_count,        // 脉冲总数（窗口结束时更新，期间保持）
    output reg  [COUNTER_WIDTH-1:0]      pileup_count,       // 堆积总数（窗口结束时更新，期间保持）
    output reg                           count_valid,        // 计数有效（窗口结束时拉高一拍）
    output reg                           window_active,      // 窗口激活状态
    
    // 调试输出
    output wire [4:0]                    dbg_pulse_this_cycle,
    output wire [4:0]                    dbg_pileup_this_cycle
);

    //==========================================================================
    // 输入寄存
    //==========================================================================
    reg [4:0] pulse_in_reg;
    reg [4:0] pileup_in_reg;
    reg valid_in_reg;
    reg count_enable_reg;
    reg count_enable_d;
    
    always @(posedge clk) begin
        pulse_in_reg <= pulse_this_cycle;
        pileup_in_reg <= pileup_this_cycle;
        valid_in_reg <= valid_in;
        count_enable_reg <= count_enable;
        count_enable_d <= count_enable_reg;
    end
    
    wire count_enable_rising = count_enable_reg && !count_enable_d;
    
    //==========================================================================
    // 调试信号输出
    //==========================================================================
    assign dbg_pulse_this_cycle = pulse_in_reg;
    assign dbg_pileup_this_cycle = pileup_in_reg;

    //==========================================================================
    // 窗口计数逻辑
    // pulse_count/pileup_count 在窗口期间保持上一个窗口的值，窗口结束时才更新
    //==========================================================================
    reg [15:0] window_cnt;
    reg [COUNTER_WIDTH-1:0] pulse_acc;    // 当前窗口的脉冲累加器
    reg [COUNTER_WIDTH-1:0] pileup_acc;   // 当前窗口的堆积累加器
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            window_cnt <= 0;
            window_active <= 0;
            pulse_count <= 0;
            pileup_count <= 0;
            pulse_acc <= 0;
            pileup_acc <= 0;
            count_valid <= 0;
        end
        else begin
            count_valid <= 0;  // 默认
            
            if (!count_enable_reg) begin
                // 使能关闭：停止计数，重置状态
                window_active <= 0;
                window_cnt <= 0;
                pulse_acc <= 0;
                pileup_acc <= 0;
            end
            else if (count_enable_rising) begin
                // 首次启动：开始第一个窗口
                window_active <= 1;
                window_cnt <= 0;
                pulse_acc <= valid_in_reg ? pulse_in_reg : 0;
                pileup_acc <= valid_in_reg ? pileup_in_reg : 0;
                // pulse_count/pileup_count 保持为0（或上一次的值）
            end
            else if (window_active && window_cnt >= window_cycles - 1) begin
                // 窗口结束：输出结果并开始新窗口
                count_valid <= 1;
                
                // 更新输出（包含最后一周期）
                if (valid_in_reg) begin
                    pulse_count <= pulse_acc + pulse_in_reg;
                    pileup_count <= pileup_acc + pileup_in_reg;
                end
                else begin
                    pulse_count <= pulse_acc;
                    pileup_count <= pileup_acc;
                end
                
                // 立即开始新窗口
                window_cnt <= 0;
                pulse_acc <= 0;
                pileup_acc <= 0;
            end
            else if (window_active) begin
                // 窗口内：累加
                if (valid_in_reg) begin
                    pulse_acc <= pulse_acc + pulse_in_reg;
                    pileup_acc <= pileup_acc + pileup_in_reg;
                end
                window_cnt <= window_cnt + 1;
                // pulse_count/pileup_count 保持不变（显示上一个窗口的结果）
            end
        end
    end

endmodule
