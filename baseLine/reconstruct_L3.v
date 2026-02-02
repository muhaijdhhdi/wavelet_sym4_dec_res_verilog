//==============================================================================
// 小波重构 L3 模块
// 
// 功能：第三级重构，r3 → r2
// 
// 流水线：
//   Stage 1: 乘法 → 寄存器
//   Stage 2: 加法 → 寄存器
//   Stage 3: 截断 → 输出寄存器
//
// 数据率：
//   - 输入：每1周期2个r3
//   - 输出：每1周期4个r2
//
// 延迟：3周期
// 乘法器：4×4 = 16个
//valid_in->valid_out延迟：3+2=5周期
//==============================================================================

module reconstruct_L3 #(
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
    
    // 输入：2个r3系数，每周期2个
    input  wire                              din_valid,
    input  wire signed [INTERNAL_WIDTH-1:0]  r3_0,
    input  wire signed [INTERNAL_WIDTH-1:0]  r3_1,
    
    // 输出：4个r2系数，每周期4个
    output reg                               dout_valid,
    output reg  signed [INTERNAL_WIDTH-1:0]  r2_0,
    output reg  signed [INTERNAL_WIDTH-1:0]  r2_1,
    output reg  signed [INTERNAL_WIDTH-1:0]  r2_2,
    output reg  signed [INTERNAL_WIDTH-1:0]  r2_3
);

    //==========================================================================
    // 历史数据缓存
    //==========================================================================
    reg signed  [INTERNAL_WIDTH-1:0]r3_hist[0:2];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
           r3_hist[0]<=0;
           r3_hist[1]<=0;
           r3_hist[2]<=0;
        end else if (din_valid) begin
           r3_hist[0]<=r3_1;
           r3_hist[1]<=r3_0;
           r3_hist[2]<=r3_hist[0];
        end
    end
    
    //==========================================================================
    // Valid 流水线
    //==========================================================================
    reg valid_s1, valid_s2;
    reg [1:0] has_data;//等待延迟

    always@(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            has_data <= 0;
        end else begin
            if(din_valid) begin
                has_data <= {has_data[0],1'b1};
            end else begin
                has_data <= {has_data[0],1'b0};
            end
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
    
    // 4个输出各需要4个乘法
    reg signed [MULT_WIDTH-1:0] mult_s1 [0:3][0:3];
    
    always @(posedge clk) begin
       
        mult_s1[0][0] <= r3_0             * $signed(REC_H0);//r3[0]*h[0]
        mult_s1[0][1] <= r3_hist[0]       * $signed(REC_H2);//r3[-1]*h[2]
        mult_s1[0][2] <= r3_hist[1]       * $signed(REC_H4);//r3[-2]*h[4]
        mult_s1[0][3] <= r3_hist[2]       * $signed(REC_H6);//r3[-3]*h[6]

    
        mult_s1[1][0] <= r3_0           *$signed(REC_H1);//r3[0]*h[1]
        mult_s1[1][1] <= r3_hist[0]     * $signed(REC_H3);//r3[-1]*h[3]
        mult_s1[1][2] <= r3_hist[1]     * $signed(REC_H5);//r3[-2]*h[5]
        mult_s1[1][3] <= r3_hist[2]     * $signed(REC_H7);//r3[-3]*h[7]
        
     
        mult_s1[2][0] <= r3_1           * $signed(REC_H0);//r3[1]*h[0]
        mult_s1[2][1] <= r3_0           * $signed(REC_H2);//r3[0]*h[2]
        mult_s1[2][2] <= r3_hist[0]     * $signed(REC_H4);//r3[-1]*h[4]
        mult_s1[2][3] <= r3_hist[1]     * $signed(REC_H6);//r3[-2]*h[6]
        
      
        mult_s1[3][0] <= r3_1         * $signed(REC_H1);//r3[1]*h[1]
        mult_s1[3][1] <= r3_0         * $signed(REC_H3);//r3[0]*h[3]
        mult_s1[3][2] <= r3_hist[0]   * $signed(REC_H5);//r3[-1]*h[5]
        mult_s1[3][3] <= r3_hist[1]   * $signed(REC_H7);//r3[-2]*h[7]
    end
    
    //==========================================================================
    // Stage 2: 累加
    //==========================================================================
    reg signed [MULT_WIDTH+1:0] sum_s2 [0:3];
    
    always @(posedge clk) begin
        sum_s2[0] <= mult_s1[0][0] + mult_s1[0][1] + mult_s1[0][2] + mult_s1[0][3];
        sum_s2[1] <= mult_s1[1][0] + mult_s1[1][1] + mult_s1[1][2] + mult_s1[1][3];
        sum_s2[2] <= mult_s1[2][0] + mult_s1[2][1] + mult_s1[2][2] + mult_s1[2][3];
        sum_s2[3] <= mult_s1[3][0] + mult_s1[3][1] + mult_s1[3][2] + mult_s1[3][3];
    end
    
    //==========================================================================
    // Stage 3: 截断并输出
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r2_0 <= 0; r2_1 <= 0; r2_2 <= 0; r2_3 <= 0;
        end else begin
            r2_0 <= sum_s2[0][COEF_FRAC + INTERNAL_WIDTH - 1 : COEF_FRAC];
            r2_1 <= sum_s2[1][COEF_FRAC + INTERNAL_WIDTH - 1 : COEF_FRAC];
            r2_2 <= sum_s2[2][COEF_FRAC + INTERNAL_WIDTH - 1 : COEF_FRAC];
            r2_3 <= sum_s2[3][COEF_FRAC + INTERNAL_WIDTH - 1 : COEF_FRAC];
        end
    end

endmodule
