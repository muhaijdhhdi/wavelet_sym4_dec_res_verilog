//==============================================================================
// 小波重构 L5 模块
// 
// 功能：第五级重构，r5 → r4
// 
// 流水线：
//   Stage 1: curr锁存（din_valid时）
//   Stage 2: 乘法 → 寄存器
//   Stage 3: 加法 → 寄存器
//   Stage 4: 截断 → 输出寄存器
//
// 数据率：
//   - 输入：每2周期1个r5
//   - 输出：每1周期1个r4（连续输出）
//
// 延迟：5周期
// 乘法器：2×4 = 8个
//valid_in->valid_out延迟：5+3*2==11周期
//==============================================================================

module reconstruct_L5 #(
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
    
    // 输入：1个r5系数，每2周期1个
    input  wire                              din_valid,
    input  wire signed [INTERNAL_WIDTH-1:0]  r5_in,
    
    // 输出：1个r4系数，每1周期1个（连续）
    output reg                               dout_valid,
    output reg  signed [INTERNAL_WIDTH-1:0]  r4_out
);
    //新增等待延迟
    reg [5:0] has_data;//等待延迟
    reg [2:0] cnt_shift=0;
    //==========================================================================
    // 历史数据缓存
    //==========================================================================
    reg signed [INTERNAL_WIDTH-1:0] r5_hist [0:2];
    reg signed [INTERNAL_WIDTH-1:0] r5_curr;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r5_hist[0] <= 0; r5_hist[1] <= 0; r5_hist[2] <= 0;
            r5_curr <= 0;
        end else if (din_valid ) begin
            r5_hist[2] <= r5_hist[1];
            r5_hist[1] <= r5_hist[0];
            r5_hist[0] <= r5_curr;
            r5_curr <= r5_in;
        end
    end
    
    //==========================================================================
    // 相位计数器：跟踪2周期内的位置
    //==========================================================================
    reg phase_cnt;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase_cnt <= 0;
        end else if (din_valid && has_data[5]) begin
            phase_cnt <= 1;
        end else if (phase_cnt == 1 && has_data[5]) begin
            phase_cnt <= 0;
        end
    end
    //==========================================================================


    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            has_data <= 0;
        end else begin if(cnt_shift>=0 &&cnt_shift<3'd6) begin
                has_data <= {has_data[4:0],din_valid};   
        end
    end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_shift <= 0;
        end else if (din_valid && cnt_shift==0) begin
            cnt_shift <= 1;
        end else if (cnt_shift>0 && cnt_shift<3'd6) begin
            cnt_shift <= cnt_shift +1;
        end
    end


    //==========================================================================
    // Stage 1: 乘法
    //==========================================================================
    localparam MULT_WIDTH = INTERNAL_WIDTH + COEF_WIDTH;
    
    reg signed [MULT_WIDTH-1:0] mult_even_s1 [0:3];
    reg signed [MULT_WIDTH-1:0] mult_odd_s1 [0:3];
    
    always @(posedge clk) begin
        mult_even_s1[0] <= r5_curr     * $signed(REC_H0);
        mult_even_s1[1] <= r5_hist[0]  * $signed(REC_H2);
        mult_even_s1[2] <= r5_hist[1]  * $signed(REC_H4);
        mult_even_s1[3] <= r5_hist[2]  * $signed(REC_H6);
        
        mult_odd_s1[0] <= r5_curr     * $signed(REC_H1);
        mult_odd_s1[1] <= r5_hist[0]  * $signed(REC_H3);
        mult_odd_s1[2] <= r5_hist[1]  * $signed(REC_H5);
        mult_odd_s1[3] <= r5_hist[2]  * $signed(REC_H7);
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
    // 时序分析（2周期一循环）：
    //   周期0: din_valid=1, phase_cnt: 0→1, curr锁存
    //   周期1: phase_cnt: 1→0, 乘法完成
    //   周期2: din_valid=1, phase_cnt: 0→1, 加法完成
    //   周期3: phase_cnt: 1→0, 输出偶数
    //   周期4: din_valid=1, phase_cnt: 0→1, 输出奇数
    //   ...连续输出
    //
    // 偶数在phase_cnt==0时输出（非复位时）
    // 奇数在phase_cnt==1时输出（has_valid_data后）
    //==========================================================================
    wire signed [INTERNAL_WIDTH-1:0] trunc_even = sum_even_s2[COEF_FRAC + INTERNAL_WIDTH - 1 : COEF_FRAC];
    wire signed [INTERNAL_WIDTH-1:0] trunc_odd  = sum_odd_s2[COEF_FRAC + INTERNAL_WIDTH - 1 : COEF_FRAC];
    
    // has_valid_data: 标记是否已经有有效数据计算完成
    // 时序：周期0 din_valid → 周期1 锁存 → 周期2 乘法 → 周期3 加法 → 周期4 输出
    // 需要在周期3末置位，即第2次 phase_cnt==1 && !din_valid 时
    // 用2级延迟实现
    reg has_valid_data_pre;
    reg has_valid_data_d1;
    reg has_valid_data;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            has_valid_data_pre <= 0;
            has_valid_data_d1 <= 0;
            has_valid_data <= 0;
        end else begin
            if (phase_cnt == 1 && !din_valid ) begin
                has_valid_data_pre <= 1;
            end
            has_valid_data_d1 <= has_valid_data_pre;
            has_valid_data <= has_valid_data_d1;
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

    // 输出逻辑：r4_out和dout_valid在同一个always块中
    // L5输出连续：偶数在phase_cnt==0输出，奇数在phase_cnt==1输出

    reg [INTERNAL_WIDTH-1:0]trunc_odd_reg=0;//缓存一下trunc_odd,因为计算时是同时计算出trunc_odd和trunc_even（phase_cnt=1），下一个周期（phase=0）会将偶数部分赋值给r4_out（开始计算），再下一个周期（phase=1),再次计算一对值，但是如果依旧使用cnt_phase=1时将其赋予r4_out，得到的就是新的奇数值，因此需要将trunc_odd缓存一个时钟周期
    always @(posedge clk) begin
        trunc_odd_reg<=trunc_odd;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r4_out <= 0;
            dout_valid <= 0;
        end else begin
            if (phase_cnt == 0 && has_valid_data&&din_valid_stop_check==0) begin
                // 偶数分量输出
                r4_out <= trunc_even;
                dout_valid <= 1;
            end else if (phase_cnt == 1 && has_valid_data) begin
                // 奇数分量输出
                r4_out <= trunc_odd_reg;
                dout_valid <= 1;
            end else begin
                dout_valid <= 0;
            end
        end
    end

endmodule
