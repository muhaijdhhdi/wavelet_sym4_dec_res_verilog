`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: pulse_counter
// Description: 脉冲计数模块（正确的相邻采样点过零检测）
//
// 采样结构：
//   ADC采样率：1.25GHz（0.8ns/点）
//   16:1解串后：78.125MHz（12.8ns/周期）
//   每个时钟周期包含16个**时间连续**的采样点（ch0=最早，ch15=最晚）
//
// 过零检测原理（核心修正）：
//   检测**相邻采样点**之间的符号变化（0.8ns间隔），而非相隔16个点（12.8ns）
//   - 边界0: ch[0] vs 上一周期ch[15]（跨周期边界）
//   - 边界1: ch[1] vs ch[0]
//   - ...
//   - 边界15: ch[15] vs ch[14]
//   这样每个真实过零只会被检测到一次
//
// 死区时间：
//   使用全局死区计数器，检测到脉冲后在dead_time周期内忽略所有新过零
//   因为脉冲是单一时间轴上的事件
//
// 双阈值判断（避免假过零）：
//   1. 差分阈值（diff_threshold）：
//      检测差分信号的幅度变化是否足够大（有效的上升/下降沿）
//   2. 绝对阈值（abs_threshold）：
//      检测差分前原始信号的绝对值是否足够大（排除噪声和小信号相交）
//   目的：两个小脉冲相交时也会产生差分过零，但原始信号幅度很小，应排除
//
// 输出行为：
//   pulse_count在窗口期间保持上一个窗口的值
//   窗口结束时才更新为当前窗口的计数结果
//
// 流水线结构（深度优化，5级）：
//   Stage 0:  输入寄存
//   Stage 1a: 采样点寄存 + 阈值寄存
//   Stage 1b: 符号检测 + 幅度比较
//   Stage 2a: 过零检测结果寄存
//   Stage 2b: 或归约 + 死区管理
//   Stage 3:  输出寄存
//   总延迟：6个时钟周期（76.8ns @ 78.125MHz）
//
// 定点格式：
//   差分输入：       Q16.4（20位）
//   差分前输入：     Q16.4（20位）
//   差分阈值：       Q16.4（20位，正数）
//   绝对阈值：       Q16.4（20位，正数）
//////////////////////////////////////////////////////////////////////////////////

module pulse_counter #(
    parameter NUM_CHANNELS = 16,
    parameter DATA_WIDTH = 20,            // Q16.4格式
    parameter COUNTER_WIDTH = 16,         // 支持最大65535个脉冲
    parameter DEAD_TIME_WIDTH = 8         // 死区计数器位宽，支持最大255周期
)(
    input  wire                                  clk,
    input  wire                                  rst_n,
    input  wire                                  valid_in,
    input  wire [NUM_CHANNELS*DATA_WIDTH-1:0]   diff_in,          // 320位差分数据
    input  wire [NUM_CHANNELS*DATA_WIDTH-1:0]   data_before_diff, // 320位差分前数据（与diff_in相位对齐）
    input  wire signed [DATA_WIDTH-1:0]         diff_threshold,   // 差分阈值（正数，Q16.4格式）
    input  wire signed [DATA_WIDTH-1:0]         abs_threshold,    // 绝对阈值（正数，Q16.4格式）
    input  wire [DEAD_TIME_WIDTH-1:0]           dead_time,        // 死区时间（周期数），以12.8ns为单位
    input  wire [15:0]                          window_cycles,    // 窗口长度（周期数），以12.8ns为单位
    input  wire                                 count_enable,     // 计数使能（高电平时窗口自动周期运行）
    
    output reg  [COUNTER_WIDTH-1:0]             pulse_count,      // 脉冲总数（窗口结束时更新，期间保持）
    output reg                                  count_valid,      // 计数有效（窗口结束时拉高一拍）
    output reg                                  window_active,    // 窗口激活状态
    
    // 调试输出
    output wire [NUM_CHANNELS-1:0]              dbg_sign_change,        // 16个边界的符号变化
    output wire [NUM_CHANNELS-1:0]              dbg_diff_amplitude_ok,  // 16个边界的差分幅度检查
    output wire [NUM_CHANNELS-1:0]              dbg_abs_amplitude_ok,   // 16个边界的绝对幅度检查
    output wire                                 dbg_pulse_detected,     // 当前周期检测到脉冲
    output wire                                 dbg_in_dead_time,       // 是否在死区中
    output wire [4:0]                           dbg_pulse_this_cycle    // 当前周期脉冲数（应为0或1）
);

    integer i;
    genvar g;

    //==========================================================================
    // Stage 0: 输入寄存
    //==========================================================================
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] diff_in_reg;
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] data_before_diff_reg;
    reg valid_in_reg;
    reg count_enable_reg;
    reg count_enable_d;
    
    always @(posedge clk) begin
        diff_in_reg <= diff_in;
        data_before_diff_reg <= data_before_diff;
        valid_in_reg <= valid_in;
        count_enable_reg <= count_enable;
        count_enable_d <= count_enable_reg;
    end
    
    wire count_enable_rising = count_enable_reg && !count_enable_d;

    //==========================================================================
    // 提取各通道数据为独立信号（便于理解和使用）
    //==========================================================================
    wire signed [DATA_WIDTH-1:0] sample [0:NUM_CHANNELS-1];           // 差分信号
    wire signed [DATA_WIDTH-1:0] sample_orig [0:NUM_CHANNELS-1];      // 差分前信号
    generate
        for (g = 0; g < NUM_CHANNELS; g = g + 1) begin : gen_samples
            assign sample[g] = diff_in_reg[g*DATA_WIDTH +: DATA_WIDTH];
            assign sample_orig[g] = data_before_diff_reg[g*DATA_WIDTH +: DATA_WIDTH];
        end
    endgenerate

    //==========================================================================
    // Stage 1a: 采样点寄存（优化时序）
    // 将sample寄存一拍，避免直接从diff_in_reg提取后立即进行比较
    //==========================================================================
    reg signed [DATA_WIDTH-1:0] sample_s1 [0:NUM_CHANNELS-1];           // 差分信号寄存
    reg signed [DATA_WIDTH-1:0] sample_orig_s1 [0:NUM_CHANNELS-1];      // 差分前信号寄存
    reg signed [DATA_WIDTH-1:0] last_sample_prev;                       // 上一周期的ch[15]（差分）
    reg signed [DATA_WIDTH-1:0] last_sample_orig_prev;                  // 上一周期的ch[15]（差分前）
    reg valid_prev;
    reg valid_s1a;
    
    always @(posedge clk) begin
        // 寄存所有采样点（差分信号和差分前信号）
        for (i = 0; i < NUM_CHANNELS; i = i + 1) begin
            sample_s1[i] <= sample[i];
            sample_orig_s1[i] <= sample_orig[i];
        end
        last_sample_prev <= sample[NUM_CHANNELS-1];
        last_sample_orig_prev <= sample_orig[NUM_CHANNELS-1];
        valid_prev <= valid_in_reg;
        valid_s1a <= valid_in_reg && valid_prev;
    end
    
    //==========================================================================
    // Stage 1b: 符号检测 + 差分幅度检查 + 绝对幅度检查（寄存器输出，优化时序）
    // 将符号比较和幅度比较分离到寄存器中
    // 新增：差分前信号的绝对值检查（避免小信号相交的假过零）
    //==========================================================================
    reg [NUM_CHANNELS-1:0] sign_change_reg;          // 边界i处是否有符号变化
    reg [NUM_CHANNELS-1:0] diff_amplitude_ok_reg;    // 边界i处差分幅度是否超过差分阈值
    reg [NUM_CHANNELS-1:0] abs_amplitude_ok_reg;     // 边界i处原始信号绝对值是否超过绝对阈值
    reg valid_s1b;
    
    // 阈值寄存（优化扇出）
    reg signed [DATA_WIDTH-1:0] diff_threshold_reg;
    reg signed [DATA_WIDTH-1:0] diff_threshold_neg_reg;
    reg signed [DATA_WIDTH-1:0] abs_threshold_reg;
    reg signed [DATA_WIDTH-1:0] abs_threshold_neg_reg;
    
    always @(posedge clk) begin
        diff_threshold_reg <= diff_threshold;
        diff_threshold_neg_reg <= -diff_threshold;
        abs_threshold_reg <= abs_threshold;
        abs_threshold_neg_reg <= -abs_threshold;
        valid_s1b <= valid_s1a;
        
        // 边界0：ch[0] vs 上一周期ch[15]（跨周期边界）
        sign_change_reg[0] <= (sample_s1[0][DATA_WIDTH-1] != last_sample_prev[DATA_WIDTH-1]);
        
        // 差分幅度检查：使用过零前的差分采样点（last_sample_prev）
        if (last_sample_prev[DATA_WIDTH-1] == 1'b0) begin
            diff_amplitude_ok_reg[0] <= (last_sample_prev > diff_threshold_reg);
        end else begin
            diff_amplitude_ok_reg[0] <= (last_sample_prev < diff_threshold_neg_reg);
        end
        
        // 绝对幅度检查：使用过零前的原始采样点（last_sample_orig_prev）的绝对值
        if (last_sample_orig_prev[DATA_WIDTH-1] == 1'b0) begin
            abs_amplitude_ok_reg[0] <= (last_sample_orig_prev > abs_threshold_reg);
        end else begin
            abs_amplitude_ok_reg[0] <= (last_sample_orig_prev < abs_threshold_neg_reg);
        end
        
        // 边界1-15：ch[i] vs ch[i-1]（周期内相邻点）
        for (i = 1; i < NUM_CHANNELS; i = i + 1) begin
            sign_change_reg[i] <= (sample_s1[i][DATA_WIDTH-1] != sample_s1[i-1][DATA_WIDTH-1]);
            
            // 差分幅度检查：使用过零前的差分采样点（sample_s1[i-1]）
            if (sample_s1[i-1][DATA_WIDTH-1] == 1'b0) begin
                diff_amplitude_ok_reg[i] <= (sample_s1[i-1] > diff_threshold_reg);
            end else begin
                diff_amplitude_ok_reg[i] <= (sample_s1[i-1] < diff_threshold_neg_reg);
            end
            
            // 绝对幅度检查：使用过零前的原始采样点（sample_orig_s1[i-1]）的绝对值
            if (sample_orig_s1[i-1][DATA_WIDTH-1] == 1'b0) begin
                abs_amplitude_ok_reg[i] <= (sample_orig_s1[i-1] > abs_threshold_reg);
            end else begin
                abs_amplitude_ok_reg[i] <= (sample_orig_s1[i-1] < abs_threshold_neg_reg);
            end
        end
    end
    
    //==========================================================================
    // Stage 2a: 过零检测结果寄存（进一步优化时序）
    // 将raw_zero_cross的计算结果寄存，避免16位与门后立即做或归约
    // 过零条件：符号变化 + 差分幅度达标 + 原始信号绝对值达标
    //==========================================================================
    reg [NUM_CHANNELS-1:0] raw_zero_cross_reg;
    reg valid_s2a;
    
    always @(posedge clk) begin
        valid_s2a <= valid_s1b;
        for (i = 0; i < NUM_CHANNELS; i = i + 1) begin
            raw_zero_cross_reg[i] <= sign_change_reg[i] && diff_amplitude_ok_reg[i] && abs_amplitude_ok_reg[i];
        end
    end
    
    //==========================================================================
    // Stage 2b: 或归约 + 死区管理
    //==========================================================================
    
    // 检测是否有任何一个边界过零（或归约）
    wire any_zero_cross = |raw_zero_cross_reg;
    
    // 全局死区计数器
    reg [DEAD_TIME_WIDTH-1:0] dead_cnt;
    reg in_dead_time;
    reg pulse_detected;  // 当前周期检测到有效脉冲
    reg valid_s2b;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dead_cnt <= 0;
            in_dead_time <= 0;
            pulse_detected <= 0;
            valid_s2b <= 0;
        end
        else begin
            valid_s2b <= valid_s2a;
            
            if (valid_s2a && any_zero_cross && !in_dead_time) begin
                // 检测到有效脉冲：有过零 + 不在死区
                pulse_detected <= 1'b1;
                dead_cnt <= dead_time;
                in_dead_time <= 1'b1;
            end
            else begin
                pulse_detected <= 1'b0;
                
                // 死区倒计时
                if (in_dead_time) begin
                    if (dead_cnt <= 1) begin
                        in_dead_time <= 1'b0;
                        dead_cnt <= 0;
                    end
                    else begin
                        dead_cnt <= dead_cnt - 1'b1;
                    end
                end
            end
        end
    end
    
    //==========================================================================
    // Stage 3: 输出寄存
    // 每个周期最多检测到1个脉冲
    //==========================================================================
    reg pulse_this_cycle;  // 0或1
    reg valid_s3;
    
    always @(posedge clk) begin
        valid_s3 <= valid_s2b;
        pulse_this_cycle <= pulse_detected;
    end
    
    //==========================================================================
    // 调试信号输出
    //==========================================================================
    assign dbg_sign_change = sign_change_reg;
    assign dbg_diff_amplitude_ok = diff_amplitude_ok_reg;
    assign dbg_abs_amplitude_ok = abs_amplitude_ok_reg;
    assign dbg_pulse_detected = pulse_detected;
    assign dbg_in_dead_time = in_dead_time;
    assign dbg_pulse_this_cycle = {4'b0, pulse_this_cycle};
    
    //==========================================================================
    // 窗口计数逻辑
    // pulse_count 在窗口期间保持上一个窗口的值，窗口结束时才更新
    //==========================================================================
    reg [15:0] window_cnt;
    reg [COUNTER_WIDTH-1:0] pulse_count_acc;  // 当前窗口的累加器（内部）
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            window_cnt <= 0;
            window_active <= 0;
            pulse_count <= 0;
            pulse_count_acc <= 0;
            count_valid <= 0;
        end
        else begin
            count_valid <= 0;  // 默认
            
            if (!count_enable_reg) begin
                // 使能关闭：停止计数，重置状态
                window_active <= 0;
                window_cnt <= 0;
                pulse_count_acc <= 0;
            end
            else if (count_enable_rising) begin
                // 首次启动：开始第一个窗口
                window_active <= 1;
                window_cnt <= 0;
                pulse_count_acc <= pulse_this_cycle;
                // pulse_count 保持为0（或上一次的值）
            end
            else if (window_active && window_cnt >= window_cycles - 1) begin
                // 窗口结束：输出结果并开始新窗口
                count_valid <= 1;
                pulse_count <= pulse_count_acc + pulse_this_cycle;  // 更新输出（包含最后一周期）
                
                // 立即开始新窗口
                window_cnt <= 0;
                pulse_count_acc <= 0;  // 新窗口从0开始（下一周期才开始累加）
            end
            else if (window_active) begin
                // 窗口内：累加脉冲
                pulse_count_acc <= pulse_count_acc + pulse_this_cycle;
                window_cnt <= window_cnt + 1;
                // pulse_count 保持不变（显示上一个窗口的结果）
            end
        end
    end

endmodule
