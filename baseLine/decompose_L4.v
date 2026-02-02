//==============================================================================
// 小波分解 L4 模块
// 
// 功能：第四级分解，a3(2) → a4(1)
// 
// 流水线：
//   Stage 1: 乘法 → 寄存器
//   Stage 2: 加法 → 寄存器
//   Stage 3: 截断 → 输出寄存器
//
// 延迟：3周期
// 乘法器：1×8 = 8个
//valid_in->valid_out 延迟7个周期（3+4）
//==============================================================================

module decompose_L4 #(
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
    
    // 输入：2个a3系数 (Q25.23)
    input  wire                              din_valid,
    input  wire signed [INTERNAL_WIDTH-1:0]  a3_0,
    input  wire signed [INTERNAL_WIDTH-1:0]  a3_1,
    
    // 输出：1个a4系数 (Q25.23)
    output reg                               dout_valid,
    output reg  signed [INTERNAL_WIDTH-1:0]  a4_0
);

    //==========================================================================
    // 历史数据缓存：需要4周期的历史
    //==========================================================================
    reg signed [INTERNAL_WIDTH-1:0] a3_hist [0:6];
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a3_hist[0] <= 0; a3_hist[1] <= 0; a3_hist[2] <= 0; a3_hist[3] <= 0;
            a3_hist[4] <= 0; a3_hist[5] <= 0; a3_hist[6] <= 0;
        end else if (din_valid) begin
            a3_hist[6] <= a3_hist[4];
            a3_hist[5] <= a3_hist[3];
            a3_hist[4] <= a3_hist[2];
            a3_hist[3] <= a3_hist[1];
            a3_hist[2] <= a3_hist[0];
            a3_hist[1] <= a3_0;
            a3_hist[0] <= a3_1;
        end
    end
    
    //==========================================================================
    // Valid 流水线
    //==========================================================================
    reg valid_s1, valid_s2;
    
    reg [3:0]has_data;//解决第一次valid时问题


    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            has_data <= 4'b0000;//第一次有数据前为0
        end else if(din_valid) begin//直到有数据才保持为1
            has_data <= {has_data[2:0],1'b1};
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s1 <= 0;
            valid_s2 <= 0;
            dout_valid <= 0;
        end else begin
            valid_s1 <= din_valid&has_data[3];
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
        mult_s1[0] <= a3_0        * $signed(DEC_H0);
        mult_s1[1] <= a3_hist[0]  * $signed(DEC_H1);
        mult_s1[2] <= a3_hist[1]  * $signed(DEC_H2);
        mult_s1[3] <= a3_hist[2]  * $signed(DEC_H3);
        mult_s1[4] <= a3_hist[3]  * $signed(DEC_H4);
        mult_s1[5] <= a3_hist[4]  * $signed(DEC_H5);
        mult_s1[6] <= a3_hist[5]  * $signed(DEC_H6);
        mult_s1[7] <= a3_hist[6]  * $signed(DEC_H7);
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
            a4_0 <= 0;
        end else begin
            a4_0 <= sum_s2[COEF_FRAC + INTERNAL_WIDTH - 1 : COEF_FRAC];
        end
    end

endmodule
