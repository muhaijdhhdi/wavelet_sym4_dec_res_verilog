//==============================================================================
// 小波分解 L2 模块
// 
// 功能：第二级分解，a1(8) → a2(4)
// 
// 流水线：
//   Stage 1: 乘法 → 寄存器
//   Stage 2: 加法 → 寄存器
//   Stage 3: 截断 → 输出寄存器
//
// 延迟：3周期
// 乘法器：4×8 = 32个
//has_data 确保前面已经有了一个周期的数据了，
//因此从第一次valid_in到L2 的dout_valid有4个周期延迟（1+3）
//==============================================================================

module decompose_L2 #(
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
    
    // 输入：8个a1系数 (Q25.23)
    input  wire                              din_valid,
    input  wire signed [INTERNAL_WIDTH-1:0]  a1_0,
    input  wire signed [INTERNAL_WIDTH-1:0]  a1_1,
    input  wire signed [INTERNAL_WIDTH-1:0]  a1_2,
    input  wire signed [INTERNAL_WIDTH-1:0]  a1_3,
    input  wire signed [INTERNAL_WIDTH-1:0]  a1_4,
    input  wire signed [INTERNAL_WIDTH-1:0]  a1_5,
    input  wire signed [INTERNAL_WIDTH-1:0]  a1_6,
    input  wire signed [INTERNAL_WIDTH-1:0]  a1_7,
    
    // 输出：4个a2系数 (Q25.23)
    output reg                               dout_valid,
    output reg  signed [INTERNAL_WIDTH-1:0]  a2_0,
    output reg  signed [INTERNAL_WIDTH-1:0]  a2_1,
    output reg  signed [INTERNAL_WIDTH-1:0]  a2_2,
    output reg  signed [INTERNAL_WIDTH-1:0]  a2_3
);

    //==========================================================================
    // 历史数据缓存
    //==========================================================================
    reg signed [INTERNAL_WIDTH-1:0] a1_hist [0:6];
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a1_hist[0] <= 0;
            a1_hist[1] <= 0;
            a1_hist[2] <= 0;
            a1_hist[3] <= 0;
            a1_hist[4] <= 0;
            a1_hist[5] <= 0;
            a1_hist[6] <= 0;
        end else if (din_valid) begin
            a1_hist[0] <= a1_7;
            a1_hist[1] <= a1_6;
            a1_hist[2] <= a1_5;
            a1_hist[3] <= a1_4;
            a1_hist[4] <= a1_3;
            a1_hist[5] <= a1_2;
            a1_hist[6] <= a1_1;
        end
    end
    
    //==========================================================================
    // Valid 流水线
    //==========================================================================
    reg valid_s1, valid_s2;
    reg has_data;//解决第一次valid时问题


    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            has_data <= 1'b0;//第一次有数据前为0
        end else if(din_valid) begin//直到有数据才保持为1
            has_data <= 1'b1;
        end
    end


    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s1 <= 0;
            valid_s2 <= 0;
            dout_valid <= 0;
        end else begin
            valid_s1 <= din_valid&has_data;
            valid_s2 <= valid_s1;
            dout_valid <= valid_s2;
        end
    end
    
    //==========================================================================
    // Stage 1: 乘法
    //==========================================================================
    localparam MULT_WIDTH = INTERNAL_WIDTH + COEF_WIDTH;
    
    reg signed [MULT_WIDTH-1:0] mult_s1 [0:3][0:7];
    
    always @(posedge clk) begin
        // 第0行
        mult_s1[0][0] <= a1_0        * $signed(DEC_H0);
        mult_s1[0][1] <= a1_hist[0]  * $signed(DEC_H1);
        mult_s1[0][2] <= a1_hist[1]  * $signed(DEC_H2);
        mult_s1[0][3] <= a1_hist[2]  * $signed(DEC_H3);
        mult_s1[0][4] <= a1_hist[3]  * $signed(DEC_H4);
        mult_s1[0][5] <= a1_hist[4]  * $signed(DEC_H5);
        mult_s1[0][6] <= a1_hist[5]  * $signed(DEC_H6);
        mult_s1[0][7] <= a1_hist[6]  * $signed(DEC_H7);
        
        // 第1行
        mult_s1[1][0] <= a1_2        * $signed(DEC_H0);
        mult_s1[1][1] <= a1_1        * $signed(DEC_H1);
        mult_s1[1][2] <= a1_0        * $signed(DEC_H2);
        mult_s1[1][3] <= a1_hist[0]  * $signed(DEC_H3);
        mult_s1[1][4] <= a1_hist[1]  * $signed(DEC_H4);
        mult_s1[1][5] <= a1_hist[2]  * $signed(DEC_H5);
        mult_s1[1][6] <= a1_hist[3]  * $signed(DEC_H6);
        mult_s1[1][7] <= a1_hist[4]  * $signed(DEC_H7);
        
        // 第2行
        mult_s1[2][0] <= a1_4        * $signed(DEC_H0);
        mult_s1[2][1] <= a1_3        * $signed(DEC_H1);
        mult_s1[2][2] <= a1_2        * $signed(DEC_H2);
        mult_s1[2][3] <= a1_1        * $signed(DEC_H3);
        mult_s1[2][4] <= a1_0        * $signed(DEC_H4);
        mult_s1[2][5] <= a1_hist[0]  * $signed(DEC_H5);
        mult_s1[2][6] <= a1_hist[1]  * $signed(DEC_H6);
        mult_s1[2][7] <= a1_hist[2]  * $signed(DEC_H7);
        
        // 第3行
        mult_s1[3][0] <= a1_6        * $signed(DEC_H0);
        mult_s1[3][1] <= a1_5        * $signed(DEC_H1);
        mult_s1[3][2] <= a1_4        * $signed(DEC_H2);
        mult_s1[3][3] <= a1_3        * $signed(DEC_H3);
        mult_s1[3][4] <= a1_2        * $signed(DEC_H4);
        mult_s1[3][5] <= a1_1        * $signed(DEC_H5);
        mult_s1[3][6] <= a1_0        * $signed(DEC_H6);
        mult_s1[3][7] <= a1_hist[0]  * $signed(DEC_H7);
    end
    
    //==========================================================================
    // Stage 2: 累加
    //==========================================================================
    reg signed [MULT_WIDTH+2:0] sum_s2 [0:3];
    
    always @(posedge clk) begin
        sum_s2[0] <= mult_s1[0][0] + mult_s1[0][1] + mult_s1[0][2] + mult_s1[0][3] +
                     mult_s1[0][4] + mult_s1[0][5] + mult_s1[0][6] + mult_s1[0][7];
        sum_s2[1] <= mult_s1[1][0] + mult_s1[1][1] + mult_s1[1][2] + mult_s1[1][3] +
                     mult_s1[1][4] + mult_s1[1][5] + mult_s1[1][6] + mult_s1[1][7];
        sum_s2[2] <= mult_s1[2][0] + mult_s1[2][1] + mult_s1[2][2] + mult_s1[2][3] +
                     mult_s1[2][4] + mult_s1[2][5] + mult_s1[2][6] + mult_s1[2][7];
        sum_s2[3] <= mult_s1[3][0] + mult_s1[3][1] + mult_s1[3][2] + mult_s1[3][3] +
                     mult_s1[3][4] + mult_s1[3][5] + mult_s1[3][6] + mult_s1[3][7];
    end
    
    //==========================================================================
    // Stage 3: 截断并输出
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a2_0 <= 0;
            a2_1 <= 0;
            a2_2 <= 0;
            a2_3 <= 0;
        end else begin
            a2_0 <= sum_s2[0][COEF_FRAC + INTERNAL_WIDTH - 1 : COEF_FRAC];
            a2_1 <= sum_s2[1][COEF_FRAC + INTERNAL_WIDTH - 1 : COEF_FRAC];
            a2_2 <= sum_s2[2][COEF_FRAC + INTERNAL_WIDTH - 1 : COEF_FRAC];
            a2_3 <= sum_s2[3][COEF_FRAC + INTERNAL_WIDTH - 1 : COEF_FRAC];
        end
    end

endmodule
