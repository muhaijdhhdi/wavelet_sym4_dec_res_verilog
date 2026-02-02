`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: pulse_counter_ultra
// Description: 高性能脉冲计数模块（支持脉冲堆积检测）
//
// 特性：
//   1. 亚周期精度过零检测（0.8ns分辨率）
//   2. 并行配对逻辑，支持一个周期内检测多个脉冲（堆积场景）
//   3. 三重验证：差分值正负、差分幅度、绝对幅度
//   4. 无死时间，通过阈值机制剔除毛刺
//   5. 流水线设计，时序友好
//
// 子模块：
//   - zeropoints_mask：过零点掩码生成
//   - zeropoints_analysis：零点分析器（包含ones_mate配对逻辑）
//
// 输入：
//   - diff_in：差分数据（来自delay_diff_intra）
//   - data_before_diff：差分前数据（绝对电平）
//   - diff_threshold：差分阈值
//   - abs_threshold：绝对阈值
//
// 输出：
//   - pulse_count：窗口内脉冲总数
//   - pulse_rate：每周期脉冲数（0~16）
//
// 流水线延迟：约11个时钟周期（zeropoints_mask:3 + ones_mate:4 + verify:3 + output:1）
//////////////////////////////////////////////////////////////////////////////////

module pulse_counter_ultra #(
    parameter NUM_CHANNELS = 16,
    parameter DATA_WIDTH = 20,            // Q16.4格式
    parameter COUNTER_WIDTH = 24,         // 支持更大计数范围
    parameter MAX_PAIRS = 8
)(
    input  wire                                  clk,
    input  wire                                  rst_n,
    input  wire                                  valid_in,
    input  wire [NUM_CHANNELS*DATA_WIDTH-1:0]   diff_in,          // 320位差分数据
    input  wire [NUM_CHANNELS*DATA_WIDTH-1:0]   data_before_diff, // 320位差分前数据
    input  wire signed [DATA_WIDTH-1:0]         diff_threshold,   // 差分阈值
    input  wire signed [DATA_WIDTH-1:0]         abs_threshold,    // 绝对阈值
    input  wire [23:0]                          window_cycles,    // 窗口长度（周期数）
    input  wire                                 count_enable,     // 计数使能
    
    output reg  [COUNTER_WIDTH-1:0]             pulse_count,      // 脉冲总数（窗口结束时更新）
    output reg                                  count_valid,      // 计数有效（窗口结束时拉高一拍）
    output reg                                  window_active,    // 窗口激活状态
    output reg  [4:0]                           pulse_rate,       // 每周期脉冲数（实时）
    
    // 调试输出
    output wire [NUM_CHANNELS-1:0]              dbg_zero_mask,
    output wire [MAX_PAIRS-1:0]                 dbg_pair_valid,
    output wire [4:0]                           dbg_total_pairs,
    output wire [4:0]                           dbg_pulse_this_cycle
);

    //==========================================================================
    // 过零点掩码生成
    //==========================================================================
    wire [NUM_CHANNELS-1:0] zero_mask;
    wire zero_mask_valid;
    
    zeropoints_mask #(
        .NUM_CHANNELS(NUM_CHANNELS),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_zeropoints_mask (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(valid_in),
        .diff_in(diff_in),
        
        .zero_mask(zero_mask),
        .valid_out(zero_mask_valid)
    );
    
    assign dbg_zero_mask = zero_mask;

    //==========================================================================
    // 差分和绝对电平延迟对齐（与zero_mask同步）
    // zeropoints_mask 有2级延迟
    //==========================================================================
    localparam MASK_DELAY = 2;
    
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] diff_delay [0:MASK_DELAY];
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] abs_delay [0:MASK_DELAY];
    
    integer d;
    always @(posedge clk) begin
        diff_delay[0] <= diff_in;
        abs_delay[0] <= data_before_diff;
        
        for (d = 1; d <= MASK_DELAY; d = d + 1) begin
            diff_delay[d] <= diff_delay[d-1];
            abs_delay[d] <= abs_delay[d-1];
        end
    end
    
    wire [NUM_CHANNELS*DATA_WIDTH-1:0] diff_sync = diff_delay[MASK_DELAY];
    wire [NUM_CHANNELS*DATA_WIDTH-1:0] abs_sync = abs_delay[MASK_DELAY];

    //==========================================================================
    // 零点分析器
    //==========================================================================
    wire [4:0] pulse_this_cycle;
    wire analysis_valid;
    wire [MAX_PAIRS-1:0] pair_valid_dbg;
    wire [4:0] total_pairs_dbg;
    
    zeropoints_analysis #(
        .NUM_CHANNELS(NUM_CHANNELS),
        .DATA_WIDTH(DATA_WIDTH),
        .MAX_PAIRS(MAX_PAIRS)
    ) u_zeropoints_analysis (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(zero_mask_valid),
        .zero_mask(zero_mask),
        .diff_in(diff_sync),
        .abs_in(abs_sync),
        .diff_threshold(diff_threshold),
        .abs_threshold(abs_threshold),
        
        .pulse_count(pulse_this_cycle),
        .valid_out(analysis_valid),
        
        .dbg_pair_valid(pair_valid_dbg),
        .dbg_total_pairs(total_pairs_dbg)
    );
    
    assign dbg_pair_valid = pair_valid_dbg;
    assign dbg_total_pairs = total_pairs_dbg;
    assign dbg_pulse_this_cycle = pulse_this_cycle;

    //==========================================================================
    // 实时脉冲率输出
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pulse_rate <= 0;
        end
        else if (analysis_valid) begin
            pulse_rate <= pulse_this_cycle;
        end
    end

    //==========================================================================
    // 窗口计数逻辑
    //==========================================================================
    reg count_enable_reg;
    reg count_enable_d;
    wire count_enable_rising;
    
    always @(posedge clk) begin
        count_enable_reg <= count_enable;
        count_enable_d <= count_enable_reg;
    end
    
    assign count_enable_rising = count_enable_reg && !count_enable_d;
    
    reg [23:0] window_cnt;
    reg [COUNTER_WIDTH-1:0] pulse_count_acc;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            window_cnt <= 0;
            window_active <= 0;
            pulse_count <= 0;
            pulse_count_acc <= 0;
            count_valid <= 0;
        end
        else begin
            count_valid <= 0;
            
            if (!count_enable_reg) begin
                // 使能关闭
                window_active <= 0;
                window_cnt <= 0;
                pulse_count_acc <= 0;
            end
            else if (count_enable_rising) begin
                // 首次启动
                window_active <= 1;
                window_cnt <= 0;
                pulse_count_acc <= (analysis_valid ? pulse_this_cycle : 0);
            end
            else if (window_active && window_cnt >= window_cycles - 1) begin
                // 窗口结束
                count_valid <= 1;
                pulse_count <= pulse_count_acc + (analysis_valid ? pulse_this_cycle : 0);
                
                // 开始新窗口
                window_cnt <= 0;
                pulse_count_acc <= 0;
            end
            else if (window_active) begin
                // 窗口内累加
                if (analysis_valid) begin
                    pulse_count_acc <= pulse_count_acc + pulse_this_cycle;
                end
                window_cnt <= window_cnt + 1;
            end
        end
    end

endmodule
