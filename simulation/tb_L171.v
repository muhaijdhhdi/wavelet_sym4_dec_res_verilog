`timescale 1ns/1ps
//`define CYCLE VIVADO_SIM

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

module tb_L171;
    // 全局参数
    parameter DATA_WIDTH     = 16;
    parameter COEF_WIDTH     = 25;
    parameter INTERNAL_WIDTH = 48;
    parameter COEF_FRAC      = 23; 
    parameter T              = 10;

    reg clk;
    reg rst_n;
    
    // L1 输入信号
    reg din_valid;
    reg signed [DATA_WIDTH-1:0] din[0:15];

    // --- 级联互连信号定义 ---
    
    // L1 输出 -> L2 输入 (8�?)
    wire l1_dout_valid;
    wire signed [INTERNAL_WIDTH-1:0] a1_bus[0:7];

    // L2 输出 -> L3 输入 (4�?)
    wire l2_dout_valid;
    wire signed [INTERNAL_WIDTH-1:0] a2_bus[0:3];

    // L3 输出 -> L4 输入 (2�?)
    wire l3_dout_valid;
    wire signed [INTERNAL_WIDTH-1:0] a3_bus[0:1];

    // L4 输出 (1�?)
    wire l4_dout_valid;
    wire signed [INTERNAL_WIDTH-1:0] a4_bus[0:0]; 

    wire l5_dout_valid;
    wire signed [INTERNAL_WIDTH-1:0] a5_bus[0:0];

    wire l6_dout_valid;
    wire signed [INTERNAL_WIDTH-1:0] a6_bus[0:0];

    wire l7_dout_valid;
    wire signed [INTERNAL_WIDTH-1:0] a7_bus[0:0];

    // 重构回传信号
    wire r6_dout_valid;
    wire signed [INTERNAL_WIDTH-1:0] r6_bus[0:0];

    wire r5_dout_valid;
    wire signed [INTERNAL_WIDTH-1:0] r5_bus[0:0];

    wire r4_dout_valid;
    wire signed [INTERNAL_WIDTH-1:0] r4_bus[0:0];

    wire r3_dout_valid;
    wire signed [INTERNAL_WIDTH-1:0] r3_bus[1:0];

    wire r2_dout_valid;
    wire signed [INTERNAL_WIDTH-1:0] r2_bus[3:0];

    wire r1_dout_valid;
    wire signed [INTERNAL_WIDTH-1:0] r1_bus[7:0];

    wire base_dout_valid;
    // 注意：reconstruct_L1输出的是DATA_WIDTH，这里�?�线定义的是INTERNAL_WIDTH
    // 连接时低位对齐，高位可能�?要注意截断或扩展，但在TB中接收�?�常没问�?
    wire signed [DATA_WIDTH-1:0] base_bus[15:0]; 

    // ------------------------

    // --- 小波分解系数 (Sym4) ---
    parameter DEC_H0 = 25'b1111101100100110101001111;  
    parameter DEC_H1 = 25'b1111111000011010011100111;  
    parameter DEC_H2 = 25'b0001111111011000111111000;  
    parameter DEC_H3 = 25'b0011001101110000011101001;  
    parameter DEC_H4 = 25'b0001001100010000000110100;  
    parameter DEC_H5 = 25'b1111100110100110011000110;  
    parameter DEC_H6 = 25'b1111111100110001011111110;  
    parameter DEC_H7 = 25'b0000001000001111111100011; 

    parameter REC_H0 = DEC_H7; 
    parameter REC_H1 = DEC_H6; 
    parameter REC_H2 = DEC_H5; 
    parameter REC_H3 = DEC_H4; 
    parameter REC_H4 = DEC_H3; 
    parameter REC_H5 = DEC_H2; 
    parameter REC_H6 = DEC_H1; 
    parameter REC_H7 = DEC_H0; 
    // ------------------------

    //--- 实例化各级分解模�? (保持原样) ---
    decompose_L1 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .COEF_FRAC(COEF_FRAC),
        .DEC_H0(DEC_H0), .DEC_H1(DEC_H1), .DEC_H2(DEC_H2), .DEC_H3(DEC_H3),
        .DEC_H4(DEC_H4), .DEC_H5(DEC_H5), .DEC_H6(DEC_H6), .DEC_H7(DEC_H7)
    ) u_decompose_L1 (
        .clk(clk), .rst_n(rst_n), .din_valid(din_valid),
        .din_0(din[0]), .din_1(din[1]), .din_2(din[2]), .din_3(din[3]),
        .din_4(din[4]), .din_5(din[5]), .din_6(din[6]), .din_7(din[7]),
        .din_8(din[8]), .din_9(din[9]), .din_10(din[10]), .din_11(din[11]),
        .din_12(din[12]), .din_13(din[13]), .din_14(din[14]), .din_15(din[15]),
        .dout_valid(l1_dout_valid),
        .a1_0(a1_bus[0]), .a1_1(a1_bus[1]), .a1_2(a1_bus[2]), .a1_3(a1_bus[3]),
        .a1_4(a1_bus[4]), .a1_5(a1_bus[5]), .a1_6(a1_bus[6]), .a1_7(a1_bus[7])
    );

    decompose_L2 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .COEF_FRAC(COEF_FRAC),
        .DEC_H0(DEC_H0), .DEC_H1(DEC_H1), .DEC_H2(DEC_H2), .DEC_H3(DEC_H3),
        .DEC_H4(DEC_H4), .DEC_H5(DEC_H5), .DEC_H6(DEC_H6), .DEC_H7(DEC_H7)
    ) u_decompose_L2 (
        .clk(clk), .rst_n(rst_n), .din_valid(l1_dout_valid),
        .a1_0(a1_bus[0]), .a1_1(a1_bus[1]), .a1_2(a1_bus[2]), .a1_3(a1_bus[3]),
        .a1_4(a1_bus[4]), .a1_5(a1_bus[5]), .a1_6(a1_bus[6]), .a1_7(a1_bus[7]),
        .dout_valid(l2_dout_valid),
        .a2_0(a2_bus[0]), .a2_1(a2_bus[1]), .a2_2(a2_bus[2]), .a2_3(a2_bus[3])
    );  

    decompose_L3 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .COEF_FRAC(COEF_FRAC),
        .DEC_H0(DEC_H0), .DEC_H1(DEC_H1), .DEC_H2(DEC_H2), .DEC_H3(DEC_H3),
        .DEC_H4(DEC_H4), .DEC_H5(DEC_H5), .DEC_H6(DEC_H6), .DEC_H7(DEC_H7)
    ) u_decompose_L3 (
        .clk(clk), .rst_n(rst_n), .din_valid(l2_dout_valid),
        .a2_0(a2_bus[0]), .a2_1(a2_bus[1]), .a2_2(a2_bus[2]), .a2_3(a2_bus[3]),
        .dout_valid(l3_dout_valid),
        .a3_0(a3_bus[0]), .a3_1(a3_bus[1])
    );

    decompose_L4 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .COEF_FRAC(COEF_FRAC),
        .DEC_H0(DEC_H0), .DEC_H1(DEC_H1), .DEC_H2(DEC_H2), .DEC_H3(DEC_H3),
        .DEC_H4(DEC_H4), .DEC_H5(DEC_H5), .DEC_H6(DEC_H6), .DEC_H7(DEC_H7)
    ) u_decompose_L4 (
        .clk(clk), .rst_n(rst_n), .din_valid(l3_dout_valid),
        .a3_0(a3_bus[0]), .a3_1(a3_bus[1]),
        .dout_valid(l4_dout_valid),
        .a4_0(a4_bus[0])
    );

    decompose_L5 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .COEF_FRAC(COEF_FRAC),
        .DEC_H0(DEC_H0), .DEC_H1(DEC_H1), .DEC_H2(DEC_H2), .DEC_H3(DEC_H3),
        .DEC_H4(DEC_H4), .DEC_H5(DEC_H5), .DEC_H6(DEC_H6), .DEC_H7(DEC_H7)
    ) u_decompose_L5 (
        .clk(clk), .rst_n(rst_n), .din_valid(l4_dout_valid),
        .a4_in(a4_bus[0]),
        .dout_valid(l5_dout_valid),
        .a5_out(a5_bus[0])
    );

    decompose_L6 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .COEF_FRAC(COEF_FRAC),
        .DEC_H0(DEC_H0), .DEC_H1(DEC_H1), .DEC_H2(DEC_H2), .DEC_H3(DEC_H3),
        .DEC_H4(DEC_H4), .DEC_H5(DEC_H5), .DEC_H6(DEC_H6), .DEC_H7(DEC_H7)
    ) u_decompose_L6 (
        .clk(clk), .rst_n(rst_n), .din_valid(l5_dout_valid),
        .a5_in(a5_bus[0]),
        .dout_valid(l6_dout_valid),
        .a6_out(a6_bus[0])
    );

    decompose_L7 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .COEF_FRAC(COEF_FRAC),
        .DEC_H0(DEC_H0), .DEC_H1(DEC_H1), .DEC_H2(DEC_H2), .DEC_H3(DEC_H3),
        .DEC_H4(DEC_H4), .DEC_H5(DEC_H5), .DEC_H6(DEC_H6), .DEC_H7(DEC_H7)
    ) u_decompose_L7 (
        .clk(clk), .rst_n(rst_n), .din_valid(l6_dout_valid),
        .a6_in(a6_bus[0]),
        .dout_valid(l7_dout_valid),
        .a7_out(a7_bus[0])
    );

    //--- 实例化各级重构模�? (已根据新接口修改) ---

    reconstruct_L7 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .COEF_FRAC(COEF_FRAC),
        .REC_H0(REC_H0), .REC_H1(REC_H1), .REC_H2(REC_H2), .REC_H3(REC_H3),
        .REC_H4(REC_H4), .REC_H5(REC_H5), .REC_H6(REC_H6), .REC_H7(REC_H7)
    ) u_reconstruct_L7 (
        .clk(clk),
        .rst_n(rst_n),
        .din_valid(l7_dout_valid),
        .a7_in(a7_bus[0]),
        .dout_valid(r6_dout_valid),
        .r6_out(r6_bus[0])
    );

    reconstruct_L6 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .COEF_FRAC(COEF_FRAC),
        .REC_H0(REC_H0), .REC_H1(REC_H1), .REC_H2(REC_H2), .REC_H3(REC_H3),
        .REC_H4(REC_H4), .REC_H5(REC_H5), .REC_H6(REC_H6), .REC_H7(REC_H7)
    ) u_reconstruct_L6 (
        .clk(clk),
        .rst_n(rst_n),
        .din_valid(r6_dout_valid),
        .r6_in(r6_bus[0]),
        .dout_valid(r5_dout_valid),
        .r5_out(r5_bus[0])
    );

    reconstruct_L5 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .COEF_FRAC(COEF_FRAC),
        .REC_H0(REC_H0), .REC_H1(REC_H1), .REC_H2(REC_H2), .REC_H3(REC_H3),
        .REC_H4(REC_H4), .REC_H5(REC_H5), .REC_H6(REC_H6), .REC_H7(REC_H7)
    ) u_reconstruct_L5 (
        .clk(clk),
        .rst_n(rst_n),
        .din_valid(r5_dout_valid),
        .r5_in(r5_bus[0]),
        .dout_valid(r4_dout_valid),
        .r4_out(r4_bus[0])
    );

    reconstruct_L4 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .COEF_FRAC(COEF_FRAC),
        .REC_H0(REC_H0), .REC_H1(REC_H1), .REC_H2(REC_H2), .REC_H3(REC_H3),
        .REC_H4(REC_H4), .REC_H5(REC_H5), .REC_H6(REC_H6), .REC_H7(REC_H7)
    ) u_reconstruct_L4 (
        .clk(clk),
        .rst_n(rst_n),
        .din_valid(r4_dout_valid),
        .r4_in(r4_bus[0]),
        .dout_valid(r3_dout_valid),
        // L4输出2个数据，映射�? r3_bus[0] �? r3_bus[1]
        .r3_0(r3_bus[0]), 
        .r3_1(r3_bus[1])
    );

    reconstruct_L3 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .COEF_FRAC(COEF_FRAC),
        .REC_H0(REC_H0), .REC_H1(REC_H1), .REC_H2(REC_H2), .REC_H3(REC_H3),
        .REC_H4(REC_H4), .REC_H5(REC_H5), .REC_H6(REC_H6), .REC_H7(REC_H7)
    ) u_reconstruct_L3 (
        .clk(clk),
        .rst_n(rst_n),
        .din_valid(r3_dout_valid),
        // L3输入2个数�?
        .r3_0(r3_bus[0]), 
        .r3_1(r3_bus[1]),
        .dout_valid(r2_dout_valid),
        // L3输出4个数据，映射�? r2_bus
        .r2_0(r2_bus[0]), .r2_1(r2_bus[1]), .r2_2(r2_bus[2]), .r2_3(r2_bus[3])
    );

    reconstruct_L2 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .COEF_FRAC(COEF_FRAC),
        .REC_H0(REC_H0), .REC_H1(REC_H1), .REC_H2(REC_H2), .REC_H3(REC_H3),
        .REC_H4(REC_H4), .REC_H5(REC_H5), .REC_H6(REC_H6), .REC_H7(REC_H7)
    ) u_reconstruct_L2 (
        .clk(clk),
        .rst_n(rst_n),
        .din_valid(r2_dout_valid),
        // L2输入4个数�?
        .r2_0(r2_bus[0]), .r2_1(r2_bus[1]), .r2_2(r2_bus[2]), .r2_3(r2_bus[3]),
        .dout_valid(r1_dout_valid),
        // L2输出8个数据，映射�? r1_bus
        .r1_0(r1_bus[0]), .r1_1(r1_bus[1]), .r1_2(r1_bus[2]), .r1_3(r1_bus[3]),
        .r1_4(r1_bus[4]), .r1_5(r1_bus[5]), .r1_6(r1_bus[6]), .r1_7(r1_bus[7])
    );

    reconstruct_L1 #(
        .DATA_WIDTH(DATA_WIDTH),
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .COEF_FRAC(COEF_FRAC),
        .REC_H0(REC_H0), .REC_H1(REC_H1), .REC_H2(REC_H2), .REC_H3(REC_H3),
        .REC_H4(REC_H4), .REC_H5(REC_H5), .REC_H6(REC_H6), .REC_H7(REC_H7)
    ) u_reconstruct_L1 (
        .clk(clk),
        .rst_n(rst_n),
        .din_valid(r1_dout_valid),
        // L1输入8个数�?
        .r1_0(r1_bus[0]), .r1_1(r1_bus[1]), .r1_2(r1_bus[2]), .r1_3(r1_bus[3]),
        .r1_4(r1_bus[4]), .r1_5(r1_bus[5]), .r1_6(r1_bus[6]), .r1_7(r1_bus[7]),
        .dout_valid(base_dout_valid),
        // L1输出16个数据，映射�? base_bus
        .baseline_0(base_bus[0]),  .baseline_1(base_bus[1]),  .baseline_2(base_bus[2]),  .baseline_3(base_bus[3]),
        .baseline_4(base_bus[4]),  .baseline_5(base_bus[5]),  .baseline_6(base_bus[6]),  .baseline_7(base_bus[7]),
        .baseline_8(base_bus[8]),  .baseline_9(base_bus[9]),  .baseline_10(base_bus[10]), .baseline_11(base_bus[11]),
        .baseline_12(base_bus[12]), .baseline_13(base_bus[13]), .baseline_14(base_bus[14]), .baseline_15(base_bus[15])
    );

    // 时钟生成
    initial begin
        clk = 0;
        forever #(T/2) clk = ~clk;
    end

    integer i, file_handle, scan_ret;
    initial begin
        clk = 0; rst_n = 0; din_valid = 0;
        $display("Starting Decompose L1->L7 + Reconstruct L7 Testbench...");
        for (i=0; i<16; i=i+1) din[i] = 0;

        file_handle = $fopen("D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/x_input.txt", "r");
        if (file_handle == 0) begin
            $display("ERROR: Cannot open x_input.txt");
            $finish;
        end

        #(10*T);
        rst_n = 1;

        while (!$feof(file_handle)) begin
                    @(posedge clk);
                    #0;
                    scan_ret=$fscanf(file_handle,"%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h\n",
                        din[0], din[1], din[2], din[3],
                        din[4], din[5], din[6], din[7],
                        din[8], din[9], din[10], din[11],
                        din[12], din[13], din[14], din[15]);
                    
                if(scan_ret==16)begin
                        din_valid=1;
                end
                else begin
                        $display("ERROR: fscanf failed to read 16 values");
                        din_valid=0;
                        #(10*T);
                        $finish;
                end
                #1;

            end

        @(posedge clk);
        din_valid = 0;
        #2000; // 适当增加等待时间，确保重构模块的数据能完全流�?
        $fclose(file_handle);
        $finish;
    end

    // ---------------------------------------------------------
    // 5. 结果存储 
    // ---------------------------------------------------------
    integer out_file_a1;
    integer out_file_a2;
    integer out_file_a3;
    integer out_file_a4;
    integer out_file_a5;
    integer out_file_a6;
    integer out_file_a7;
    // [新增] r6 输出文件句柄
    integer out_file_r6;
    integer out_file_r5;
    integer out_file_r4;
    integer out_file_r3;
    integer out_file_r2;
    integer out_file_r1;
    integer out_file_base;

    // 修改输出文件�?
    initial out_file_a1 = $fopen("D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/a1_output.txt", "w");
    initial out_file_a2 = $fopen("D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/a2_output.txt", "w");
    initial out_file_a3 = $fopen("D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/a3_output.txt", "w");
    initial out_file_a4 = $fopen("D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/a4_output.txt", "w");
    initial out_file_a5 = $fopen("D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/a5_output.txt", "w");
    initial out_file_a6 = $fopen("D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/a6_output.txt", "w");
    initial out_file_a7 = $fopen("D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/a7_output.txt", "w");

    initial out_file_r6 = $fopen("D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/r6_output.txt", "w");
    initial out_file_r5 = $fopen("D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/r5_output.txt", "w");
    initial out_file_r4 = $fopen("D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/r4_output.txt", "w");
    initial out_file_r3 = $fopen("D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/r3_output.txt", "w");
    initial out_file_r2 = $fopen("D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/r2_output.txt", "w");
    initial out_file_r1 = $fopen("D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/r1_output.txt", "w");
    initial out_file_base =$fopen("D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/base_output.txt","w");
    always @(posedge clk) begin
        if (l1_dout_valid) begin 
            $fdisplay(out_file_a1, "%h,%h,%h,%h,%h,%h,%h,%h",
                a1_bus[0], a1_bus[1], a1_bus[2], a1_bus[3],
                a1_bus[4], a1_bus[5], a1_bus[6], a1_bus[7]);
        end
        if (l2_dout_valid) begin 
            $fdisplay(out_file_a2, "%h,%h,%h,%h", 
            a2_bus[0], a2_bus[1], a2_bus[2], a2_bus[3]);
        end
        if (l3_dout_valid) begin 
            $fdisplay(out_file_a3, "%h,%h",
             a3_bus[0], a3_bus[1]);
        end
        if (l4_dout_valid) begin 
            $fdisplay(out_file_a4, "%h", a4_bus[0]);
        end
        if (l5_dout_valid) begin 
            $fdisplay(out_file_a5, "%h", a5_bus[0]);
        end
        if (l6_dout_valid) begin 
            $fdisplay(out_file_a6, "%h", a6_bus[0]);
        end
        if (l7_dout_valid) begin 
            $fdisplay(out_file_a7, "%h", a7_bus[0]);
        end
    
        if (r6_dout_valid) begin 
            $fdisplay(out_file_r6, "%h", r6_bus[0]); // 注意：这里使用了r6_bus[0]代替r6_out，因为TB中定义的是wire
        end

        if( r5_dout_valid) begin 
            $fdisplay(out_file_r5, "%h", r5_bus[0]);
        end

        if( r4_dout_valid) begin 
            $fdisplay(out_file_r4, "%h", r4_bus[0]);
        end

        if( r3_dout_valid) begin 
            $fdisplay(out_file_r3, "%h,%h", r3_bus[0], r3_bus[1]); // �?保存�?有分�?
        end
        if( r2_dout_valid) begin 
            $fdisplay(out_file_r2, "%h,%h,%h,%h", r2_bus[0], r2_bus[1], r2_bus[2], r2_bus[3]);
        end
        if( r1_dout_valid) begin 
            $fdisplay(out_file_r1, "%h,%h,%h,%h,%h,%h,%h,%h", 
                r1_bus[0], r1_bus[1], r1_bus[2], r1_bus[3],
                r1_bus[4], r1_bus[5], r1_bus[6], r1_bus[7]);
        end

        if (base_dout_valid) begin
            $fdisplay(out_file_base, "%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h",
                base_bus[0],  base_bus[1],  base_bus[2],  base_bus[3],
                base_bus[4],  base_bus[5],  base_bus[6],  base_bus[7],
                base_bus[8],  base_bus[9],  base_bus[10], base_bus[11],
                base_bus[12], base_bus[13], base_bus[14], base_bus[15]);
        end
        
    end

`ifndef VIVADO_SIM
    initial begin
        $dumpfile("waveform/tb_decompose_L171_REC.vcd");
        $dumpvars(0, tb_L171); 
    end
`endif

endmodule