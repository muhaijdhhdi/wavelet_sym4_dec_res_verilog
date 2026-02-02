//==============================================================================
// 小波分解 L5 模块
// 
// 功能：第五级分解，a4(1/周期) → a5(1/2周期)
// 
// 流水线：
//   Stage 1: 乘法 → 寄存器
//   Stage 2: 加法 → 寄存器
//   Stage 3: 截断 → 输出寄存器
//
// 特点：
//   - 输入：每周期1个a4
//   - 输出：每2周期1个a5（valid信号指示）
//
// 延迟：3周期
// 乘法器：1×8 = 8个
//din_valid->dout_valid延迟3+7=10个周期
//
//==============================================================================

module decompose_L5 #(
    parameter INTERNAL_WIDTH = 48,
    parameter COEF_WIDTH     = 25,
    parameter COEF_FRAC      = 23,
    
    // 分解滤波器系数
    parameter signed [COEF_WIDTH-1:0] DEC_H0 = 0,
    parameter signed [COEF_WIDTH-1:0] DEC_H1 = 0,
    parameter signed [COEF_WIDTH-1:0] DEC_H2 = 0,
    parameter signed [COEF_WIDTH-1:0] DEC_H3 = 0,
    parameter signed [COEF_WIDTH-1:0] DEC_H4 = 0,
    parameter signed [COEF_WIDTH-1:0] DEC_H5 = 0,
    parameter signed [COEF_WIDTH-1:0] DEC_H6 = 0,
    parameter signed [COEF_WIDTH-1:0] DEC_H7 = 0
)(
    input  wire                              clk,
    input  wire                              rst_n,
    
    // 输入：1个a4系数 (Q25.23)，每周期1个
    input  wire                              din_valid,
    input  wire signed [INTERNAL_WIDTH-1:0]  a4_in,
    
    // 输出：1个a5系数 (Q25.23)，每2周期1个
    output reg                               dout_valid,
    output reg  signed [INTERNAL_WIDTH-1:0]  a5_out
);

    reg [6:0]has_data;
    //==========================================================================
    // 下采样相位计数器
    //==========================================================================
    reg phase;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= 1'b0;
        end else if (din_valid&&has_data[6]) begin
            phase <= ~phase;
        end
    end
    
    //==========================================================================
    // 历史数据缓存
    //==========================================================================
    reg signed [INTERNAL_WIDTH-1:0] a4_hist [0:6];
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a4_hist[0] <= 0; a4_hist[1] <= 0; a4_hist[2] <= 0; a4_hist[3] <= 0;
            a4_hist[4] <= 0; a4_hist[5] <= 0; a4_hist[6] <= 0;
        end else if (din_valid) begin
            a4_hist[6] <= a4_hist[5];
            a4_hist[5] <= a4_hist[4];
            a4_hist[4] <= a4_hist[3];
            a4_hist[3] <= a4_hist[2];
            a4_hist[2] <= a4_hist[1];
            a4_hist[1] <= a4_hist[0];
            a4_hist[0] <= a4_in;
        end
    end
    
    //==========================================================================
    // Valid 流水线（只在phase=0时启动）
    //==========================================================================
    reg valid_s1, valid_s2;
    
    wire start_calc = din_valid && (phase == 1'b0);
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s1 <= 0;
            valid_s2 <= 0;
            dout_valid <= 0;
            has_data <= 7'b0000000;
        end else begin
            has_data <= {has_data[5:0], din_valid};
            valid_s1 <= start_calc&has_data[6];
            valid_s2 <= valid_s1;
            dout_valid <= valid_s2;
        end
    end
    
    //==========================================================================
    // Stage 1: 乘法
    //==========================================================================
    localparam MULT_WIDTH = INTERNAL_WIDTH + COEF_WIDTH;
    
    reg signed [MULT_WIDTH-1:0] mult_s1 [0:7];
    
    always @(posedge clk) begin
        mult_s1[0] <= a4_in       * $signed(DEC_H0);
        mult_s1[1] <= a4_hist[0]  * $signed(DEC_H1);
        mult_s1[2] <= a4_hist[1]  * $signed(DEC_H2);
        mult_s1[3] <= a4_hist[2]  * $signed(DEC_H3);
        mult_s1[4] <= a4_hist[3]  * $signed(DEC_H4);
        mult_s1[5] <= a4_hist[4]  * $signed(DEC_H5);
        mult_s1[6] <= a4_hist[5]  * $signed(DEC_H6);
        mult_s1[7] <= a4_hist[6]  * $signed(DEC_H7);
    end
    
    //==========================================================================
    // Stage 2: 累加
    //==========================================================================
    reg signed [MULT_WIDTH+2:0] sum_s2;
    
    always @(posedge clk) begin
        sum_s2 <= mult_s1[0] + mult_s1[1] + mult_s1[2] + mult_s1[3] +
                  mult_s1[4] + mult_s1[5] + mult_s1[6] + mult_s1[7];
    end
    
    //==========================================================================
    // Stage 3: 截断并输出
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a5_out <= 0;
        end else begin
            a5_out <= sum_s2[COEF_FRAC + INTERNAL_WIDTH - 1 : COEF_FRAC];
        end
    end

endmodule
