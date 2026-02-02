`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: fir_symmetric_layer
// Description: 优化版对称FIR滤波层
//              179阶对称滤波器，利用对称性优化
//
// 定点格式（按用户定义 Qm.n = m位整数含符号 + n位小数）：
//   ADC输入：    Q16.0 (16位)
//   预加法：     Q17.0 (17位)
//   系数：       Q3.18 (21位)
//   乘法结果：   Q20.18 (38位) → 截断为 Q16.16 (32位)
//   累加：       内部用40位防溢出 → 最终截断为 Q16.4 (20位)
//
// 乘法截断说明：
//   Q17.0 × Q3.18 = Q20.18 (38位)
//   截断为Q16.16：丢弃4位高位整数，丢弃2位低位小数
//   取 full_product[33:2]
//
// 累加截断说明：
//   90个Q16.16相加，需要7位额外整数位 → Q23.16 (39位)
//   使用40位累加器
//   最终截断为Q16.4：取bit[31:12]（16位整数+4位小数）
//
// 流水线结构（6级）：
//   Stage 0: 输入寄存（样本+系数）
//   Stage 1: 预加法
//   Stage 2: 乘法+截断
//   Stage 3: 加法树L1-L4
//   Stage 4: 加法树L5-L7
//   Stage 5: 输出
//
// DSP48E2使用：每通道90个DSP
//////////////////////////////////////////////////////////////////////////////////

module fir_symmetric_layer #(
    parameter CHANNEL_ID = 0,
    parameter ADC_WIDTH = 16,
    parameter NUM_PAIRS = 89,
    parameter NUM_COEFFS = 90,
    parameter COEFF_WIDTH = 21,         // Q3.18
    parameter OUTPUT_WIDTH = 20         // Q16.4
)(
    input  wire                              clk,
    input  wire                              valid_in,
    
    // 样本输入（展平向量）
    input  wire [NUM_PAIRS*ADC_WIDTH-1:0]    samples_a,       // 89×16 = 1424位
    input  wire [NUM_PAIRS*ADC_WIDTH-1:0]    samples_b,       // 89×16 = 1424位
    input  wire signed [ADC_WIDTH-1:0]       sample_center,   // 16位
    
    // 系数输入（展平向量）
    input  wire [NUM_COEFFS*COEFF_WIDTH-1:0] coeffs,          // 90×21 = 1890位
    
    // 输出
    output reg  signed [OUTPUT_WIDTH-1:0]    y_out,
    output reg                               valid_out
);

    // 内部位宽参数
    localparam PRE_ADD_WIDTH = 17;          // Q17.0 预加法
    localparam MULT_FULL_WIDTH = 38;        // Q20.18 完整乘法结果
    localparam MULT_TRUNC_WIDTH = 32;       // Q16.16 截断后乘法结果
    localparam ACCUM_WIDTH = 40;            // 累加器（防溢出）

    integer i;
    genvar g;

    //==========================================================================
    // Stage 0: 输入寄存（样本提取 + 系数寄存）
    // 将组合逻辑切片后的数据寄存，改善时序
    //==========================================================================
    
    reg signed [ADC_WIDTH-1:0] sample_a_s0 [0:NUM_PAIRS-1];
    reg signed [ADC_WIDTH-1:0] sample_b_s0 [0:NUM_PAIRS-1];
    reg signed [ADC_WIDTH-1:0] sample_center_s0;
    reg signed [COEFF_WIDTH-1:0] coeff_s0 [0:NUM_COEFFS-1];
    reg valid_s0;
    
    always @(posedge clk) begin
        valid_s0 <= valid_in;
        sample_center_s0 <= sample_center;
        
        // 样本提取并寄存
        for (i = 0; i < NUM_PAIRS; i = i + 1) begin
            sample_a_s0[i] <= samples_a[i*ADC_WIDTH +: ADC_WIDTH];
            sample_b_s0[i] <= samples_b[i*ADC_WIDTH +: ADC_WIDTH];
        end
        
        // 系数寄存（关键：避免系数直接参与组合逻辑乘法）
        for (i = 0; i < NUM_COEFFS; i = i + 1) begin
            coeff_s0[i] <= coeffs[i*COEFF_WIDTH +: COEFF_WIDTH];
        end
    end

    //==========================================================================
    // Stage 1: 预加法 (a[j] + b[j])
    // Q16.0 + Q16.0 = Q17.0 (17位)
    //==========================================================================
    
    reg signed [PRE_ADD_WIDTH-1:0] pre_sum [0:NUM_PAIRS-1];
    reg signed [PRE_ADD_WIDTH-1:0] center_ext;
    reg signed [COEFF_WIDTH-1:0] coeff_s1 [0:NUM_COEFFS-1];
    reg valid_s1;
    
    always @(posedge clk) begin
        valid_s1 <= valid_s0;
        
        // 中心样本符号扩展到17位
        center_ext <= {{1{sample_center_s0[ADC_WIDTH-1]}}, sample_center_s0};
        
        // 预加法：16位符号扩展到17位后相加
        for (i = 0; i < NUM_PAIRS; i = i + 1) begin
            pre_sum[i] <= {{1{sample_a_s0[i][ADC_WIDTH-1]}}, sample_a_s0[i]} + 
                          {{1{sample_b_s0[i][ADC_WIDTH-1]}}, sample_b_s0[i]};
        end
        
        // 系数传递（保持与数据同步）
        for (i = 0; i < NUM_COEFFS; i = i + 1) begin
            coeff_s1[i] <= coeff_s0[i];
        end
    end
    
    //==========================================================================
    // Stage 2: 乘法 + 截断
    // Q17.0 × Q3.18 = Q20.18 (38位) → 截断为 Q16.16 (32位)
    // 乘法在寄存器输出上进行，便于DSP48E2推断
    //==========================================================================
    
    reg signed [MULT_TRUNC_WIDTH-1:0] products [0:NUM_COEFFS-1];
    reg valid_s2;
    
    // 完整乘法结果（组合逻辑，但输入输出都已寄存）
    wire signed [MULT_FULL_WIDTH-1:0] mult_result [0:NUM_COEFFS-1];
    
    generate
        for (g = 0; g < NUM_PAIRS; g = g + 1) begin : gen_mult_pairs
            // Q17.0 × Q3.18 = Q20.18 (38位)
            // pre_sum和coeff_s1都是寄存器输出，时序友好
            assign mult_result[g] = pre_sum[g] * coeff_s1[g];
        end
        // 中心系数乘法
        assign mult_result[NUM_COEFFS-1] = center_ext * coeff_s1[NUM_COEFFS-1];
    endgenerate
    
    always @(posedge clk) begin
        valid_s2 <= valid_s1;
        
        // 截断为Q16.16：取bit[33:2]
        // 丢弃高4位整数（bit[37:34]），丢弃低2位小数（bit[1:0]）
        for (i = 0; i < NUM_COEFFS; i = i + 1) begin
            products[i] <= mult_result[i][33:2];
        end
    end
    
    //==========================================================================
    // Stage 3: 加法树 Level 1-4 (90 → 6)
    // 使用40位累加器防止溢出
    //==========================================================================
    
    reg signed [ACCUM_WIDTH-1:0] sum_L1 [0:44];
    reg signed [ACCUM_WIDTH-1:0] sum_L2 [0:22];
    reg signed [ACCUM_WIDTH-1:0] sum_L3 [0:11];
    reg signed [ACCUM_WIDTH-1:0] sum_L4 [0:5];
    reg valid_s3;
    
    always @(posedge clk) begin
        valid_s3 <= valid_s2;
        
        // Level 1: 90 → 45（32位扩展到40位后相加）
        for (i = 0; i < 45; i = i + 1) begin
            sum_L1[i] <= $signed({{(ACCUM_WIDTH-MULT_TRUNC_WIDTH){products[2*i][MULT_TRUNC_WIDTH-1]}}, products[2*i]}) +
                         $signed({{(ACCUM_WIDTH-MULT_TRUNC_WIDTH){products[2*i+1][MULT_TRUNC_WIDTH-1]}}, products[2*i+1]});
        end
        
        // Level 2: 45 → 23
        for (i = 0; i < 22; i = i + 1) begin
            sum_L2[i] <= sum_L1[2*i] + sum_L1[2*i+1];
        end
        sum_L2[22] <= sum_L1[44];
        
        // Level 3: 23 → 12
        for (i = 0; i < 11; i = i + 1) begin
            sum_L3[i] <= sum_L2[2*i] + sum_L2[2*i+1];
        end
        sum_L3[11] <= sum_L2[22];
        
        // Level 4: 12 → 6
        for (i = 0; i < 6; i = i + 1) begin
            sum_L4[i] <= sum_L3[2*i] + sum_L3[2*i+1];
        end
    end
    
    //==========================================================================
    // Stage 4: 加法树 Level 5-7 (6 → 1)
    //==========================================================================
    
    reg signed [ACCUM_WIDTH-1:0] sum_L5 [0:2];
    reg signed [ACCUM_WIDTH-1:0] sum_L6 [0:1];
    reg signed [ACCUM_WIDTH-1:0] sum_L7;
    reg valid_s4;
    
    always @(posedge clk) begin
        valid_s4 <= valid_s3;
        
        // Level 5: 6 → 3
        for (i = 0; i < 3; i = i + 1) begin
            sum_L5[i] <= sum_L4[2*i] + sum_L4[2*i+1];
        end
        
        // Level 6: 3 → 2
        sum_L6[0] <= sum_L5[0] + sum_L5[1];
        sum_L6[1] <= sum_L5[2];
        
        // Level 7: 2 → 1
        sum_L7 <= sum_L6[0] + sum_L6[1];
    end

    //==========================================================================
    // Stage 5: 输出截断
    // 累加器格式：Q23.16（40位存储）
    //   - bit[15:0]  = 小数部分（16位）
    //   - bit[38:16] = 整数部分（23位有效）
    // 输出格式：Q16.4（20位）
    //   - 取整数部分低16位：bit[31:16]
    //   - 取小数部分高4位：bit[15:12]
    //   - 合并：bit[31:12]
    //==========================================================================
    
    reg valid_s5;
    
    always @(posedge clk) begin
        valid_s5 <= valid_s4;
        
        // 正确的截断：取bit[31:12]得到Q16.4
        y_out <= sum_L7[31:12];
        valid_out <= valid_s5;
    end

endmodule
