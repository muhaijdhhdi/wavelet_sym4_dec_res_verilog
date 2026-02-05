`timescale 1ns/1ps
//`define  VIVADO_SIM
`ifndef VIVADO_SIM
    `include "../baseLine/wavelet_baseline_removal_top.v"
`endif 
module tb_baseline_removal_top;

    //==========================================================================
    // 1. 参数定义
    //==========================================================================
    parameter DATA_WIDTH  = 16;
    parameter DATA_OUTPUT = 17;
    parameter TOTAL_DELAY = 154; // 算法+物理延迟
    parameter T           = 10;  // 100MHz
    
    parameter IN_FILE  = "D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/x_input.txt";
    parameter OUT_BASE = "D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/baseline_output.txt";
    parameter OUT_CLEAN= "D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/clean_signal_output.txt";

    //==========================================================================
    // 2. 信号定义
    //==========================================================================
    reg clk;
    reg rst_n;

    // --- 输入信号 ---
    reg  din_valid;
    // 临时数组，用于fscanf读取
    reg signed [DATA_WIDTH-1:0] din_array [0:15]; 
    // 打包后的宽总线，连接IP
    wire [DATA_WIDTH*16-1:0]    din_packed;       

    // --- 输出信号 ---
    wire baseline_valid;
    wire [DATA_OUTPUT*16-1:0] baseline_packed;
    wire [DATA_OUTPUT*16-1:0] signal_no_baseline_packed;

    // 辅助解包数组，用于fwrite写入文件
    wire signed [DATA_OUTPUT-1:0] baseline_unpacked [0:15];
    wire signed [DATA_OUTPUT-1:0] signal_no_baseline_unpacked [0:15];

    // 文件句柄
    integer file_in, file_out_base, file_out_clean;
    integer scan_ret, i;

    //==========================================================================
    // 3. 时钟生成
    //==========================================================================
    initial begin
        clk = 0;
        forever #(T/2) clk = ~clk;
    end

    //==========================================================================
    // 4. 打包与解包逻辑 (连接 Testbench 数组 <-> IP 宽总线)
    //==========================================================================
    genvar gi;
    generate
        // Input Packing: Array -> Bus
        for (gi = 0; gi < 16; gi = gi + 1) begin : pack_input
            assign din_packed[DATA_WIDTH*(gi+1)-1 : DATA_WIDTH*gi] = din_array[gi];
        end

        // Output Unpacking: Bus -> Array
        for (gi = 0; gi < 16; gi = gi + 1) begin : unpack_output
            assign baseline_unpacked[gi]           = baseline_packed[DATA_OUTPUT*(gi+1)-1 : DATA_OUTPUT*gi];
            assign signal_no_baseline_unpacked[gi] = signal_no_baseline_packed[DATA_OUTPUT*(gi+1)-1 : DATA_OUTPUT*gi];
        end
    endgenerate

    //==========================================================================
    // 5. 实例化被测 IP (Device Under Test)
    //==========================================================================
    wavelet_baseline_removal_top #(
        .DATA_WIDTH(DATA_WIDTH),
        .TOTAL_DELAY(TOTAL_DELAY),
        .DATA_OUTPUT(DATA_OUTPUT)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .din_valid(din_valid),
        .din(din_packed),
        .baseline_valid(baseline_valid),
        .baseline(baseline_packed),
        .signal_no_baseline(signal_no_baseline_packed)
    );

    //==========================================================================
    // 6. 延迟计数器 (用于验证延迟是否符合预期)
    //==========================================================================
    reg [31:0] latency_cnt;
    reg        timer_en;
    reg        first_in_flag;  // 标记第一个输入
    reg        first_out_flag; // 标记第一个输出

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            latency_cnt    <= 0;
            timer_en       <= 0;
            first_in_flag  <= 0;
            first_out_flag <= 0;
        end else begin
            // 检测第一个有效输入，启动计数器，初始置1（消除 off-by-one）
            if (din_valid && !first_in_flag) begin
                timer_en      <= 1;
                latency_cnt   <= 1; 
                first_in_flag <= 1;
                $display("\n[Time %t] Input Stream Started...", $time);
            end
            else if (timer_en && !first_out_flag) begin
                latency_cnt <= latency_cnt + 1;
            end

            // 检测第一个有效输出，停止计数并打印
            if (baseline_valid && !first_out_flag) begin
                first_out_flag <= 1;
                $display("[Time %t] Output Stream Started!", $time);
                $display("--------------------------------------------------");
                $display("MEASURED LATENCY: %d Cycles", latency_cnt);
                $display("EXPECTED LATENCY: %d Cycles (TOTAL_DELAY + 1 reg)", TOTAL_DELAY + 1);
                $display("--------------------------------------------------\n");
            end
        end
    end

    //==========================================================================
    // 7. 主测试流程：读取输入文件
    //==========================================================================
    initial begin
        // 初始化
        rst_n = 0;
        din_valid = 0;
        for (i=0; i<16; i=i+1) din_array[i] = 0;

        // 打开文件
        file_in = $fopen(IN_FILE, "r");
        file_out_base = $fopen(OUT_BASE, "w");
        file_out_clean = $fopen(OUT_CLEAN, "w");

        if (file_in == 0) begin
            $display("ERROR: Cannot open input file: %s", IN_FILE);
            $finish;
        end

        // 复位释放
        #(10*T);
        rst_n = 1;
        #(2*T);

        $display("Reading data from file...");

        // 循环读取文件
        while (!$feof(file_in)) begin
            @(posedge clk);
            #0; // 稍微延迟一点进行读取和赋值，保证 setup time

            scan_ret = $fscanf(file_in, "%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h\n",
                din_array[0], din_array[1], din_array[2], din_array[3],
                din_array[4], din_array[5], din_array[6], din_array[7],
                din_array[8], din_array[9], din_array[10], din_array[11],
                din_array[12], din_array[13], din_array[14], din_array[15]);

            if (scan_ret == 16) begin
                din_valid <= 1;
            end else begin
                din_valid <= 0; // 读取失败或文件结束
            end
        end

        // 文件读完后，停止输入
        @(posedge clk);
        din_valid <= 0;
        $display("Input file read complete. Waiting for pipeline to flush...");

        // 等待流水线排空 (例如 200 个周期，足够覆盖 155 延迟)
        #(200*T);
        
        // 关闭文件并结束仿真
        $fclose(file_in);
        $fclose(file_out_base);
        $fclose(file_out_clean);
        $display("Simulation Finished. Results saved to txt files.");
        $finish;
    end

    //==========================================================================
    // 8. 结果保存流程：写入输出文件
    //==========================================================================
    always @(posedge clk) begin
        if (baseline_valid) begin
            // 写入 Baseline
            $fdisplay(file_out_base, "%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h",
                baseline_unpacked[0], baseline_unpacked[1], baseline_unpacked[2], baseline_unpacked[3],
                baseline_unpacked[4], baseline_unpacked[5], baseline_unpacked[6], baseline_unpacked[7],
                baseline_unpacked[8], baseline_unpacked[9], baseline_unpacked[10], baseline_unpacked[11],
                baseline_unpacked[12], baseline_unpacked[13], baseline_unpacked[14], baseline_unpacked[15]);
            
            // 写入 Clean Signal
            $fdisplay(file_out_clean, "%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h",
                signal_no_baseline_unpacked[0], signal_no_baseline_unpacked[1], 
                signal_no_baseline_unpacked[2], signal_no_baseline_unpacked[3],
                signal_no_baseline_unpacked[4], signal_no_baseline_unpacked[5], 
                signal_no_baseline_unpacked[6], signal_no_baseline_unpacked[7],
                signal_no_baseline_unpacked[8], signal_no_baseline_unpacked[9], 
                signal_no_baseline_unpacked[10], signal_no_baseline_unpacked[11],
                signal_no_baseline_unpacked[12], signal_no_baseline_unpacked[13], 
                signal_no_baseline_unpacked[14], signal_no_baseline_unpacked[15]);
        end
    end
`ifndef VIVADO_SIM
    initial begin
        $dumpfile("waveform/tb_baseline_removal_top.vcd");
        $dumpvars(0, tb_baseline_removal_top); 
    end
`endif
endmodule