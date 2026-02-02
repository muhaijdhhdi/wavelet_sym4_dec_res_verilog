`timescale 1ns / 1ps

// 包含两个模块的定义
//`define VIVADO_SIM
`ifndef VIVADO_SIM
    `include "../baseLine/decompose_L1.v"
    `include "../baseLine/decompose_L2.v"
`endif

module tb_decompose_L12;
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

    // L1 与 L2 之间的连接线
    wire l1_dout_valid;
    wire signed [INTERNAL_WIDTH-1:0] a1_bus[0:7];

    // L2 输出信号
    wire l2_dout_valid;
    wire signed [INTERNAL_WIDTH-1:0] a2_bus[0:3];

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
    // 1. 实例化 L1 模块
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
    // 2. 实例化 L2 模块 (直接对接 L1 的输出)
    // ---------------------------------------------------------
    decompose_L2 #(
        .INTERNAL_WIDTH(INTERNAL_WIDTH),
        .COEF_WIDTH(COEF_WIDTH),
        .DEC_H0(DEC_H0), .DEC_H1(DEC_H1), .DEC_H2(DEC_H2), .DEC_H3(DEC_H3),
        .DEC_H4(DEC_H4), .DEC_H5(DEC_H5), .DEC_H6(DEC_H6), .DEC_H7(DEC_H7)
    ) u_L2 (
        .clk(clk),
        .rst_n(rst_n),
        .din_valid(l1_dout_valid), // 关键：使用 L1 的 valid
        .a1_0(a1_bus[0]), .a1_1(a1_bus[1]), .a1_2(a1_bus[2]), .a1_3(a1_bus[3]),
        .a1_4(a1_bus[4]), .a1_5(a1_bus[5]), .a1_6(a1_bus[6]), .a1_7(a1_bus[7]),
        .dout_valid(l2_dout_valid),
        .a2_0(a2_bus[0]), .a2_1(a2_bus[1]), .a2_2(a2_bus[2]), .a2_3(a2_bus[3])
    );

    // 时钟与复位逻辑
    always #(T/2) clk = ~clk;

    integer i, file_handle, scan_ret;
    initial begin
        clk = 0; rst_n = 0; din_valid = 0;
        $display("Starting Decompose L1/L2 Testbench...");
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
                        din[12], din[13], din[14], din[15]);//从文件中读取数据
                    
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
        #200; // 等待流水线排空
        $fclose(file_handle);
        $finish;
    end

    // ---------------------------------------------------------
    // 3. 结果存储 (记录最终 L2 的输出)
    // ---------------------------------------------------------
    integer out_file;
    initial out_file = $fopen("D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/a2_output.txt", "w");

    always @(posedge clk) begin
        if (l2_dout_valid) begin
            $fdisplay(out_file, "%h,%h,%h,%h", a2_bus[0], a2_bus[1], a2_bus[2], a2_bus[3]);
        end
    end

`ifndef VIVADO_SIM
    initial begin
    $dumpfile("waveform/tb_decompose_L12.vcd");
    $dumpvars(0, tb_decompose_L12); 
end
`endif



endmodule