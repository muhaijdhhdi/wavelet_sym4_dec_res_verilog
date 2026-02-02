`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: zeropoints_mask
// Description: 过零点掩码生成模块
//              检测16个相邻采样点边界的符号变化，生成16-bit过零掩码
//
// 采样结构：
//   ADC采样率：1.25GHz（0.8ns/点）
//   16:1解串后：78.125MHz（12.8ns/周期）
//   每个时钟周期包含16个时间连续的采样点（ch0=最早，ch15=最晚）
//
// 过零检测：
//   边界0: ch[0] vs 上一周期ch[15]（跨周期边界）
//   边界1: ch[1] vs ch[0]
//   ...
//   边界15: ch[15] vs ch[14]
//
// 输出：
//   zero_mask[15:0]：每位表示对应边界是否有过零
//
// 流水线延迟：2个时钟周期
//////////////////////////////////////////////////////////////////////////////////

module zeropoints_mask #(
    parameter NUM_CHANNELS = 16,
    parameter DATA_WIDTH = 20              // Q16.4格式
)(
    input  wire                                  clk,
    input  wire                                  rst_n,
    input  wire                                  valid_in,
    input  wire [NUM_CHANNELS*DATA_WIDTH-1:0]   diff_in,          // 320位差分数据
    
    output reg  [NUM_CHANNELS-1:0]              zero_mask,        // 16位过零掩码
    output reg                                   valid_out
);

    //==========================================================================
    // 提取各通道差分数据的符号位
    //==========================================================================
    wire [NUM_CHANNELS-1:0] sign_bits;
    
    genvar g;
    generate
        for (g = 0; g < NUM_CHANNELS; g = g + 1) begin : gen_sign
            // 符号位是最高位
            assign sign_bits[g] = diff_in[(g+1)*DATA_WIDTH - 1];
        end
    endgenerate

    //==========================================================================
    // Stage 1: 符号位寄存 + 保存上周期ch15的符号
    //==========================================================================
    reg [NUM_CHANNELS-1:0] sign_bits_s1;
    reg last_sign_prev;      // 上一周期ch15的符号位
    reg valid_s1;
    reg valid_prev;          // 用于检测有效的上一周期
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sign_bits_s1 <= 0;
            last_sign_prev <= 0;
            valid_s1 <= 0;
            valid_prev <= 0;
        end
        else begin
            sign_bits_s1 <= sign_bits;
            last_sign_prev <= sign_bits[NUM_CHANNELS-1];  // 保存ch15的符号
            valid_prev <= valid_in;
            valid_s1 <= valid_in && valid_prev;  // 需要有上一周期数据才有效
        end
    end

    //==========================================================================
    // Stage 2: 过零检测
    // 检测相邻采样点之间的符号变化
    //==========================================================================
    reg [NUM_CHANNELS-1:0] zero_mask_s2;
    reg valid_s2;
    
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            zero_mask_s2 <= 0;
            valid_s2 <= 0;
        end
        else begin
            valid_s2 <= valid_s1;
            
            // 边界0：ch[0] vs 上一周期ch[15]
            zero_mask_s2[0] <= (sign_bits_s1[0] != last_sign_prev);
            
            // 边界1-15：ch[i] vs ch[i-1]
            for (i = 1; i < NUM_CHANNELS; i = i + 1) begin
                zero_mask_s2[i] <= (sign_bits_s1[i] != sign_bits_s1[i-1]);
            end
        end
    end

    //==========================================================================
    // 输出
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            zero_mask <= 0;
            valid_out <= 0;
        end
        else begin
            zero_mask <= zero_mask_s2;
            valid_out <= valid_s2;
        end
    end

endmodule
