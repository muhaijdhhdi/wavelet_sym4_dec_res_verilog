//==============================================================================
// 小波基线去除顶层模块
// 
// 功能：使用sym4小波进行7级分解和重构，提取低频基线并从原始信号中减去
// 
// 输入�?16路并行采样数据，打包�?256�? (16×16bit Q16.0)
// 输出：去除基线后的信号，打包�?256�? (16×16bit Q16.0)
// 
// 数据格式�?
//   din[15:0]   = 通道0 (�?早采样点)
//   din[31:16]  = 通道1
//   ...
//   din[255:240] = 通道15 (�?晚采样点)
// 
// 流水线延迟分析：
//   延迟 = 算法延迟（等待历史数据）+ 物理延迟（计算流水线�?
//
//   分解阶段�?78周期）：
//     L1: 1(算法) + 3(物理) = 4   累计: 4
//     L2: 1 + 3 = 4               累计: 8
//     L3: 2 + 3 = 5               累计: 13
//     L4: 4 + 3 = 7               累计: 20
//     L5: 7 + 3 = 10              累计: 30
//     L6: 14 + 3 = 17             累计: 47
//     L7: 28 + 3 = 31             累计: 78
//
//   重构阶段�?76周期）：
//     R7: 24(3历史×8周期) + 5 = 29  累计: 107
//     R6: 12(3历史×4周期) + 5 = 17  累计: 124
//     R5: 6(3历史×2周期) + 5 = 11   累计: 135
//     R4: 3 + 3 = 6                累计: 141
//     R3: 2 + 3 = 5                累计: 146
//     R2: 1 + 3 = 4                累计: 150
//     R1: 1 + 3 = 4                累计: 154
//
//   减法输出打一拍：+1周期
//   总延迟：155周期
//
// 资源估算�?
//   分解乘法器：64+32+16+8+8+8+8 = 144
//   重构乘法器：8+8+8+8+16+32+64 = 144
//   总乘法器�?288
//
//==============================================================================
`timescale 1ns/1ps
//`define  VIVADO_SIM

`ifndef VIVADO_SIM
    `include "../baseLine/decompose_L1.v"
    `include "../baseLine/decompose_L2.v"
    `include "../baseLine/decompose_L3.v"
    `include "../baseLine/decompose_L4.v"
    `include "../baseLine/decompose_L5.v"
    `include "../baseLine/decompose_L6.v"
    `include "../baseLine/decompose_L7.v"
    `include "../baseLine/reconstruct_L7.v" 
    `include "../baseLine/reconstruct_L6.v"
    `include "../baseLine/reconstruct_L5.v"
    `include "../baseLine/reconstruct_L4.v"
    `include "../baseLine/reconstruct_L3.v"
    `include "../baseLine/reconstruct_L2.v"
    `include "../baseLine/reconstruct_L1.v"
`endif 

