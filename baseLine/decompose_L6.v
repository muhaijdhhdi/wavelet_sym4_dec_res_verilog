//==============================================================================
// 小波分解 L6 模块
// 
// 功能：第六级分解，a5(1/2周期) → a6(1/4周期)
// 
// 流水线：
//   Stage 1: 乘法 → 寄存器
//   Stage 2: 加法 → 寄存器
//   Stage 3: 截断 → 输出寄存器
//
// 特点：
//   - 输入：每2周期1个a5（由din_valid指示）
//   - 输出：每4周期1个a6（由dout_valid指示）
//
// 延迟：3周期
// 乘法器：1×8 = 8个
//din_valid-dout_valid 3+14=17
//==============================================================================

module decompose_L6 #(
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
    
    // 输入：1个a5系数 (Q25.23)，每2周期1个
    input  wire                              din_valid,
    input  wire signed [INTERNAL_WIDTH-1:0]  a5_in,
    
    // 输出：1个a6系数 (Q25.23)，每4周期1个
    output reg                               dout_valid,
    output reg  signed [INTERNAL_WIDTH-1:0]  a6_out
);
     reg [13:0]has_data;
    //==========================================================================
    // 下采样相位计数器
    //==========================================================================
    reg phase;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= 1'b0;
        end else if (din_valid&has_data[13]) begin
            phase <= ~phase;
        end
    end
    
    //==========================================================================
    // 历史数据缓存
    //==========================================================================
    reg signed [INTERNAL_WIDTH-1:0] a5_hist [0:6];
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a5_hist[0] <= 0; a5_hist[1] <= 0; a5_hist[2] <= 0; a5_hist[3] <= 0;
            a5_hist[4] <= 0; a5_hist[5] <= 0; a5_hist[6] <= 0;
        end else if (din_valid) begin
            a5_hist[6] <= a5_hist[5];
            a5_hist[5] <= a5_hist[4];
            a5_hist[4] <= a5_hist[3];
            a5_hist[3] <= a5_hist[2];
            a5_hist[2] <= a5_hist[1];
            a5_hist[1] <= a5_hist[0];
            a5_hist[0] <= a5_in;
        end
    end
    
    //==========================================================================
    // Valid 流水线
    //==========================================================================
    reg valid_s1, valid_s2;
    wire start_calc = din_valid && (phase == 1'b0);
   
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s1 <= 0;
            valid_s2 <= 0;
            dout_valid <= 0;
            has_data <= 14'b00000000000000;
        end else begin
            has_data <= {has_data[12:0], din_valid};
            valid_s1 <= start_calc&has_data[13];
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
        mult_s1[0] <= a5_in       * $signed(DEC_H0);
        mult_s1[1] <= a5_hist[0]  * $signed(DEC_H1);
        mult_s1[2] <= a5_hist[1]  * $signed(DEC_H2);
        mult_s1[3] <= a5_hist[2]  * $signed(DEC_H3);
        mult_s1[4] <= a5_hist[3]  * $signed(DEC_H4);
        mult_s1[5] <= a5_hist[4]  * $signed(DEC_H5);
        mult_s1[6] <= a5_hist[5]  * $signed(DEC_H6);
        mult_s1[7] <= a5_hist[6]  * $signed(DEC_H7);
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
            a6_out <= 0;
        end else begin
            a6_out <= sum_s2[COEF_FRAC + INTERNAL_WIDTH - 1 : COEF_FRAC];
        end
    end

endmodule
