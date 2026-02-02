`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: pulse_counter_diff_trigger_top
// Description: 脉冲计数模块顶层封装（diff_trigger版本）
//              基于"跨越阈值"事件的脉冲计数，支持堆积检测
//
// 设计原理（与v3本质区别）：
//   不使用"过零点配对"，而是检测"差分值跨越阈值"这个瞬时动作
//   跨越阈值是一个点事件，只能落在某一个采样点，无需跨周期处理
//   逻辑大幅简化，时序更优
//
// 特性：
//   1. 亚周期精度检测（0.8ns分辨率）
//   2. 双阈值设计：主阈值 + 堆积阈值
//   3. 无需跨周期配对处理
//   4. 无需死区时间
//   5. 全流水线设计，时序友好
//   6. 支持堆积检测和统计
//
// 子模块：
//   - event_mask_gen：双阈值事件掩码生成（3周期）
//   - event_analysis：事件统计（5周期）
//   - pulse_counter_diff_trigger：窗口累加计数（1周期）
//
// 输入：
//   - diff_in：差分数据（来自delay_diff_intra）
//   - threshold1：主阈值（跨越产生脉冲计数）
//   - threshold2：堆积阈值（跨越产生额外脉冲+堆积计数）
//
// 输出：
//   - pulse_count：窗口内脉冲总数
//   - pileup_count：窗口内堆积总数
//   - pulse_rate：每周期脉冲数（实时）
//   - pileup_rate：每周期堆积数（实时）
//
// 流水线延迟：9个时钟周期
//   event_mask_gen: 3 + event_analysis: 5 + pulse_counter: 1
//////////////////////////////////////////////////////////////////////////////////

module pulse_counter_diff_trigger_top #(
    parameter NUM_CHANNELS = 16,
    parameter DATA_WIDTH = 20,            // Q16.4格式
    parameter COUNTER_WIDTH = 24          // 支持更大计数范围
)(
    input  wire                                  clk,
    input  wire                                  rst_n,
    input  wire                                  valid_in,
    input  wire [NUM_CHANNELS*DATA_WIDTH-1:0]   diff_in,          // 320位差分数据
    input  wire signed [DATA_WIDTH-1:0]         threshold1,       // 主阈值
    input  wire signed [DATA_WIDTH-1:0]         threshold2,       // 堆积阈值（> threshold1）
    input  wire [23:0]                          window_cycles,    // 窗口长度（周期数）
    input  wire                                 count_enable,     // 计数使能
    
    output wire [COUNTER_WIDTH-1:0]             pulse_count,      // 脉冲总数（窗口结束时更新）
    output wire [COUNTER_WIDTH-1:0]             pileup_count,     // 堆积总数（窗口结束时更新）
    output wire                                 count_valid,      // 计数有效（窗口结束时拉高一拍）
    output wire                                 window_active,    // 窗口激活状态
    output reg  [4:0]                           pulse_rate,       // 每周期脉冲数（实时）
    output reg  [4:0]                           pileup_rate,      // 每周期堆积数（实时）
    
    // 调试输出
    output wire [NUM_CHANNELS-1:0]              dbg_event_mask1,
    output wire [NUM_CHANNELS-1:0]              dbg_event_mask2,
    output wire [4:0]                           dbg_pulse_this_cycle,
    output wire [4:0]                           dbg_pileup_this_cycle
);

    //==========================================================================
    // 事件掩码生成（双阈值）
    //==========================================================================
    wire [NUM_CHANNELS-1:0] event_mask1;
    wire [NUM_CHANNELS-1:0] event_mask2;
    wire mask_valid;
    
    event_mask_gen #(
        .NUM_CHANNELS(NUM_CHANNELS),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_event_mask_gen (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(valid_in),
        .diff_in(diff_in),
        .threshold1(threshold1),
        .threshold2(threshold2),
        
        .event_mask1(event_mask1),
        .event_mask2(event_mask2),
        .valid_out(mask_valid)
    );
    
    assign dbg_event_mask1 = event_mask1;
    assign dbg_event_mask2 = event_mask2;

    //==========================================================================
    // 事件分析（popcount统计）
    //==========================================================================
    wire [4:0] pulse_this_cycle;
    wire [4:0] pileup_this_cycle;
    wire analysis_valid;
    
    event_analysis #(
        .NUM_CHANNELS(NUM_CHANNELS)
    ) u_event_analysis (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(mask_valid),
        .event_mask1(event_mask1),
        .event_mask2(event_mask2),
        
        .pulse_this_cycle(pulse_this_cycle),
        .pileup_this_cycle(pileup_this_cycle),
        .valid_out(analysis_valid)
    );
    
    assign dbg_pulse_this_cycle = pulse_this_cycle;
    assign dbg_pileup_this_cycle = pileup_this_cycle;

    //==========================================================================
    // 实时脉冲率/堆积率输出
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pulse_rate <= 0;
            pileup_rate <= 0;
        end
        else if (analysis_valid) begin
            pulse_rate <= pulse_this_cycle;
            pileup_rate <= pileup_this_cycle;
        end
    end

    //==========================================================================
    // 窗口累加计数
    //==========================================================================
    wire [15:0] pulse_count_internal;
    wire [15:0] pileup_count_internal;
    
    pulse_counter_diff_trigger #(
        .COUNTER_WIDTH(16)
    ) u_pulse_counter (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(analysis_valid),
        .pulse_this_cycle(pulse_this_cycle),
        .pileup_this_cycle(pileup_this_cycle),
        .window_cycles(window_cycles[15:0]),
        .count_enable(count_enable),
        
        .pulse_count(pulse_count_internal),
        .pileup_count(pileup_count_internal),
        .count_valid(count_valid),
        .window_active(window_active),
        
        .dbg_pulse_this_cycle(),
        .dbg_pileup_this_cycle()
    );
    
    // 扩展到COUNTER_WIDTH位
    assign pulse_count = {{(COUNTER_WIDTH-16){1'b0}}, pulse_count_internal};
    assign pileup_count = {{(COUNTER_WIDTH-16){1'b0}}, pileup_count_internal};

endmodule
