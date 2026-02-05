//==============================================================================
// 小波重构 L6 模块
// 
// 功能：第六级重构，r6 → r5
// 
// 流水线：
//   Stage 1: curr锁存（din_valid时）
//   Stage 2: 乘法 → 寄存器
//   Stage 3: 加法 → 寄存器
//   Stage 4: 截断 → 输出寄存器
//
// 数据率：
//   - 输入：每4周期1个r6
//   - 输出：每2周期1个r5（均匀分布）
//
// 延迟：5周期
// 乘法器：2×4 = 8个
//valid_in->valid_out延迟：5+3*4=17周期
//==============================================================================

module reconstruct_L6 #(
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
    
    // 输入：1个r6系数，每4周期1个
    input  wire                              din_valid,
    input  wire signed [INTERNAL_WIDTH-1:0]  r6_in,
    
    // 输出：1个r5系数，每2周期1个（均匀）
    output reg                               dout_valid,
    output reg  signed [INTERNAL_WIDTH-1:0]  r5_out
);
    //新增等待延迟
    reg [11:0] has_data;
    reg [3:0] cnt_shift=4'd0;
    
    //==========================================================================
    // 历史数据缓存
    //==========================================================================
    reg signed [INTERNAL_WIDTH-1:0] r6_hist [0:2];
    reg signed [INTERNAL_WIDTH-1:0] r6_curr;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r6_hist[0] <= 0; r6_hist[1] <= 0; r6_hist[2] <= 0;
            r6_curr <= 0;
        end else if (din_valid ) begin
            r6_hist[2] <= r6_hist[1];
            r6_hist[1] <= r6_hist[0];
            r6_hist[0] <= r6_curr;
            r6_curr <= r6_in;
        end
    end
    
    //==========================================================================
    // 相位计数器：跟踪4周期内的位置
    //==========================================================================
    reg [1:0] phase_cnt;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase_cnt <= 0;
        end else if (din_valid && has_data[11]) begin
            phase_cnt <= 1;
        end else if (phase_cnt != 0 && has_data[11]) begin
            if (phase_cnt == 3) begin
                phase_cnt <= 0;
            end else begin
                phase_cnt <= phase_cnt + 1;
            end
        end
    end
    
    //==========================================================================
    

    always@(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            cnt_shift <=4'd0;
        end else if (din_valid && cnt_shift==0) begin
            cnt_shift <= 1;
        end else if (cnt_shift>0 && cnt_shift<4'd12) begin
            cnt_shift <= cnt_shift +1;
        end

    end

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            has_data <= 0;
//          cnt_shift <=0;
        end else if (cnt_shift>=0 &&cnt_shift<4'd12) begin
            has_data <= {has_data[10:0], din_valid};
        end
    end
    
    //==========================================================================
    // Stage 1: 乘法
    //==========================================================================
    localparam MULT_WIDTH = INTERNAL_WIDTH + COEF_WIDTH;
    
    reg signed [MULT_WIDTH-1:0] mult_even_s1 [0:3];
    reg signed [MULT_WIDTH-1:0] mult_odd_s1 [0:3];
    
    always @(posedge clk) begin
        mult_even_s1[0] <= r6_curr     * $signed(REC_H0);
        mult_even_s1[1] <= r6_hist[0]  * $signed(REC_H2);
        mult_even_s1[2] <= r6_hist[1]  * $signed(REC_H4);
        mult_even_s1[3] <= r6_hist[2]  * $signed(REC_H6);
        
        mult_odd_s1[0] <= r6_curr     * $signed(REC_H1);
        mult_odd_s1[1] <= r6_hist[0]  * $signed(REC_H3);
        mult_odd_s1[2] <= r6_hist[1]  * $signed(REC_H5);
        mult_odd_s1[3] <= r6_hist[2]  * $signed(REC_H7);
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
    // Stage 3: 截断并选择输出
    // 时序分析（稳定流）：
    //   周期0: din_valid=1, phase_cnt==0, 同时输出上一组偶数（第一次除外）
    //   周期1: curr锁存完成, phase_cnt==1
    //   周期2: 乘法完成, phase_cnt==2, 输出奇数
    //   周期3: 加法完成, phase_cnt==3
    //   周期4: phase_cnt==0, din_valid=1, 输出偶数...
    //
    // 偶数在phase_cnt==0时输出（需要has_valid_data标志排除第一次）
    // 奇数在phase_cnt==2时输出
    //==========================================================================
    wire signed [INTERNAL_WIDTH-1:0] trunc_even = sum_even_s2[COEF_FRAC + INTERNAL_WIDTH - 1 : COEF_FRAC];
    wire signed [INTERNAL_WIDTH-1:0] trunc_odd  = sum_odd_s2[COEF_FRAC + INTERNAL_WIDTH - 1 : COEF_FRAC];
    
    // has_valid_data: 标记是否已经有有效数据计算完成
    // 第一个din_valid后4周期（即下一个din_valid到来时）置位
    reg has_valid_data;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            has_valid_data <= 0;
        end else begin
            if (phase_cnt == 3) begin
                // 加法完成，数据准备好，下一个phase_cnt==0时可以输出
                has_valid_data <= 1;
            end
        end
    end
    
   reg din_valid_stop_check=0;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            din_valid_stop_check<=0;
        end
        else begin if(phase_cnt==0)//只要检到phase_cnt==0即认为一个valid_din周期
                din_valid_stop_check<=1;
            else //当检查到由于valid_dind导致phase_cnt>0时，此时为一个新周期
                din_valid_stop_check<=0;
        end

    end

    // 输出逻辑：r5_out和dout_valid在同一个always块中
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r5_out <= 0;
            dout_valid <= 0;
        end else begin
            if (phase_cnt == 0 && has_valid_data && din_valid_stop_check==0) begin
                // 偶数分量输出
                r5_out <= trunc_even;
                dout_valid <= 1;
            end else if (phase_cnt == 2 && has_valid_data ) begin//has_valid_data是为了处理第一次的phase_cnt==0时，还没有准备好数据以及cnt_phase==2时还没又计算好（需要5个延迟）
                // 奇数分量输出
                r5_out <= trunc_odd;
                dout_valid <= 1;
            end else begin
                dout_valid <= 0;
                // r5_out保持不变
            end
        end
    end

endmodule
