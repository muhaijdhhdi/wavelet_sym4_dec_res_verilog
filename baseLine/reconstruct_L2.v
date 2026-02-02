//==============================================================================
// 小波重构 L2 模块
// 
// 功能：第二级重构，r2 → r1
// 
// 流水线：
//   Stage 1: 乘法 → 寄存器
//   Stage 2: 加法 → 寄存器
//   Stage 3: 截断 → 输出寄存器
//
// 数据率：
//   - 输入：每1周期4个r2
//   - 输出：每1周期8个r1
//
// 延迟：3周期
// 乘法器：8×4 = 32个
//valid_in->valid_out延迟：3周期+1=4
//==============================================================================

module reconstruct_L2 #(
    parameter INTERNAL_WIDTH = 48,
    parameter COEF_WIDTH     = 25,
    parameter COEF_FRAC      = 23,
    
    // 重构滤波器系数
    parameter signed [COEF_WIDTH-1:0] REC_H0 = 0,
    parameter signed [COEF_WIDTH-1:0] REC_H1 = 0,
    parameter signed [COEF_WIDTH-1:0] REC_H2 = 0,
    parameter signed [COEF_WIDTH-1:0] REC_H3 = 0,
    parameter signed [COEF_WIDTH-1:0] REC_H4 = 0,
    parameter signed [COEF_WIDTH-1:0] REC_H5 = 0,
    parameter signed [COEF_WIDTH-1:0] REC_H6 = 0,
    parameter signed [COEF_WIDTH-1:0] REC_H7 = 0
)(
    input  wire                              clk,
    input  wire                              rst_n,
    
    // 输入：4个r2系数，每周期4个
    input  wire                              din_valid,
    input  wire signed [INTERNAL_WIDTH-1:0]  r2_0,
    input  wire signed [INTERNAL_WIDTH-1:0]  r2_1,
    input  wire signed [INTERNAL_WIDTH-1:0]  r2_2,
    input  wire signed [INTERNAL_WIDTH-1:0]  r2_3,
    
    // 输出：8个r1系数，每周期8个
    output reg                               dout_valid,
    output reg  signed [INTERNAL_WIDTH-1:0]  r1_0,
    output reg  signed [INTERNAL_WIDTH-1:0]  r1_1,
    output reg  signed [INTERNAL_WIDTH-1:0]  r1_2,
    output reg  signed [INTERNAL_WIDTH-1:0]  r1_3,
    output reg  signed [INTERNAL_WIDTH-1:0]  r1_4,
    output reg  signed [INTERNAL_WIDTH-1:0]  r1_5,
    output reg  signed [INTERNAL_WIDTH-1:0]  r1_6,
    output reg  signed [INTERNAL_WIDTH-1:0]  r1_7
);

    //==========================================================================
    // 历史数据缓存
    //==========================================================================
    reg signed [INTERNAL_WIDTH-1:0] r2_hist [0:2];
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r2_hist[0] <= 0; r2_hist[1] <= 0; r2_hist[2] <= 0;
        end else if (din_valid) begin
            r2_hist[0] <= r2_3; r2_hist[1] <= r2_2; r2_hist[2] <= r2_1; 
        end
    end
    
    //==========================================================================
    // Valid 流水线
    //==========================================================================
    reg valid_s1, valid_s2;
    reg has_data;//等待延迟 ;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            has_data <= 0;
        end else begin
            if(din_valid) begin
                has_data <= 1'b1;
            end
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
    
    reg signed [MULT_WIDTH-1:0] mult_s1 [0:7][0:3];
    
    always @(posedge clk) begin
        // r1_0
        mult_s1[0][0] <= r2_0       * $signed(REC_H0);
        mult_s1[0][1] <= r2_hist[0] * $signed(REC_H2);
        mult_s1[0][2] <= r2_hist[1] * $signed(REC_H4);
        mult_s1[0][3] <= r2_hist[2] * $signed(REC_H6);  // 简化：使用可用的历史
        
        // r1_1
        mult_s1[1][0] <= r2_0       * $signed(REC_H1);
        mult_s1[1][1] <= r2_hist[0] * $signed(REC_H3);
        mult_s1[1][2] <= r2_hist[1] * $signed(REC_H5);
        mult_s1[1][3] <= r2_hist[2] * $signed(REC_H7);
        
        // r1_2
        mult_s1[2][0] <= r2_1       * $signed(REC_H0);
        mult_s1[2][1] <= r2_0       * $signed(REC_H2);
        mult_s1[2][2] <= r2_hist[0] * $signed(REC_H4);
        mult_s1[2][3] <= r2_hist[1] * $signed(REC_H6);
        
        // r1_3
        mult_s1[3][0] <= r2_1       * $signed(REC_H1);
        mult_s1[3][1] <= r2_0       * $signed(REC_H3);
        mult_s1[3][2] <= r2_hist[0] * $signed(REC_H5);
        mult_s1[3][3] <= r2_hist[1] * $signed(REC_H7);
        
        // r1_4
        mult_s1[4][0] <= r2_2       * $signed(REC_H0);
        mult_s1[4][1] <= r2_1       * $signed(REC_H2);
        mult_s1[4][2] <= r2_0      * $signed(REC_H4);
        mult_s1[4][3] <= r2_hist[0] * $signed(REC_H6);
        
        // r1_5
        mult_s1[5][0] <= r2_2       * $signed(REC_H1);
        mult_s1[5][1] <= r2_1       * $signed(REC_H3);
        mult_s1[5][2] <= r2_0       * $signed(REC_H5);
        mult_s1[5][3] <= r2_hist[0] * $signed(REC_H7);
        
        // r1_6
        mult_s1[6][0] <= r2_3       * $signed(REC_H0);
        mult_s1[6][1] <= r2_2       * $signed(REC_H2);
        mult_s1[6][2] <= r2_1       * $signed(REC_H4);
        mult_s1[6][3] <= r2_0       * $signed(REC_H6);
        
        // r1_7
        mult_s1[7][0] <= r2_3       * $signed(REC_H1);
        mult_s1[7][1] <= r2_2       * $signed(REC_H3);
        mult_s1[7][2] <= r2_1       * $signed(REC_H5);
        mult_s1[7][3] <= r2_0       * $signed(REC_H7);
    end
    
    //==========================================================================
    // Stage 2: 累加
    //==========================================================================
    reg signed [MULT_WIDTH+1:0] sum_s2 [0:7];
    
    always @(posedge clk) begin
        sum_s2[0] <= mult_s1[0][0] + mult_s1[0][1] + mult_s1[0][2] + mult_s1[0][3];
        sum_s2[1] <= mult_s1[1][0] + mult_s1[1][1] + mult_s1[1][2] + mult_s1[1][3];
        sum_s2[2] <= mult_s1[2][0] + mult_s1[2][1] + mult_s1[2][2] + mult_s1[2][3];
        sum_s2[3] <= mult_s1[3][0] + mult_s1[3][1] + mult_s1[3][2] + mult_s1[3][3];
        sum_s2[4] <= mult_s1[4][0] + mult_s1[4][1] + mult_s1[4][2] + mult_s1[4][3];
        sum_s2[5] <= mult_s1[5][0] + mult_s1[5][1] + mult_s1[5][2] + mult_s1[5][3];
        sum_s2[6] <= mult_s1[6][0] + mult_s1[6][1] + mult_s1[6][2] + mult_s1[6][3];
        sum_s2[7] <= mult_s1[7][0] + mult_s1[7][1] + mult_s1[7][2] + mult_s1[7][3];
    end
    
    //==========================================================================
    // Stage 3: 截断并输出
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r1_0 <= 0; r1_1 <= 0; r1_2 <= 0; r1_3 <= 0;
            r1_4 <= 0; r1_5 <= 0; r1_6 <= 0; r1_7 <= 0;
        end else begin
            r1_0 <= sum_s2[0][COEF_FRAC + INTERNAL_WIDTH - 1 : COEF_FRAC];
            r1_1 <= sum_s2[1][COEF_FRAC + INTERNAL_WIDTH - 1 : COEF_FRAC];
            r1_2 <= sum_s2[2][COEF_FRAC + INTERNAL_WIDTH - 1 : COEF_FRAC];
            r1_3 <= sum_s2[3][COEF_FRAC + INTERNAL_WIDTH - 1 : COEF_FRAC];
            r1_4 <= sum_s2[4][COEF_FRAC + INTERNAL_WIDTH - 1 : COEF_FRAC];
            r1_5 <= sum_s2[5][COEF_FRAC + INTERNAL_WIDTH - 1 : COEF_FRAC];
            r1_6 <= sum_s2[6][COEF_FRAC + INTERNAL_WIDTH - 1 : COEF_FRAC];
            r1_7 <= sum_s2[7][COEF_FRAC + INTERNAL_WIDTH - 1 : COEF_FRAC];
        end
    end

endmodule
