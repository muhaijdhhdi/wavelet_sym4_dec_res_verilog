//==============================================================================
// 小波分解 L1 模块
// 
// 功能：第一级分解，x(16) → a1(8)
// 
// 矩阵运算：
//   a1 = X * H
//   其中 X 是 8×8 矩阵（由当前和历史x组成），H 是 8×1 滤波器系数向量
//
// 流水线：
//   Stage 1: 乘法 → 寄存器
//   Stage 2: 加法 → 寄存器
//   Stage 3: 截断 → 输出寄存器
//
// 延迟：3周期
// 乘法器：8×8 = 64个
//has_data 确保前面已经有了一个周期的数据了，因此从第一次valid_in到L1 的dout_valid有4个周期延迟（1+3）
//==============================================================================

module decompose_L1 #(
    parameter DATA_WIDTH     = 16,
    parameter COEF_WIDTH     = 25,
    parameter INTERNAL_WIDTH = 48,
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
    
    // 输入：16个并行采样点 (Q16.0)
    input  wire                              din_valid,
    input  wire signed [DATA_WIDTH-1:0]      din_0,
    input  wire signed [DATA_WIDTH-1:0]      din_1,
    input  wire signed [DATA_WIDTH-1:0]      din_2,
    input  wire signed [DATA_WIDTH-1:0]      din_3,
    input  wire signed [DATA_WIDTH-1:0]      din_4,
    input  wire signed [DATA_WIDTH-1:0]      din_5,
    input  wire signed [DATA_WIDTH-1:0]      din_6,
    input  wire signed [DATA_WIDTH-1:0]      din_7,
    input  wire signed [DATA_WIDTH-1:0]      din_8,
    input  wire signed [DATA_WIDTH-1:0]      din_9,
    input  wire signed [DATA_WIDTH-1:0]      din_10,
    input  wire signed [DATA_WIDTH-1:0]      din_11,
    input  wire signed [DATA_WIDTH-1:0]      din_12,
    input  wire signed [DATA_WIDTH-1:0]      din_13,
    input  wire signed [DATA_WIDTH-1:0]      din_14,
    input  wire signed [DATA_WIDTH-1:0]      din_15,
    
    // 输出：8个a1系数 (Q25.23)
    output reg                               dout_valid,
    output reg  signed [INTERNAL_WIDTH-1:0]  a1_0,
    output reg  signed [INTERNAL_WIDTH-1:0]  a1_1,
    output reg  signed [INTERNAL_WIDTH-1:0]  a1_2,
    output reg  signed [INTERNAL_WIDTH-1:0]  a1_3,
    output reg  signed [INTERNAL_WIDTH-1:0]  a1_4,
    output reg  signed [INTERNAL_WIDTH-1:0]  a1_5,
    output reg  signed [INTERNAL_WIDTH-1:0]  a1_6,
    output reg  signed [INTERNAL_WIDTH-1:0]  a1_7
);

    //==========================================================================
    // 历史数据缓存：需要x[-1]到x[-7]
    //==========================================================================
    reg signed [DATA_WIDTH-1:0] x_hist [0:6];
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_hist[0] <= 0;
            x_hist[1] <= 0;
            x_hist[2] <= 0;
            x_hist[3] <= 0;
            x_hist[4] <= 0;
            x_hist[5] <= 0;
            x_hist[6] <= 0;
        end else if (din_valid) begin
            x_hist[0] <= din_15;
            x_hist[1] <= din_14;
            x_hist[2] <= din_13;
            x_hist[3] <= din_12;
            x_hist[4] <= din_11;
            x_hist[5] <= din_10;
            x_hist[6] <= din_9;
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
            valid_s1 <= din_valid&&has_data;
            valid_s2 <= valid_s1;
            dout_valid <= valid_s2;
        end
    end
    
    //==========================================================================
    // Stage 1: 乘法 (64个乘法器)
    //==========================================================================
    localparam MULT_WIDTH = DATA_WIDTH + COEF_WIDTH;  // 41位
    
    reg signed [MULT_WIDTH-1:0] mult_s1 [0:7][0:7];
    
    always @(posedge clk) begin
        // 第0行
        mult_s1[0][0] <= $signed(din_0)     * $signed(DEC_H0);
        mult_s1[0][1] <= $signed(x_hist[0]) * $signed(DEC_H1);
        mult_s1[0][2] <= $signed(x_hist[1]) * $signed(DEC_H2);
        mult_s1[0][3] <= $signed(x_hist[2]) * $signed(DEC_H3);
        mult_s1[0][4] <= $signed(x_hist[3]) * $signed(DEC_H4);
        mult_s1[0][5] <= $signed(x_hist[4]) * $signed(DEC_H5);
        mult_s1[0][6] <= $signed(x_hist[5]) * $signed(DEC_H6);
        mult_s1[0][7] <= $signed(x_hist[6]) * $signed(DEC_H7);
        
        // 第1行
        mult_s1[1][0] <= $signed(din_2)     * $signed(DEC_H0);
        mult_s1[1][1] <= $signed(din_1)     * $signed(DEC_H1);
        mult_s1[1][2] <= $signed(din_0)     * $signed(DEC_H2);
        mult_s1[1][3] <= $signed(x_hist[0]) * $signed(DEC_H3);
        mult_s1[1][4] <= $signed(x_hist[1]) * $signed(DEC_H4);
        mult_s1[1][5] <= $signed(x_hist[2]) * $signed(DEC_H5);
        mult_s1[1][6] <= $signed(x_hist[3]) * $signed(DEC_H6);
        mult_s1[1][7] <= $signed(x_hist[4]) * $signed(DEC_H7);
        
        // 第2行
        mult_s1[2][0] <= $signed(din_4)     * $signed(DEC_H0);
        mult_s1[2][1] <= $signed(din_3)     * $signed(DEC_H1);
        mult_s1[2][2] <= $signed(din_2)     * $signed(DEC_H2);
        mult_s1[2][3] <= $signed(din_1)     * $signed(DEC_H3);
        mult_s1[2][4] <= $signed(din_0)     * $signed(DEC_H4);
        mult_s1[2][5] <= $signed(x_hist[0]) * $signed(DEC_H5);
        mult_s1[2][6] <= $signed(x_hist[1]) * $signed(DEC_H6);
        mult_s1[2][7] <= $signed(x_hist[2]) * $signed(DEC_H7);
        
        // 第3行
        mult_s1[3][0] <= $signed(din_6)     * $signed(DEC_H0);
        mult_s1[3][1] <= $signed(din_5)     * $signed(DEC_H1);
        mult_s1[3][2] <= $signed(din_4)     * $signed(DEC_H2);
        mult_s1[3][3] <= $signed(din_3)     * $signed(DEC_H3);
        mult_s1[3][4] <= $signed(din_2)     * $signed(DEC_H4);
        mult_s1[3][5] <= $signed(din_1)     * $signed(DEC_H5);
        mult_s1[3][6] <= $signed(din_0)     * $signed(DEC_H6);
        mult_s1[3][7] <= $signed(x_hist[0]) * $signed(DEC_H7);
        
        // 第4行
        mult_s1[4][0] <= $signed(din_8)  * $signed(DEC_H0);
        mult_s1[4][1] <= $signed(din_7)  * $signed(DEC_H1);
        mult_s1[4][2] <= $signed(din_6)  * $signed(DEC_H2);
        mult_s1[4][3] <= $signed(din_5)  * $signed(DEC_H3);
        mult_s1[4][4] <= $signed(din_4)  * $signed(DEC_H4);
        mult_s1[4][5] <= $signed(din_3)  * $signed(DEC_H5);
        mult_s1[4][6] <= $signed(din_2)  * $signed(DEC_H6);
        mult_s1[4][7] <= $signed(din_1)  * $signed(DEC_H7);
        
        // 第5行
        mult_s1[5][0] <= $signed(din_10) * $signed(DEC_H0);
        mult_s1[5][1] <= $signed(din_9)  * $signed(DEC_H1);
        mult_s1[5][2] <= $signed(din_8)  * $signed(DEC_H2);
        mult_s1[5][3] <= $signed(din_7)  * $signed(DEC_H3);
        mult_s1[5][4] <= $signed(din_6)  * $signed(DEC_H4);
        mult_s1[5][5] <= $signed(din_5)  * $signed(DEC_H5);
        mult_s1[5][6] <= $signed(din_4)  * $signed(DEC_H6);
        mult_s1[5][7] <= $signed(din_3)  * $signed(DEC_H7);
        
        // 第6行
        mult_s1[6][0] <= $signed(din_12) * $signed(DEC_H0);
        mult_s1[6][1] <= $signed(din_11) * $signed(DEC_H1);
        mult_s1[6][2] <= $signed(din_10) * $signed(DEC_H2);
        mult_s1[6][3] <= $signed(din_9)  * $signed(DEC_H3);
        mult_s1[6][4] <= $signed(din_8)  * $signed(DEC_H4);
        mult_s1[6][5] <= $signed(din_7)  * $signed(DEC_H5);
        mult_s1[6][6] <= $signed(din_6)  * $signed(DEC_H6);
        mult_s1[6][7] <= $signed(din_5)  * $signed(DEC_H7);
        
        // 第7行
        mult_s1[7][0] <= $signed(din_14) * $signed(DEC_H0);
        mult_s1[7][1] <= $signed(din_13) * $signed(DEC_H1);
        mult_s1[7][2] <= $signed(din_12) * $signed(DEC_H2);
        mult_s1[7][3] <= $signed(din_11) * $signed(DEC_H3);
        mult_s1[7][4] <= $signed(din_10) * $signed(DEC_H4);
        mult_s1[7][5] <= $signed(din_9)  * $signed(DEC_H5);
        mult_s1[7][6] <= $signed(din_8)  * $signed(DEC_H6);
        mult_s1[7][7] <= $signed(din_7)  * $signed(DEC_H7);
    end
    
    //==========================================================================
    // Stage 2: 累加
    //==========================================================================
    reg signed [INTERNAL_WIDTH-1:0] sum_s2 [0:7];
    
    always @(posedge clk) begin
        sum_s2[0] <= mult_s1[0][0] + mult_s1[0][1] + mult_s1[0][2] + mult_s1[0][3] +
                     mult_s1[0][4] + mult_s1[0][5] + mult_s1[0][6] + mult_s1[0][7];
        sum_s2[1] <= mult_s1[1][0] + mult_s1[1][1] + mult_s1[1][2] + mult_s1[1][3] +
                     mult_s1[1][4] + mult_s1[1][5] + mult_s1[1][6] + mult_s1[1][7];
        sum_s2[2] <= mult_s1[2][0] + mult_s1[2][1] + mult_s1[2][2] + mult_s1[2][3] +
                     mult_s1[2][4] + mult_s1[2][5] + mult_s1[2][6] + mult_s1[2][7];
        sum_s2[3] <= mult_s1[3][0] + mult_s1[3][1] + mult_s1[3][2] + mult_s1[3][3] +
                     mult_s1[3][4] + mult_s1[3][5] + mult_s1[3][6] + mult_s1[3][7];
        sum_s2[4] <= mult_s1[4][0] + mult_s1[4][1] + mult_s1[4][2] + mult_s1[4][3] +
                     mult_s1[4][4] + mult_s1[4][5] + mult_s1[4][6] + mult_s1[4][7];
        sum_s2[5] <= mult_s1[5][0] + mult_s1[5][1] + mult_s1[5][2] + mult_s1[5][3] +
                     mult_s1[5][4] + mult_s1[5][5] + mult_s1[5][6] + mult_s1[5][7];
        sum_s2[6] <= mult_s1[6][0] + mult_s1[6][1] + mult_s1[6][2] + mult_s1[6][3] +
                     mult_s1[6][4] + mult_s1[6][5] + mult_s1[6][6] + mult_s1[6][7];
        sum_s2[7] <= mult_s1[7][0] + mult_s1[7][1] + mult_s1[7][2] + mult_s1[7][3] +
                     mult_s1[7][4] + mult_s1[7][5] + mult_s1[7][6] + mult_s1[7][7];
    end
    
    //==========================================================================
    // Stage 3: 输出（L1不需要截断，因为输入是Q16.0，乘法后直接是Q25.23范围内）
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a1_0 <= 0;
            a1_1 <= 0;
            a1_2 <= 0;
            a1_3 <= 0;
            a1_4 <= 0;
            a1_5 <= 0;
            a1_6 <= 0;
            a1_7 <= 0;
        end else begin
            a1_0 <= sum_s2[0];
            a1_1 <= sum_s2[1];
            a1_2 <= sum_s2[2];
            a1_3 <= sum_s2[3];
            a1_4 <= sum_s2[4];
            a1_5 <= sum_s2[5];
            a1_6 <= sum_s2[6];
            a1_7 <= sum_s2[7];
        end
    end

endmodule
