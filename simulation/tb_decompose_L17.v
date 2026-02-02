`timescale 1ns / 1ps

// 包含所有层级的模块定义
`ifndef VIVADO_SIM
    `include "../baseLine/decompose_L1.v"
    `include "../baseLine/decompose_L2.v"
    `include "../baseLine/decompose_L3.v" // 假设你有这个文件
    `include "../baseLine/decompose_L4.v" // 假设你有这个文件
    `include "../baseLine/decompose_L5.v" // 假设你有这个文件
    `include "../baseLine/decompose_L6.v" // 假设你有这个
    `include "../baseLine/decompose_L7.v" // 假设你有这个文件

`endif

module tb_decompose_L17; // 模块名改为 L17
    // 全局参数
    parameter DATA_WIDTH     = 16;
    parameter COEF_WIDTH     = 25;
    parameter INTERNAL_WIDTH = 48;
    parameter T              = 10;

    reg clk;
    reg rst_n;
    
    // L1 输入信号
    reg din_valid;
    reg signed [DATA_WIDTH-1:0] din[0:15];

    // --- 级联互连信号定义 ---
    
    // L1 输出 -> L2 输入 (8路)
    wire l1_dout_valid;
    wire signed [INTERNAL_WIDTH-1:0] a1_bus[0:7];

    // L2 输出 -> L3 输入 (4路)
    wire l2_dout_valid;
    wire signed [INTERNAL_WIDTH-1:0] a2_bus[0:3];

    // L3 输出 -> L4 输入 (2路) [新增]
    wire l3_dout_valid;
    wire signed [INTERNAL_WIDTH-1:0] a3_bus[0:1];

    // L4 输出 (1路) [新增]
    wire l4_dout_valid;
    wire signed [INTERNAL_WIDTH-1:0] a4_bus[0:0]; // 定义为数组方便统一管理，实际只有 a4_0

    wire l5_dout_valid;
    wire signed [INTERNAL_WIDTH-1:0] a5_bus[0:0];

    wire l6_dout_valid;
    wire signed [INTERNAL_WIDTH-1:0] a6_bus[0:0];

    wire l7_dout_valid;
    wire signed [INTERNAL_WIDTH-1:0] a7_bus[0:0];

    // --- 小波系数 (Sym4) ---
    parameter DEC_H0 = 25'b1111101100100110101001111;  
    parameter DEC_H1 = 25'b1111111000011010011100111;  
    parameter DEC_H2 = 25'b0001111111011000111111000;  
    parameter DEC_H3 = 25'b0011001101110000011101001;  
    parameter DEC_H4 = 25'b0001001100010000000110100;  
    parameter DEC_H5 = 25'b1111100110100110011000110;  
    parameter DEC_H6 = 25'b1111111100110001011111110;  
    parameter DEC_H7 = 25'b0000001000001111111100011; 

    // ---------------------------------------------------------
    // 1. 实例化 L1 模块 (16 -> 8)
    // ---------------------------------------------------------
    decompose_L1 #(
        .DATA_WIDTH(DATA_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .DEC_H0(DEC_H0), .DEC_H1(DEC_H1), .DEC_H2(DEC_H2), .DEC_H3(DEC_H3),
        .DEC_H4(DEC_H4), .DEC_H5(DEC_H5), .DEC_H6(DEC_H6), .DEC_H7(DEC_H7)
    ) u_L1 (
        .clk(clk),
        .rst_n(rst_n),
        .din_valid(din_valid),
        .din_0(din[0]),   .din_1(din[1]),   .din_2(din[2]),   .din_3(din[3]),
        .din_4(din[4]),   .din_5(din[5]),   .din_6(din[6]),   .din_7(din[7]),
        .din_8(din[8]),   .din_9(din[9]),   .din_10(din[10]), .din_11(din[11]),
        .din_12(din[12]), .din_13(din[13]), .din_14(din[14]), .din_15(din[15]),
        .dout_valid(l1_dout_valid),
        .a1_0(a1_bus[0]), .a1_1(a1_bus[1]), .a1_2(a1_bus[2]), .a1_3(a1_bus[3]),
        .a1_4(a1_bus[4]), .a1_5(a1_bus[5]), .a1_6(a1_bus[6]), .a1_7(a1_bus[7])
    );

    // ---------------------------------------------------------
    // 2. 实例化 L2 模块 (8 -> 4)
    // ---------------------------------------------------------
    decompose_L2 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .DEC_H0(DEC_H0), .DEC_H1(DEC_H1), .DEC_H2(DEC_H2), .DEC_H3(DEC_H3),
        .DEC_H4(DEC_H4), .DEC_H5(DEC_H5), .DEC_H6(DEC_H6), .DEC_H7(DEC_H7)
    ) u_L2 (
        .clk(clk),
        .rst_n(rst_n),
        .din_valid(l1_dout_valid), // 级联：接 L1 valid
        .a1_0(a1_bus[0]), .a1_1(a1_bus[1]), .a1_2(a1_bus[2]), .a1_3(a1_bus[3]),
        .a1_4(a1_bus[4]), .a1_5(a1_bus[5]), .a1_6(a1_bus[6]), .a1_7(a1_bus[7]),
        .dout_valid(l2_dout_valid),
        .a2_0(a2_bus[0]), .a2_1(a2_bus[1]), .a2_2(a2_bus[2]), .a2_3(a2_bus[3])
    );

    // ---------------------------------------------------------
    // 3. 实例化 L3 模块 (4 -> 2) [新增]
    // ---------------------------------------------------------
    decompose_L3 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .DEC_H0(DEC_H0), .DEC_H1(DEC_H1), .DEC_H2(DEC_H2), .DEC_H3(DEC_H3),
        .DEC_H4(DEC_H4), .DEC_H5(DEC_H5), .DEC_H6(DEC_H6), .DEC_H7(DEC_H7)
    ) u_L3 (
        .clk(clk),
        .rst_n(rst_n),
        .din_valid(l2_dout_valid), // 级联：接 L2 valid
        // L3 的输入是 L2 的输出 a2_bus
        .a2_0(a2_bus[0]), 
        .a2_1(a2_bus[1]), 
        .a2_2(a2_bus[2]), 
        .a2_3(a2_bus[3]),
        // L3 的输出是 a3_bus (2路)
        .dout_valid(l3_dout_valid),
        .a3_0(a3_bus[0]), 
        .a3_1(a3_bus[1])
    );

    // ---------------------------------------------------------
    // 4. 实例化 L4 模块 (2 -> 1) [新增]
    // ---------------------------------------------------------
    decompose_L4 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .DEC_H0(DEC_H0), .DEC_H1(DEC_H1), .DEC_H2(DEC_H2), .DEC_H3(DEC_H3),
        .DEC_H4(DEC_H4), .DEC_H5(DEC_H5), .DEC_H6(DEC_H6), .DEC_H7(DEC_H7)
    ) u_L4 (
        .clk(clk),
        .rst_n(rst_n),
        .din_valid(l3_dout_valid), // 级联：接 L3 valid
        // L4 的输入是 L3 的输出 a3_bus
        .a3_0(a3_bus[0]), 
        .a3_1(a3_bus[1]),
        // L4 的输出是 a4_bus (1路)
        .dout_valid(l4_dout_valid),
        .a4_0(a4_bus[0])
    );


    // ---------------------------------------------------------
    // 5.实例化 L5 模块 (1 -> 1)
    // ---------------------------------------------------------

    decompose_L5 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .DEC_H0(DEC_H0), .DEC_H1(DEC_H1), .DEC_H2(DEC_H2), .DEC_H3(DEC_H3),
        .DEC_H4(DEC_H4), .DEC_H5(DEC_H5), .DEC_H6(DEC_H6), .DEC_H7(DEC_H7)
    ) u_L5 (
        .clk(clk),
        .rst_n(rst_n),
        .din_valid(l4_dout_valid), // 级联：接 L4 valid
        .a4_in(a4_bus[0]),
        .dout_valid(l5_dout_valid),
        .a5_out(a5_bus[0])
    );

    // ---------------------------------------------------------
    // 6.实例化 L6 模块 (1 -> 1)
    // ---------------------------------------------------------
    decompose_L6 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .DEC_H0(DEC_H0), .DEC_H1(DEC_H1), .DEC_H2(DEC_H2), .DEC_H3(DEC_H3),
        .DEC_H4(DEC_H4), .DEC_H5(DEC_H5), .DEC_H6(DEC_H6), .DEC_H7(DEC_H7)
    ) u_L6 (
        .clk(clk),
        .rst_n(rst_n),
        .din_valid(l5_dout_valid), // 级联：接 L5 valid
        .a5_in(a5_bus[0]),
        .dout_valid(l6_dout_valid),
        .a6_out(a6_bus[0])
    );
    // ---------------------------------------------------------
    // 7.实例化 L7 模块 (1 -> 1)
    // ---------------------------------------------------------
    decompose_L7 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .DEC_H0(DEC_H0), .DEC_H1(DEC_H1), .DEC_H2(DEC_H2), .DEC_H3(DEC_H3),
        .DEC_H4(DEC_H4), .DEC_H5(DEC_H5), .DEC_H6(DEC_H6), .DEC_H7(DEC_H7)
    ) u_L7 (
        .clk(clk),
        .rst_n(rst_n),
        .din_valid(l6_dout_valid), // 级联：接 L6 valid
        .a6_in(a6_bus[0]),
        .dout_valid(l7_dout_valid),
        .a7_out(a7_bus[0])
    );
    // ---------------------------------------------------------


    // 时钟与复位逻辑
    always #(T/2) clk = ~clk;

    integer i, file_handle, scan_ret;
    initial begin
        clk = 0; rst_n = 0; din_valid = 0;
        $display("Starting Decompose L1->L2->L3->L4 Testbench...");
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
        #500; // 增加等待时间，因为4级流水线延迟较大
        $fclose(file_handle);
        $finish;
    end

    // ---------------------------------------------------------
    // 5. 结果存储 (记录最终 L4 的输出)
    // ---------------------------------------------------------
    integer out_file_a1;
    integer out_file_a2;
    integer out_file_a3;
    integer out_file_a4;
    integer out_file_a5;
    integer out_file_a6;
    integer out_file_a7;



    // 修改输出文件名
    initial out_file_a1 = $fopen("D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/a1_output.txt", "w");
    initial out_file_a2 = $fopen("D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/a2_output.txt", "w");
    initial out_file_a3 = $fopen("D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/a3_output.txt", "w");
    initial out_file_a4 = $fopen("D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/a4_output.txt", "w");
    initial out_file_a5 = $fopen("D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/a5_output.txt", "w");
    initial out_file_a6 = $fopen("D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/a6_output.txt", "w");
    initial out_file_a7 = $fopen("D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/a7_output.txt", "w");

    always @(posedge clk) begin
        if (l1_dout_valid) begin // 只有当 L1 输出有效时才写入
            $fdisplay(out_file_a1, "%h,%h,%h,%h,%h,%h,%h,%h",
                a1_bus[0], a1_bus[1], a1_bus[2], a1_bus[3],
                a1_bus[4], a1_bus[5], a1_bus[6], a1_bus[7]);
        end
        if (l2_dout_valid) begin // 只有当 L2 输出有效时才写入
            $fdisplay(out_file_a2, "%h,%h,%h,%h", 
            a2_bus[0], a2_bus[1], a2_bus[2], a2_bus[3]);
        end
        if (l3_dout_valid) begin // 只有当 L3 输出有效时才写入
            $fdisplay(out_file_a3, "%h,%h",
             a3_bus[0], a3_bus[1]);
        end
        if (l4_dout_valid) begin // 只有当 L4 输出有效时才写入
            $fdisplay(out_file_a4, "%h", a4_bus[0]);
        end
        if (l5_dout_valid) begin // 只有当 L5 输出有效时才写入
            $fdisplay(out_file_a5, "%h", a5_bus[0]);
        end
        if (l6_dout_valid) begin // 只有当 L6 输出有效时才写入
            $fdisplay(out_file_a6, "%h", a6_bus[0]);
        end
        if (l7_dout_valid) begin // 只有当 L7 输出有效时才写入
            $fdisplay(out_file_a7, "%h", a7_bus[0]);
        end
    end

`ifndef VIVADO_SIM
    initial begin
    $dumpfile("waveform/tb_decompose_L17.vcd");
    $dumpvars(0, tb_decompose_L17); 
end
`endif

endmodule