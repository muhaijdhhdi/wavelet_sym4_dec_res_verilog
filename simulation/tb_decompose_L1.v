`define VIVADO_SIM
`timescale 1ns / 1ps

`ifndef VIVADO_SIM
    `include "../baseLine/decompose_L1.v"
`endif

module tb_decompose_L1;
    parameter DATA_WIDTH = 16;
    parameter COEFF_WIDTH = 25;
    parameter INTERNAL_WIDTH = 48;

    reg clk;
    reg rst_n;
    reg din_valid;
    reg signed [DATA_WIDTH-1:0] din[0:15];

    wire dout_valid;
    wire signed [INTERNAL_WIDTH-1:0] a1[0:7];

    parameter T=10;
    parameter  DEC_H0 = 25'b1111101100100110101001111;  
    parameter  DEC_H1 = 25'b1111111000011010011100111;  
    parameter  DEC_H2 = 25'b0001111111011000111111000;  
    parameter  DEC_H3 = 25'b0011001101110000011101001;  
    parameter  DEC_H4 = 25'b0001001100010000000110100;  
    parameter  DEC_H5 = 25'b1111100110100110011000110;  
    parameter  DEC_H6 = 25'b1111111100110001011111110;  
    parameter  DEC_H7 = 25'b0000001000001111111100011; 


    parameter  REC_H0 = DEC_H7;
    parameter  REC_H1 = DEC_H6;
    parameter  REC_H2 = DEC_H5;
    parameter  REC_H3 = DEC_H4;
    parameter  REC_H4 = DEC_H3;
    parameter  REC_H5 = DEC_H2;
    parameter  REC_H6 = DEC_H1;
    parameter  REC_H7 = DEC_H0;

decompose_L1 #(
        
        .DEC_H0( DEC_H0), 
        .DEC_H1( DEC_H1),
        .DEC_H2( DEC_H2),
        .DEC_H3( DEC_H3),
        .DEC_H4( DEC_H4),
        .DEC_H5( DEC_H5),
        .DEC_H6( DEC_H6),
        .DEC_H7( DEC_H7)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .din_valid(din_valid),
       
        .din_0(din[0]),   .din_1(din[1]),   .din_2(din[2]),   .din_3(din[3]),
        .din_4(din[4]),   .din_5(din[5]),   .din_6(din[6]),   .din_7(din[7]),
        .din_8(din[8]),   .din_9(din[9]),   .din_10(din[10]), .din_11(din[11]),
        .din_12(din[12]), .din_13(din[13]), .din_14(din[14]), .din_15(din[15]),
        
        .dout_valid(dout_valid),
        .a1_0(a1[0]), .a1_1(a1[1]), .a1_2(a1[2]), .a1_3(a1[3]),
        .a1_4(a1[4]), .a1_5(a1[5]), .a1_6(a1[6]), .a1_7(a1[7])
    );

    always #(T/2) clk = ~clk;

    integer i;
    integer scan_ret;
    integer file_handle;
    initial begin
        $display("Simulation start...");
        clk=0;rst_n=0;din_valid=0;
        for (i=0;i<16;i=i+1) begin
            din[i]=0;
        end
       
       //打开文件
        file_handle = $fopen("D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/x_input.txt", "r");
        if (file_handle == 0) begin
            $display("ERROR: Can not open x_input.txt");
            $finish;
        end

        #(10*T);
        rst_n=1;

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
        #200; // 等待流水线排�?
        $fclose(file_handle);
        $finish;
    end

`ifndef VIVADO_SIM
    initial begin
    $dumpfile("waveform/tb_decompose_L1.vcd");
    $dumpvars(0, tb_decompose_L1); 
end
`endif

    integer out_file;
    initial out_file = $fopen("D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/a1_output.txt", "w");

always @(posedge clk) begin
    if (dout_valid) begin
        // �? 8 路并行数据写入文件，用�?�号或空格分�?
        $fdisplay(out_file, "%h,%h,%h,%h,%h,%h,%h,%h", 
                  a1[0], a1[1], a1[2], a1[3], a1[4], a1[5], a1[6], a1[7]);
    end
end

endmodule 