module wavelet_baseline_removal_top #(
    parameter DATA_WIDTH     = 16,      // 单�?�道数据位宽 (Q16.0)
    parameter DATA_OUTPUT    = DATA_WIDTH+1, //减法后输出的位宽,防止溢出
    parameter COEF_WIDTH     = 25,      // 系数位宽 (Q2.23)
    parameter COEF_FRAC      = 23,      // 系数小数�?
    parameter INTERNAL_WIDTH = 48,      // 内部计算位宽 (Q25.23)
    parameter TOTAL_DELAY    = 154    // 总延迟周期数（算法延�?+物理延迟�?
    
    //==========================================================================
    // // sym4 分解低�?�滤波器系数 (Q2.23)
    // //==========================================================================
    // parameter signed [COEF_WIDTH-1:0] DEC_H0 = 25'sb1111101100100110101001111,
    // parameter signed [COEF_WIDTH-1:0] DEC_H1 = 25'sb1111111000011010011100111,
    // parameter signed [COEF_WIDTH-1:0] DEC_H2 = 25'sb0001111111011000111111000,
    // parameter signed [COEF_WIDTH-1:0] DEC_H3 = 25'sb0011001101110000011101001,
    // parameter signed [COEF_WIDTH-1:0] DEC_H4 = 25'sb0001001100010000000110100,
    // parameter signed [COEF_WIDTH-1:0] DEC_H5 = 25'sb1111100110100110011000110,
    // parameter signed [COEF_WIDTH-1:0] DEC_H6 = 25'sb1111111100110001011111110,
    // parameter signed [COEF_WIDTH-1:0] DEC_H7 = 25'sb0000001000001111111100011,   
    
    // //==========================================================================
    // // sym4 重构低�?�滤波器系数 (Q2.23)
    // //==========================================================================
    // parameter signed [COEF_WIDTH-1:0] REC_H0 = DEC_H7,   // -0.00951648
    // parameter signed [COEF_WIDTH-1:0] REC_H1 = DEC_H6,  // -0.0170866
    // parameter signed [COEF_WIDTH-1:0] REC_H2 = DEC_H5,  // 0.442659
    // parameter signed [COEF_WIDTH-1:0] REC_H3 = DEC_H4,  // 0.705800
    // parameter signed [COEF_WIDTH-1:0] REC_H4 = DEC_H3,  // 0.299006
    // parameter signed [COEF_WIDTH-1:0] REC_H5 = DEC_H2,  // -0.0532824
    // parameter signed [COEF_WIDTH-1:0] REC_H6 = DEC_H1,  // -0.0300516
    // parameter signed [COEF_WIDTH-1:0] REC_H7 = DEC_H0    // 0.0083054
    
)(
    input  wire                              clk,
    input  wire                              rst_n,
    
    // 输入�?16个并行采样点，打包为256�?
    input  wire                              din_valid,
    input  wire [DATA_WIDTH*16-1:0]          din,          // 256�?
    
    // 输出：基线，打包�?256�?
    output wire                              baseline_valid,
    output wire [DATA_OUTPUT*16-1:0]          baseline,     // 256�?
    
    // 输出：去除基线后的信号，打包�?256�?
    output wire [DATA_OUTPUT*16-1:0]          signal_no_baseline  // 256�?
);

    `include "coef_params.vh"
    //==========================================================================
    // 输入解包
    //==========================================================================
    wire signed [DATA_WIDTH-1:0] din_unpacked [0:15];
    
    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : unpack_din
            assign din_unpacked[gi] = din[DATA_WIDTH*(gi+1)-1 : DATA_WIDTH*gi];
        end
    endgenerate

    //==========================================================================
    // 原始信号延迟线（用于与基线对齐）
    //==========================================================================
    reg signed [DATA_WIDTH-1:0] din_delay [0:TOTAL_DELAY-1][0:15];
    reg [TOTAL_DELAY-1:0] valid_delay;
    
    integer i, j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_delay <= 0;
            for (i = 0; i < TOTAL_DELAY; i = i + 1) begin
                for (j = 0; j < 16; j = j + 1) begin
                    din_delay[i][j] <= 0;
                end
            end
        end else begin
            valid_delay <= {valid_delay[TOTAL_DELAY-2:0], din_valid};
            
            for (j = 0; j < 16; j = j + 1) begin
                din_delay[0][j] <= din_unpacked[j];
            end
            
            for (i = 1; i < TOTAL_DELAY; i = i + 1) begin
                for (j = 0; j < 16; j = j + 1) begin
                    din_delay[i][j] <= din_delay[i-1][j];
                end
            end
        end
    end
    
    wire signed [DATA_WIDTH-1:0] din_aligned [0:15];
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : align_din
            assign din_aligned[gi] = din_delay[TOTAL_DELAY-1][gi];
        end
    endgenerate

    //==========================================================================
    // 分解 L1: x(16) �? a1(8)
    //==========================================================================
    wire l1_valid;
    wire signed [INTERNAL_WIDTH-1:0] a1 [0:7];
    
    decompose_L1 #(
        .DATA_WIDTH(DATA_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_FRAC(COEF_FRAC),
        .DEC_H0(DEC_H0), .DEC_H1(DEC_H1), .DEC_H2(DEC_H2), .DEC_H3(DEC_H3),
        .DEC_H4(DEC_H4), .DEC_H5(DEC_H5), .DEC_H6(DEC_H6), .DEC_H7(DEC_H7)
    ) u_decompose_L1 (
        .clk(clk), .rst_n(rst_n),
        .din_valid(din_valid),
        .din_0(din_unpacked[0]),   .din_1(din_unpacked[1]),
        .din_2(din_unpacked[2]),   .din_3(din_unpacked[3]),
        .din_4(din_unpacked[4]),   .din_5(din_unpacked[5]),
        .din_6(din_unpacked[6]),   .din_7(din_unpacked[7]),
        .din_8(din_unpacked[8]),   .din_9(din_unpacked[9]),
        .din_10(din_unpacked[10]), .din_11(din_unpacked[11]),
        .din_12(din_unpacked[12]), .din_13(din_unpacked[13]),
        .din_14(din_unpacked[14]), .din_15(din_unpacked[15]),
        .dout_valid(l1_valid),
        .a1_0(a1[0]), .a1_1(a1[1]), .a1_2(a1[2]), .a1_3(a1[3]),
        .a1_4(a1[4]), .a1_5(a1[5]), .a1_6(a1[6]), .a1_7(a1[7])
    );
    
    //==========================================================================
    // 分解 L2: a1(8) �? a2(4)
    //==========================================================================
    wire l2_valid;
    wire signed [INTERNAL_WIDTH-1:0] a2 [0:3];
    
    decompose_L2 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .COEF_FRAC(COEF_FRAC),
        .DEC_H0(DEC_H0), .DEC_H1(DEC_H1), .DEC_H2(DEC_H2), .DEC_H3(DEC_H3),
        .DEC_H4(DEC_H4), .DEC_H5(DEC_H5), .DEC_H6(DEC_H6), .DEC_H7(DEC_H7)
    ) u_decompose_L2 (
        .clk(clk), .rst_n(rst_n),
        .din_valid(l1_valid),
        .a1_0(a1[0]), .a1_1(a1[1]), .a1_2(a1[2]), .a1_3(a1[3]),
        .a1_4(a1[4]), .a1_5(a1[5]), .a1_6(a1[6]), .a1_7(a1[7]),
        .dout_valid(l2_valid),
        .a2_0(a2[0]), .a2_1(a2[1]), .a2_2(a2[2]), .a2_3(a2[3])
    );
    
    //==========================================================================
    // 分解 L3: a2(4) �? a3(2)
    //==========================================================================
    wire l3_valid;
    wire signed [INTERNAL_WIDTH-1:0] a3 [0:1];
    
    decompose_L3 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .COEF_FRAC(COEF_FRAC),
        .DEC_H0(DEC_H0), .DEC_H1(DEC_H1), .DEC_H2(DEC_H2), .DEC_H3(DEC_H3),
        .DEC_H4(DEC_H4), .DEC_H5(DEC_H5), .DEC_H6(DEC_H6), .DEC_H7(DEC_H7)
    ) u_decompose_L3 (
        .clk(clk), .rst_n(rst_n),
        .din_valid(l2_valid),
        .a2_0(a2[0]), .a2_1(a2[1]), .a2_2(a2[2]), .a2_3(a2[3]),
        .dout_valid(l3_valid),
        .a3_0(a3[0]), .a3_1(a3[1])
    );
    
    //==========================================================================
    // 分解 L4: a3(2) �? a4(1)
    //==========================================================================
    wire l4_valid;
    wire signed [INTERNAL_WIDTH-1:0] a4;
    
    decompose_L4 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .COEF_FRAC(COEF_FRAC),
        .DEC_H0(DEC_H0), .DEC_H1(DEC_H1), .DEC_H2(DEC_H2), .DEC_H3(DEC_H3),
        .DEC_H4(DEC_H4), .DEC_H5(DEC_H5), .DEC_H6(DEC_H6), .DEC_H7(DEC_H7)
    ) u_decompose_L4 (
        .clk(clk), .rst_n(rst_n),
        .din_valid(l3_valid),
        .a3_0(a3[0]), .a3_1(a3[1]),
        .dout_valid(l4_valid),
        .a4_0(a4)
    );
    
    //==========================================================================
    // 分解 L5: a4(1/周期) �? a5(1/2周期)
    //==========================================================================
    wire l5_valid;
    wire signed [INTERNAL_WIDTH-1:0] a5;
    
    decompose_L5 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .COEF_FRAC(COEF_FRAC),
        .DEC_H0(DEC_H0), .DEC_H1(DEC_H1), .DEC_H2(DEC_H2), .DEC_H3(DEC_H3),
        .DEC_H4(DEC_H4), .DEC_H5(DEC_H5), .DEC_H6(DEC_H6), .DEC_H7(DEC_H7)
    ) u_decompose_L5 (
        .clk(clk), .rst_n(rst_n),
        .din_valid(l4_valid),
        .a4_in(a4),
        .dout_valid(l5_valid),
        .a5_out(a5)
    );
    
    //==========================================================================
    // 分解 L6: a5(1/2周期) �? a6(1/4周期)
    //==========================================================================
    wire l6_valid;
    wire signed [INTERNAL_WIDTH-1:0] a6;
    
    decompose_L6 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .COEF_FRAC(COEF_FRAC),
        .DEC_H0(DEC_H0), .DEC_H1(DEC_H1), .DEC_H2(DEC_H2), .DEC_H3(DEC_H3),
        .DEC_H4(DEC_H4), .DEC_H5(DEC_H5), .DEC_H6(DEC_H6), .DEC_H7(DEC_H7)
    ) u_decompose_L6 (
        .clk(clk), .rst_n(rst_n),
        .din_valid(l5_valid),
        .a5_in(a5),
        .dout_valid(l6_valid),
        .a6_out(a6)
    );
    
    //==========================================================================
    // 分解 L7: a6(1/4周期) �? a7(1/8周期)
    //==========================================================================
    wire l7_valid;
    wire signed [INTERNAL_WIDTH-1:0] a7;
    
    decompose_L7 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .COEF_FRAC(COEF_FRAC),
        .DEC_H0(DEC_H0), .DEC_H1(DEC_H1), .DEC_H2(DEC_H2), .DEC_H3(DEC_H3),
        .DEC_H4(DEC_H4), .DEC_H5(DEC_H5), .DEC_H6(DEC_H6), .DEC_H7(DEC_H7)
    ) u_decompose_L7 (
        .clk(clk), .rst_n(rst_n),
        .din_valid(l6_valid),
        .a6_in(a6),
        .dout_valid(l7_valid),
        .a7_out(a7)
    );
    
    //==========================================================================
    // 重构 L7: a7 �? r6
    //==========================================================================
    wire r7_valid;
    wire signed [INTERNAL_WIDTH-1:0] r6;
    
    reconstruct_L7 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .COEF_FRAC(COEF_FRAC),
        .REC_H0(REC_H0), .REC_H1(REC_H1), .REC_H2(REC_H2), .REC_H3(REC_H3),
        .REC_H4(REC_H4), .REC_H5(REC_H5), .REC_H6(REC_H6), .REC_H7(REC_H7)
    ) u_reconstruct_L7 (
        .clk(clk), .rst_n(rst_n),
        .din_valid(l7_valid),
        .a7_in(a7),
        .dout_valid(r7_valid),
        .r6_out(r6)
    );
    
    //==========================================================================
    // 重构 L6: r6 �? r5
    //==========================================================================
    wire r6_valid;
    wire signed [INTERNAL_WIDTH-1:0] r5;
    
    reconstruct_L6 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .COEF_FRAC(COEF_FRAC),
        .REC_H0(REC_H0), .REC_H1(REC_H1), .REC_H2(REC_H2), .REC_H3(REC_H3),
        .REC_H4(REC_H4), .REC_H5(REC_H5), .REC_H6(REC_H6), .REC_H7(REC_H7)
    ) u_reconstruct_L6 (
        .clk(clk), .rst_n(rst_n),
        .din_valid(r7_valid),
        .r6_in(r6),
        .dout_valid(r6_valid),
        .r5_out(r5)
    );
    
    //==========================================================================
    // 重构 L5: r5 �? r4
    //==========================================================================
    wire r5_valid;
    wire signed [INTERNAL_WIDTH-1:0] r4;
    
    reconstruct_L5 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .COEF_FRAC(COEF_FRAC),
        .REC_H0(REC_H0), .REC_H1(REC_H1), .REC_H2(REC_H2), .REC_H3(REC_H3),
        .REC_H4(REC_H4), .REC_H5(REC_H5), .REC_H6(REC_H6), .REC_H7(REC_H7)
    ) u_reconstruct_L5 (
        .clk(clk), .rst_n(rst_n),
        .din_valid(r6_valid),
        .r5_in(r5),
        .dout_valid(r5_valid),
        .r4_out(r4)
    );
    
    //==========================================================================
    // 重构 L4: r4 �? r3
    //==========================================================================
    wire r4_valid;
    wire signed [INTERNAL_WIDTH-1:0] r3 [0:1];
    
    reconstruct_L4 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .COEF_FRAC(COEF_FRAC),
        .REC_H0(REC_H0), .REC_H1(REC_H1), .REC_H2(REC_H2), .REC_H3(REC_H3),
        .REC_H4(REC_H4), .REC_H5(REC_H5), .REC_H6(REC_H6), .REC_H7(REC_H7)
    ) u_reconstruct_L4 (
        .clk(clk), .rst_n(rst_n),
        .din_valid(r5_valid),
        .r4_in(r4),
        .dout_valid(r4_valid),
        .r3_0(r3[0]), .r3_1(r3[1])
    );
    
    //==========================================================================
    // 重构 L3: r3 �? r2
    //==========================================================================
    wire r3_valid;
    wire signed [INTERNAL_WIDTH-1:0] r2 [0:3];
    
    reconstruct_L3 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .COEF_FRAC(COEF_FRAC),
        .REC_H0(REC_H0), .REC_H1(REC_H1), .REC_H2(REC_H2), .REC_H3(REC_H3),
        .REC_H4(REC_H4), .REC_H5(REC_H5), .REC_H6(REC_H6), .REC_H7(REC_H7)
    ) u_reconstruct_L3 (
        .clk(clk), .rst_n(rst_n),
        .din_valid(r4_valid),
        .r3_0(r3[0]), .r3_1(r3[1]),
        .dout_valid(r3_valid),
        .r2_0(r2[0]), .r2_1(r2[1]), .r2_2(r2[2]), .r2_3(r2[3])
    );
    
    //==========================================================================
    // 重构 L2: r2 �? r1
    //==========================================================================
    wire r2_valid;
    wire signed [INTERNAL_WIDTH-1:0] r1 [0:7];
    
    reconstruct_L2 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .COEF_FRAC(COEF_FRAC),
        .REC_H0(REC_H0), .REC_H1(REC_H1), .REC_H2(REC_H2), .REC_H3(REC_H3),
        .REC_H4(REC_H4), .REC_H5(REC_H5), .REC_H6(REC_H6), .REC_H7(REC_H7)
    ) u_reconstruct_L2 (
        .clk(clk), .rst_n(rst_n),
        .din_valid(r3_valid),
        .r2_0(r2[0]), .r2_1(r2[1]), .r2_2(r2[2]), .r2_3(r2[3]),
        .dout_valid(r2_valid),
        .r1_0(r1[0]), .r1_1(r1[1]), .r1_2(r1[2]), .r1_3(r1[3]),
        .r1_4(r1[4]), .r1_5(r1[5]), .r1_6(r1[6]), .r1_7(r1[7])
    );
    
    //==========================================================================
    // 重构 L1: r1 �? baseline
    //==========================================================================
    wire r1_valid;
    wire signed [DATA_WIDTH-1:0] baseline_internal [0:15];
    
    reconstruct_L1 #(
        .DATA_WIDTH(DATA_WIDTH),
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .COEF_FRAC(COEF_FRAC),
        .REC_H0(REC_H0), .REC_H1(REC_H1), .REC_H2(REC_H2), .REC_H3(REC_H3),
        .REC_H4(REC_H4), .REC_H5(REC_H5), .REC_H6(REC_H6), .REC_H7(REC_H7)
    ) u_reconstruct_L1 (
        .clk(clk), .rst_n(rst_n),
        .din_valid(r2_valid),
        .r1_0(r1[0]), .r1_1(r1[1]), .r1_2(r1[2]), .r1_3(r1[3]),
        .r1_4(r1[4]), .r1_5(r1[5]), .r1_6(r1[6]), .r1_7(r1[7]),
        .dout_valid(r1_valid),
        .baseline_0(baseline_internal[0]),   .baseline_1(baseline_internal[1]),
        .baseline_2(baseline_internal[2]),   .baseline_3(baseline_internal[3]),
        .baseline_4(baseline_internal[4]),   .baseline_5(baseline_internal[5]),
        .baseline_6(baseline_internal[6]),   .baseline_7(baseline_internal[7]),
        .baseline_8(baseline_internal[8]),   .baseline_9(baseline_internal[9]),
        .baseline_10(baseline_internal[10]), .baseline_11(baseline_internal[11]),
        .baseline_12(baseline_internal[12]), .baseline_13(baseline_internal[13]),
        .baseline_14(baseline_internal[14]), .baseline_15(baseline_internal[15])
    );
    
    //==========================================================================
    // 输出打包与时序优�?
    // 为避免组合�?�辑过长导致时序不收敛，减法结果打一拍再输出
    //==========================================================================
    
    // baseline直接输出（已经是寄存器输出）
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : pack_baseline
            assign baseline[DATA_OUTPUT*(gi+1)-1 : DATA_OUTPUT*gi] = baseline_internal[gi];
        end
    endgenerate
    
    // 减法打一拍，优化时序
    reg signed [DATA_OUTPUT-1:0] signal_no_baseline_reg [0:15];
    reg baseline_valid_reg;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            baseline_valid_reg <= 0;
            for (i = 0; i < 16; i = i + 1) begin
                signal_no_baseline_reg[i] <= 0;
            end
        end else begin
            baseline_valid_reg <= r1_valid;
            for (i = 0; i < 16; i = i + 1) begin
                signal_no_baseline_reg[i] <= din_aligned[i] - baseline_internal[i];
            end
        end
    end
    
    assign baseline_valid = baseline_valid_reg;
    
    // 打包去除基线后的信号
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : pack_no_baseline
            assign signal_no_baseline[DATA_OUTPUT*(gi+1)-1 : DATA_OUTPUT*gi] = signal_no_baseline_reg[gi];
        end
    endgenerate

endmodule
