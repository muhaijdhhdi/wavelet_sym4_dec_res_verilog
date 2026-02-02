//==============================================================================
// 小波重构 L4 模块
// 
// 功能：第四级重构，r4 → r3
// 
// 流水线：
//   Stage 1: 乘法 → 寄存器
//   Stage 2: 加法 → 寄存器
//   Stage 3: 截断 → 输出寄存器
//
// 数据率：
//   - 输入：每1周期1个r4
//   - 输出：每1周期2个r3
//
// 延迟：3周期
// 乘法器：2×4 = 8个
//valid_in->valid_out延迟：3+3=6
//==============================================================================

module reconstruct_L4 #(
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
    
    // 输入：1个r4系数，每周期1个
    input  wire                              din_valid,
    input  wire signed [INTERNAL_WIDTH-1:0]  r4_in,
    
    // 输出：2个r3系数，每周期2个
    output reg                               dout_valid,
    output reg  signed [INTERNAL_WIDTH-1:0]  r3_0,
    output reg  signed [INTERNAL_WIDTH-1:0]  r3_1
);
    //==========================================================================
    //新增等待延迟
    reg [2:0] has_data;//等待延迟

    always@(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            has_data <= 0;
        end else begin
            if(din_valid) begin
                has_data <= {has_data[1:0],1'b1};
            end else begin
                has_data <= {has_data[1:0],1'b0};
            end
        end
    end

    //==========================================================================
    // 历史数据缓存
    //==========================================================================
    reg signed [INTERNAL_WIDTH-1:0] r4_hist [0:2];
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r4_hist[0] <= 0; r4_hist[1] <= 0; r4_hist[2] <= 0;
        end else if (din_valid) begin
            r4_hist[2] <= r4_hist[1];
            r4_hist[1] <= r4_hist[0];
            r4_hist[0] <= r4_in;
        end
    end
    
    //==========================================================================
    // Valid 流水线
    //==========================================================================
    reg valid_s1, valid_s2;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s1 <= 0;
            valid_s2 <= 0;
            dout_valid <= 0;
        end else begin
            valid_s1 <= din_valid&has_data[2];
            valid_s2 <= valid_s1;
            dout_valid <= valid_s2;
        end
    end
    
    //==========================================================================
    // Stage 1: 乘法
    //==========================================================================
    localparam MULT_WIDTH = INTERNAL_WIDTH + COEF_WIDTH;
    
    reg signed [MULT_WIDTH-1:0] mult_even_s1 [0:3];
    reg signed [MULT_WIDTH-1:0] mult_odd_s1 [0:3];
    
    always @(posedge clk) begin
        mult_even_s1[0] <= r4_in       * $signed(REC_H0);
        mult_even_s1[1] <= r4_hist[0]  * $signed(REC_H2);
        mult_even_s1[2] <= r4_hist[1]  * $signed(REC_H4);
        mult_even_s1[3] <= r4_hist[2]  * $signed(REC_H6);
        
        mult_odd_s1[0] <= r4_in       * $signed(REC_H1);
        mult_odd_s1[1] <= r4_hist[0]  * $signed(REC_H3);
        mult_odd_s1[2] <= r4_hist[1]  * $signed(REC_H5);
        mult_odd_s1[3] <= r4_hist[2]  * $signed(REC_H7);
    end
    
    //==========================================================================
    // Stage 2: 累加
    //==========================================================================
    reg signed [MULT_WIDTH+1:0] sum_even_s2, sum_odd_s2;
    
    always @(posedge clk) begin
        sum_even_s2 <= mult_even_s1[0] + mult_even_s1[1] + mult_even_s1[2] + mult_even_s1[3];
        sum_odd_s2  <= mult_odd_s1[0]  + mult_odd_s1[1]  + mult_odd_s1[2]  + mult_odd_s1[3];
    end
    
    //==========================================================================
    // Stage 3: 截断并输出
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r3_0 <= 0;
            r3_1 <= 0;
        end else begin
            r3_0 <= sum_even_s2[COEF_FRAC + INTERNAL_WIDTH - 1 : COEF_FRAC];
            r3_1 <= sum_odd_s2[COEF_FRAC + INTERNAL_WIDTH - 1 : COEF_FRAC];
        end
    end

endmodule
