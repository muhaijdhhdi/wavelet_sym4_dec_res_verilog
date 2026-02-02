//==============================================================================
// 小波分解 L3 模块
// 
// 功能：第三级分解，a2(4) → a3(2)
// 
// 流水线：
//   Stage 1: 乘法 → 寄存器
//   Stage 2: 加法 → 寄存器
//   Stage 3: 截断 → 输出寄存器
//
// 延迟：3周期
// 乘法器：2×8 = 16个
//valid_in->valid_out 延迟5个周期（2+3）
//==============================================================================

module decompose_L3 #(
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
    
    // 输入：4个a2系数 (Q25.23)
    input  wire                              din_valid,
    input  wire signed [INTERNAL_WIDTH-1:0]  a2_0,
    input  wire signed [INTERNAL_WIDTH-1:0]  a2_1,
    input  wire signed [INTERNAL_WIDTH-1:0]  a2_2,
    input  wire signed [INTERNAL_WIDTH-1:0]  a2_3,
    
    // 输出：2个a3系数 (Q25.23)
    output reg                               dout_valid,
    output reg  signed [INTERNAL_WIDTH-1:0]  a3_0,
    output reg  signed [INTERNAL_WIDTH-1:0]  a3_1
);

    //==========================================================================
    // 历史数据缓存：需要2周期的历史
    //==========================================================================
    reg signed [INTERNAL_WIDTH-1:0] a2_hist_1 [0:3];
    reg signed [INTERNAL_WIDTH-1:0] a2_hist_2 [0:3];
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a2_hist_1[0] <= 0; a2_hist_1[1] <= 0; a2_hist_1[2] <= 0; a2_hist_1[3] <= 0;
            a2_hist_2[0] <= 0; a2_hist_2[1] <= 0; a2_hist_2[2] <= 0; a2_hist_2[3] <= 0;
        end else if (din_valid) begin
            a2_hist_2[0] <= a2_hist_1[0]; a2_hist_2[1] <= a2_hist_1[1];
            a2_hist_2[2] <= a2_hist_1[2]; a2_hist_2[3] <= a2_hist_1[3];
            a2_hist_1[0] <= a2_3; a2_hist_1[1] <= a2_2;
            a2_hist_1[2] <= a2_1; a2_hist_1[3] <= a2_0;
        end
    end
    
    // 别名
    wire signed [INTERNAL_WIDTH-1:0] a2_m1 = a2_hist_1[0];
    wire signed [INTERNAL_WIDTH-1:0] a2_m2 = a2_hist_1[1];
    wire signed [INTERNAL_WIDTH-1:0] a2_m3 = a2_hist_1[2];
    wire signed [INTERNAL_WIDTH-1:0] a2_m4 = a2_hist_1[3];
    wire signed [INTERNAL_WIDTH-1:0] a2_m5 = a2_hist_2[0];
    wire signed [INTERNAL_WIDTH-1:0] a2_m6 = a2_hist_2[1];
    wire signed [INTERNAL_WIDTH-1:0] a2_m7 = a2_hist_2[2];
    
    //==========================================================================
    // Valid 流水线
    //==========================================================================
    reg valid_s1, valid_s2;
    
    reg [1:0]has_data;//解决第一次valid时问题


    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            has_data <= 2'b00;//第一次有数据前为0
        end else if(din_valid) begin//直到有数据才保持为1
            has_data <= {has_data[0],1'b1};
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s1 <= 0;
            valid_s2 <= 0;
            dout_valid <= 0;
        end else begin
            valid_s1 <= din_valid&has_data[1];
            valid_s2 <= valid_s1;
            dout_valid <= valid_s2;
        end
    end
    
    //==========================================================================
    // Stage 1: 乘法
    //==========================================================================
    localparam MULT_WIDTH = INTERNAL_WIDTH + COEF_WIDTH;
    
    reg signed [MULT_WIDTH-1:0] mult_s1 [0:1][0:7];
    
    always @(posedge clk) begin
        // 第0行
        mult_s1[0][0] <= a2_0  * $signed(DEC_H0);
        mult_s1[0][1] <= a2_m1 * $signed(DEC_H1);
        mult_s1[0][2] <= a2_m2 * $signed(DEC_H2);
        mult_s1[0][3] <= a2_m3 * $signed(DEC_H3);
        mult_s1[0][4] <= a2_m4 * $signed(DEC_H4);
        mult_s1[0][5] <= a2_m5 * $signed(DEC_H5);
        mult_s1[0][6] <= a2_m6 * $signed(DEC_H6);
        mult_s1[0][7] <= a2_m7 * $signed(DEC_H7);
        
        // 第1行
        mult_s1[1][0] <= a2_2  * $signed(DEC_H0);
        mult_s1[1][1] <= a2_1  * $signed(DEC_H1);
        mult_s1[1][2] <= a2_0  * $signed(DEC_H2);
        mult_s1[1][3] <= a2_m1 * $signed(DEC_H3);
        mult_s1[1][4] <= a2_m2 * $signed(DEC_H4);
        mult_s1[1][5] <= a2_m3 * $signed(DEC_H5);
        mult_s1[1][6] <= a2_m4 * $signed(DEC_H6);
        mult_s1[1][7] <= a2_m5 * $signed(DEC_H7);
    end
    
    //==========================================================================
    // Stage 2: 累加
    //==========================================================================
    reg signed [MULT_WIDTH+2:0] sum_s2 [0:1];
    
    always @(posedge clk) begin
        sum_s2[0] <= mult_s1[0][0] + mult_s1[0][1] + mult_s1[0][2] + mult_s1[0][3] +
                     mult_s1[0][4] + mult_s1[0][5] + mult_s1[0][6] + mult_s1[0][7];
        sum_s2[1] <= mult_s1[1][0] + mult_s1[1][1] + mult_s1[1][2] + mult_s1[1][3] +
                     mult_s1[1][4] + mult_s1[1][5] + mult_s1[1][6] + mult_s1[1][7];
    end
    
    //==========================================================================
    // Stage 3: 截断并输出
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a3_0 <= 0;
            a3_1 <= 0;
        end else begin
            a3_0 <= sum_s2[0][COEF_FRAC + INTERNAL_WIDTH - 1 : COEF_FRAC];
            a3_1 <= sum_s2[1][COEF_FRAC + INTERNAL_WIDTH - 1 : COEF_FRAC];
        end
    end

endmodule
