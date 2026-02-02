//==============================================================================
// 小波重构 L1 模块
// 
// 功能：第一级重构，r1 → baseline
// 
// 流水线：
//   Stage 1: 乘法 → 寄存器
//   Stage 2: 加法 → 寄存器
//   Stage 3: 截断 → 输出寄存器
//
// 数据率：
//   - 输入：每1周期8个r1
//   - 输出：每1周期16个baseline
//
// 延迟：3周期
// 乘法器：16×4 = 64个
//valid_in->valid_out延迟：3周期+1=4
//==============================================================================

module reconstruct_L1 #(
    parameter DATA_WIDTH     = 16,
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
    
    // 输入：8个r1系数，每周期8个
    input  wire                              din_valid,
    input  wire signed [INTERNAL_WIDTH-1:0]  r1_0,
    input  wire signed [INTERNAL_WIDTH-1:0]  r1_1,
    input  wire signed [INTERNAL_WIDTH-1:0]  r1_2,
    input  wire signed [INTERNAL_WIDTH-1:0]  r1_3,
    input  wire signed [INTERNAL_WIDTH-1:0]  r1_4,
    input  wire signed [INTERNAL_WIDTH-1:0]  r1_5,
    input  wire signed [INTERNAL_WIDTH-1:0]  r1_6,
    input  wire signed [INTERNAL_WIDTH-1:0]  r1_7,
    
    // 输出：16个baseline，每周期16个 (Q16.0)
    output reg                               dout_valid,
    output reg  signed [DATA_WIDTH-1:0]      baseline_0,
    output reg  signed [DATA_WIDTH-1:0]      baseline_1,
    output reg  signed [DATA_WIDTH-1:0]      baseline_2,
    output reg  signed [DATA_WIDTH-1:0]      baseline_3,
    output reg  signed [DATA_WIDTH-1:0]      baseline_4,
    output reg  signed [DATA_WIDTH-1:0]      baseline_5,
    output reg  signed [DATA_WIDTH-1:0]      baseline_6,
    output reg  signed [DATA_WIDTH-1:0]      baseline_7,
    output reg  signed [DATA_WIDTH-1:0]      baseline_8,
    output reg  signed [DATA_WIDTH-1:0]      baseline_9,
    output reg  signed [DATA_WIDTH-1:0]      baseline_10,
    output reg  signed [DATA_WIDTH-1:0]      baseline_11,
    output reg  signed [DATA_WIDTH-1:0]      baseline_12,
    output reg  signed [DATA_WIDTH-1:0]      baseline_13,
    output reg  signed [DATA_WIDTH-1:0]      baseline_14,
    output reg  signed [DATA_WIDTH-1:0]      baseline_15
);

    //==========================================================================
    // 历史数据缓存
    //==========================================================================
    reg signed [INTERNAL_WIDTH-1:0] r1_hist [0:2];
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r1_hist[0] <= 0; r1_hist[1] <= 0; r1_hist[2] <= 0;
        end else if (din_valid) begin
            r1_hist[0] <= r1_7; r1_hist[1] <= r1_6; r1_hist[2] <= r1_5;
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
    
    reg signed [MULT_WIDTH-1:0] mult_s1 [0:15][0:3];
    
    always @(posedge clk) begin
        // baseline_0
        mult_s1[0][0] <= r1_0       * $signed(REC_H0);
        mult_s1[0][1] <= r1_hist[0] * $signed(REC_H2);
        mult_s1[0][2] <= r1_hist[1] * $signed(REC_H4);
        mult_s1[0][3] <= r1_hist[2] * $signed(REC_H6);
        
        // baseline_1
        mult_s1[1][0] <= r1_0       * $signed(REC_H1);
        mult_s1[1][1] <= r1_hist[0] * $signed(REC_H3);
        mult_s1[1][2] <= r1_hist[1] * $signed(REC_H5);
        mult_s1[1][3] <= r1_hist[2] * $signed(REC_H7);
        
        // baseline_2
        mult_s1[2][0] <= r1_1       * $signed(REC_H0);
        mult_s1[2][1] <= r1_0 * $signed(REC_H2);
        mult_s1[2][2] <= r1_hist[0] * $signed(REC_H4);
        mult_s1[2][3] <= r1_hist[1] * $signed(REC_H6);
        
        // baseline_3
        mult_s1[3][0] <= r1_1       * $signed(REC_H1);
        mult_s1[3][1] <= r1_0 *     $signed(REC_H3);
        mult_s1[3][2] <= r1_hist[0] * $signed(REC_H5);
        mult_s1[3][3] <= r1_hist[1] * $signed(REC_H7);
        
        // baseline_4
        mult_s1[4][0] <= r1_2       * $signed(REC_H0);
        mult_s1[4][1] <= r1_1 * $signed(REC_H2);
        mult_s1[4][2] <= r1_0 * $signed(REC_H4);
        mult_s1[4][3] <= r1_hist[0] * $signed(REC_H6);
        
        // baseline_5
        mult_s1[5][0] <= r1_2       * $signed(REC_H1);
        mult_s1[5][1] <= r1_1 * $signed(REC_H3);
        mult_s1[5][2] <= r1_0 * $signed(REC_H5);
        mult_s1[5][3] <= r1_hist[0] * $signed(REC_H7);
        
        // baseline_6
        mult_s1[6][0] <= r1_3 * $signed(REC_H0);
        mult_s1[6][1] <= r1_2 * $signed(REC_H2);
        mult_s1[6][2] <= r1_1 * $signed(REC_H4);
        mult_s1[6][3] <= r1_0 * $signed(REC_H6);
        
        // baseline_7
        mult_s1[7][0] <=r1_3 * $signed(REC_H1);
        mult_s1[7][1] <=r1_2 * $signed(REC_H3);
        mult_s1[7][2] <=r1_1 * $signed(REC_H5);
        mult_s1[7][3] <=r1_0 * $signed(REC_H7);
        
        // baseline_8
        mult_s1[8][0] <= r1_4 * $signed(REC_H0);
        mult_s1[8][1] <= r1_3 * $signed(REC_H2);
        mult_s1[8][2] <= r1_2 * $signed(REC_H4);
        mult_s1[8][3] <= r1_1 * $signed(REC_H6);
        
        // baseline_9
        mult_s1[9][0] <=  r1_4 * $signed(REC_H1);
        mult_s1[9][1] <=  r1_3 * $signed(REC_H3);
        mult_s1[9][2] <=  r1_2 * $signed(REC_H5);
        mult_s1[9][3] <=  r1_1 * $signed(REC_H7);
        
        // baseline_10
        mult_s1[10][0] <=  r1_5 * $signed(REC_H0);
        mult_s1[10][1] <=  r1_4 * $signed(REC_H2);
        mult_s1[10][2] <=  r1_3 * $signed(REC_H4);
        mult_s1[10][3] <=  r1_2 * $signed(REC_H6);
        
        // baseline_11
        mult_s1[11][0] <= r1_5 * $signed(REC_H1);
        mult_s1[11][1] <= r1_4 * $signed(REC_H3);
        mult_s1[11][2] <= r1_3 * $signed(REC_H5);
        mult_s1[11][3] <= r1_2 * $signed(REC_H7);
        
        // baseline_12
        mult_s1[12][0] <=  r1_6 * $signed(REC_H0);
        mult_s1[12][1] <=  r1_5 * $signed(REC_H2);
        mult_s1[12][2] <=  r1_4 * $signed(REC_H4);
        mult_s1[12][3] <=  r1_3 * $signed(REC_H6);
        
        // baseline_13
        mult_s1[13][0] <= r1_6 * $signed(REC_H1);
        mult_s1[13][1] <= r1_5 * $signed(REC_H3);
        mult_s1[13][2] <= r1_4 * $signed(REC_H5);
        mult_s1[13][3] <= r1_3 * $signed(REC_H7);
        
        // baseline_14
        mult_s1[14][0] <= r1_7       * $signed(REC_H0);
        mult_s1[14][1] <= r1_6       * $signed(REC_H2);
        mult_s1[14][2] <= r1_5       * $signed(REC_H4);
        mult_s1[14][3] <= r1_4       * $signed(REC_H6);
        
        // baseline_15
        mult_s1[15][0] <= r1_7 * $signed(REC_H1);
        mult_s1[15][1] <= r1_6 * $signed(REC_H3);
        mult_s1[15][2] <= r1_5 * $signed(REC_H5);
        mult_s1[15][3] <= r1_4 * $signed(REC_H7);
    end
    
    //==========================================================================
    // Stage 2: 累加
    //==========================================================================
    reg signed [MULT_WIDTH+1:0] sum_s2 [0:15];
    
    always @(posedge clk) begin
        sum_s2[0]  <= mult_s1[0][0]  + mult_s1[0][1]  + mult_s1[0][2]  + mult_s1[0][3];
        sum_s2[1]  <= mult_s1[1][0]  + mult_s1[1][1]  + mult_s1[1][2]  + mult_s1[1][3];
        sum_s2[2]  <= mult_s1[2][0]  + mult_s1[2][1]  + mult_s1[2][2]  + mult_s1[2][3];
        sum_s2[3]  <= mult_s1[3][0]  + mult_s1[3][1]  + mult_s1[3][2]  + mult_s1[3][3];
        sum_s2[4]  <= mult_s1[4][0]  + mult_s1[4][1]  + mult_s1[4][2]  + mult_s1[4][3];
        sum_s2[5]  <= mult_s1[5][0]  + mult_s1[5][1]  + mult_s1[5][2]  + mult_s1[5][3];
        sum_s2[6]  <= mult_s1[6][0]  + mult_s1[6][1]  + mult_s1[6][2]  + mult_s1[6][3];
        sum_s2[7]  <= mult_s1[7][0]  + mult_s1[7][1]  + mult_s1[7][2]  + mult_s1[7][3];
        sum_s2[8]  <= mult_s1[8][0]  + mult_s1[8][1]  + mult_s1[8][2]  + mult_s1[8][3];
        sum_s2[9]  <= mult_s1[9][0]  + mult_s1[9][1]  + mult_s1[9][2]  + mult_s1[9][3];
        sum_s2[10] <= mult_s1[10][0] + mult_s1[10][1] + mult_s1[10][2] + mult_s1[10][3];
        sum_s2[11] <= mult_s1[11][0] + mult_s1[11][1] + mult_s1[11][2] + mult_s1[11][3];
        sum_s2[12] <= mult_s1[12][0] + mult_s1[12][1] + mult_s1[12][2] + mult_s1[12][3];
        sum_s2[13] <= mult_s1[13][0] + mult_s1[13][1] + mult_s1[13][2] + mult_s1[13][3];
        sum_s2[14] <= mult_s1[14][0] + mult_s1[14][1] + mult_s1[14][2] + mult_s1[14][3];
        sum_s2[15] <= mult_s1[15][0] + mult_s1[15][1] + mult_s1[15][2] + mult_s1[15][3];
    end
    
    //==========================================================================
    // Stage 3: 截断到Q16.0并输出
    //==========================================================================
    // 从Q27.46截断到Q16.0，需要右移46位，将小数位全部去掉
    parameter COFF_FRAC_ALL =COEF_FRAC*2 ;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            baseline_0  <= 0; baseline_1  <= 0; baseline_2  <= 0; baseline_3  <= 0;
            baseline_4  <= 0; baseline_5  <= 0; baseline_6  <= 0; baseline_7  <= 0;
            baseline_8  <= 0; baseline_9  <= 0; baseline_10 <= 0; baseline_11 <= 0;
            baseline_12 <= 0; baseline_13 <= 0; baseline_14 <= 0; baseline_15 <= 0;
        end else begin
            baseline_0  <= sum_s2[0][COFF_FRAC_ALL + DATA_WIDTH - 1 :COFF_FRAC_ALL];
            baseline_1  <= sum_s2[1][COFF_FRAC_ALL + DATA_WIDTH - 1 :COFF_FRAC_ALL];
            baseline_2  <= sum_s2[2][COFF_FRAC_ALL + DATA_WIDTH - 1 :COFF_FRAC_ALL];
            baseline_3  <= sum_s2[3][COFF_FRAC_ALL + DATA_WIDTH - 1 :COFF_FRAC_ALL];
            baseline_4  <= sum_s2[4][COFF_FRAC_ALL + DATA_WIDTH - 1 :COFF_FRAC_ALL];
            baseline_5  <= sum_s2[5][COFF_FRAC_ALL + DATA_WIDTH - 1 :COFF_FRAC_ALL];
            baseline_6  <= sum_s2[6][COFF_FRAC_ALL + DATA_WIDTH - 1 :COFF_FRAC_ALL];
            baseline_7  <= sum_s2[7][COFF_FRAC_ALL + DATA_WIDTH - 1 :COFF_FRAC_ALL];
            baseline_8  <= sum_s2[8][COFF_FRAC_ALL + DATA_WIDTH - 1 :COFF_FRAC_ALL];
            baseline_9  <= sum_s2[9][COFF_FRAC_ALL + DATA_WIDTH - 1 :COFF_FRAC_ALL];
            baseline_10 <= sum_s2[10][COFF_FRAC_ALL + DATA_WIDTH - 1 :COFF_FRAC_ALL];
            baseline_11 <= sum_s2[11][COFF_FRAC_ALL + DATA_WIDTH - 1 :COFF_FRAC_ALL];
            baseline_12 <= sum_s2[12][COFF_FRAC_ALL + DATA_WIDTH - 1 :COFF_FRAC_ALL];
            baseline_13 <= sum_s2[13][COFF_FRAC_ALL + DATA_WIDTH - 1 :COFF_FRAC_ALL];
            baseline_14 <= sum_s2[14][COFF_FRAC_ALL + DATA_WIDTH - 1 :COFF_FRAC_ALL];
            baseline_15 <= sum_s2[15][COFF_FRAC_ALL + DATA_WIDTH - 1 :COFF_FRAC_ALL];
        end
    end

endmodule
