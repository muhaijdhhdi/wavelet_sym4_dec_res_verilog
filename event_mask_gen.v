`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: event_mask_gen
// Description: 双阈值事件掩码生成模块
//              检测16个采样点差分值"跨越阈值"的动作，生成事件掩码
//
// 设计原理（diff_trigger版本核心）：
//   不使用"电平触发"或"过零点配对"，而是检测"跨越阈值"这个瞬时动作
//   跨越阈值是一个点事件，只能落在某一个采样点，无需跨周期处理
//
// 采样结构：
//   ADC采样率：1.25GHz（0.8ns/点）
//   16:1解串后：78.125MHz（12.8ns/周期）
//   每个时钟周期包含16个时间连续的采样点（ch0=最早，ch15=最晚）
//
// 跨越检测（上穿）：
//   边界0: ch[0] vs 上一周期ch[15]（跨周期边界）
//   边界1: ch[1] vs ch[0]
//   ...
//   边界15: ch[15] vs ch[14]
//   跨越条件：前一点 < threshold 且 当前点 >= threshold
//
// 双阈值设计：
//   - threshold1：主阈值，跨越产生 event_mask1
//   - threshold2：堆积阈值（threshold2 > threshold1），跨越产生 event_mask2
//
// 输出：
//   event_mask1[15:0]：每位表示对应边界是否跨越阈值1
//   event_mask2[15:0]：每位表示对应边界是否跨越阈值2
//
// 流水线延迟：3个时钟周期
//////////////////////////////////////////////////////////////////////////////////

module event_mask_gen #(
    parameter NUM_CHANNELS = 16,
    parameter DATA_WIDTH = 20              // Q16.4格式
)(
    input  wire                                  clk,
    input  wire                                  rst_n,
    input  wire                                  valid_in,
    input  wire [NUM_CHANNELS*DATA_WIDTH-1:0]   diff_in,          // 320位差分数据
    input  wire signed [DATA_WIDTH-1:0]         threshold1,       // 主阈值（正数）
    input  wire signed [DATA_WIDTH-1:0]         threshold2,       // 堆积阈值（正数，> threshold1）
    
    output reg  [NUM_CHANNELS-1:0]              event_mask1,      // 16位事件掩码1
    output reg  [NUM_CHANNELS-1:0]              event_mask2,      // 16位事件掩码2
    output reg                                   valid_out
);

    //==========================================================================
    // 提取各通道差分数据
    //==========================================================================
    wire signed [DATA_WIDTH-1:0] diff_ch [0:NUM_CHANNELS-1];
    
    genvar g;
    generate
        for (g = 0; g < NUM_CHANNELS; g = g + 1) begin : gen_extract
            assign diff_ch[g] = diff_in[g*DATA_WIDTH +: DATA_WIDTH];
        end
    endgenerate

    //==========================================================================
    // Stage 1: 输入寄存 + 保存上周期ch15
    //==========================================================================
    reg signed [DATA_WIDTH-1:0] diff_s1 [0:NUM_CHANNELS-1];
    reg signed [DATA_WIDTH-1:0] last_diff_prev;      // 上一周期ch15的差分值
    reg signed [DATA_WIDTH-1:0] threshold1_s1;
    reg signed [DATA_WIDTH-1:0] threshold2_s1;
    reg valid_s1;
    reg valid_prev;
    
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < NUM_CHANNELS; i = i + 1) begin
                diff_s1[i] <= 0;
            end
            last_diff_prev <= 0;
            threshold1_s1 <= 0;
            threshold2_s1 <= 0;
            valid_s1 <= 0;
            valid_prev <= 0;
        end
        else begin
            for (i = 0; i < NUM_CHANNELS; i = i + 1) begin
                diff_s1[i] <= diff_ch[i];
            end
            last_diff_prev <= diff_ch[NUM_CHANNELS-1];  // 保存ch15
            threshold1_s1 <= threshold1;
            threshold2_s1 <= threshold2;
            valid_prev <= valid_in;
            valid_s1 <= valid_in && valid_prev;  // 需要有上一周期数据才有效
        end
    end

    //==========================================================================
    // Stage 2: 跨越检测
    // 跨越条件：前一点 < threshold 且 当前点 >= threshold（上穿）
    //==========================================================================
    reg [NUM_CHANNELS-1:0] cross1_s2;   // 跨越阈值1
    reg [NUM_CHANNELS-1:0] cross2_s2;   // 跨越阈值2
    reg valid_s2;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cross1_s2 <= 0;
            cross2_s2 <= 0;
            valid_s2 <= 0;
        end
        else begin
            valid_s2 <= valid_s1;
            
            // 边界0：ch[0] vs 上一周期ch[15]
            cross1_s2[0] <= (last_diff_prev < threshold1_s1) && (diff_s1[0] >= threshold1_s1);
            cross2_s2[0] <= (last_diff_prev < threshold2_s1) && (diff_s1[0] >= threshold2_s1);
            
            // 边界1-15：ch[i] vs ch[i-1]
            for (i = 1; i < NUM_CHANNELS; i = i + 1) begin
                cross1_s2[i] <= (diff_s1[i-1] < threshold1_s1) && (diff_s1[i] >= threshold1_s1);
                cross2_s2[i] <= (diff_s1[i-1] < threshold2_s1) && (diff_s1[i] >= threshold2_s1);
            end
        end
    end

    //==========================================================================
    // Stage 3: 输出寄存
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            event_mask1 <= 0;
            event_mask2 <= 0;
            valid_out <= 0;
        end
        else begin
            event_mask1 <= cross1_s2;
            event_mask2 <= cross2_s2;
            valid_out <= valid_s2;
        end
    end

endmodule
