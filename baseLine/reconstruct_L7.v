//==============================================================================
// 小波重构 L7 模块
// 
// 功能：第七级重构，a7 → r6
// 
// 流水线：
//   Stage 1: curr锁存（din_valid时）
//   Stage 2: 乘法 → 寄存器
//   Stage 3: 加法 → 寄存器
//   Stage 4: 截断 → 输出寄存器
//
// 数据率：
//   - 输入：每8周期1个a7
//   - 输出：每4周期1个r6（均匀分布）
//
// 延迟：5周期
// 乘法器：2×4 = 8个
// valid_in->valid_out延迟：5+3*8=29周期，其中3个历史的数据，每8个周期来一次，这属于有由于速率不同的等待延迟
//==============================================================================

module reconstruct_L7 #(
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
    
    // 输入：1个a7系数，每8周期1个
    input  wire                              din_valid,
    input  wire signed [INTERNAL_WIDTH-1:0]  a7_in,
    
    // 输出：1个r6系数，每4周期1个（均匀）
    output reg                               dout_valid,
    output reg  signed [INTERNAL_WIDTH-1:0]  r6_out
);

    //新增等待延迟
    reg [23:0] has_data;
    reg [4:0] cnt_shift=5'd0;
    //==========================================================================
    // 历史数据缓存
    //==========================================================================
    reg signed [INTERNAL_WIDTH-1:0] a7_hist [0:2];
    reg signed [INTERNAL_WIDTH-1:0] a7_curr;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a7_hist[0] <= 0; a7_hist[1] <= 0; a7_hist[2] <= 0;
            a7_curr <= 0;
        end else if (din_valid) begin
            a7_hist[2] <= a7_hist[1];
            a7_hist[1] <= a7_hist[0];
            a7_hist[0] <= a7_curr;
            a7_curr <= a7_in;
        end
    end
    
    //==========================================================================
    // 相位计数器：跟踪8周期内的位置
    //==========================================================================
    reg [2:0] phase_cnt;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase_cnt <= 0;
        end else if (din_valid&&has_data[23]) begin
            phase_cnt <= 1;
        end else if (phase_cnt != 0&&has_data[23]) begin
            if (phase_cnt == 7) begin
                phase_cnt <= 0;
            end else begin
                phase_cnt <= phase_cnt + 1;
            end
        end
    end
    //==========================================================================


    always@(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            cnt_shift <=5'd0;
        end else if (din_valid && cnt_shift==0) begin//仅仅用于第一次din_valid进来，用于移位寄存器的延迟
            cnt_shift <= 1;
        end else if (cnt_shift>0 && cnt_shift<5'd24) begin//之后保持在24
            cnt_shift <= cnt_shift +1;
        end

    end

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            has_data <= 0;
        end else if (cnt_shift>=0 &&cnt_shift<5'd24) begin//第一次valid_in进来开始，若
        //在valid_in进来之前，cnt_shift=0,只有第一次valid_in=1才会使得cnt_shitf=1并开始递增
        //在valid_in进来之前，将din_valid移入并没有影响，因为它是0.
            has_data <= {has_data[22:0], din_valid};
        end
    end

    //==========================================================================
    // Stage 1: 乘法 (8个乘法器)
    //==========================================================================
    localparam MULT_WIDTH = INTERNAL_WIDTH + COEF_WIDTH;
    
    reg signed [MULT_WIDTH-1:0] mult_even_s1 [0:3];
    reg signed [MULT_WIDTH-1:0] mult_odd_s1 [0:3];
    
    always @(posedge clk) begin
        mult_even_s1[0] <= a7_curr     * $signed(REC_H0);
        mult_even_s1[1] <= a7_hist[0]  * $signed(REC_H2);
        mult_even_s1[2] <= a7_hist[1]  * $signed(REC_H4);
        mult_even_s1[3] <= a7_hist[2]  * $signed(REC_H6);
        
        mult_odd_s1[0] <= a7_curr     * $signed(REC_H1);
        mult_odd_s1[1] <= a7_hist[0]  * $signed(REC_H3);
        mult_odd_s1[2] <= a7_hist[1]  * $signed(REC_H5);
        mult_odd_s1[3] <= a7_hist[2]  * $signed(REC_H7);
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
    // 时序：din_valid在周期0 → curr锁存在周期1 → 乘法在周期2 → 加法在周期3 → 输出在周期4
    // 偶数输出：phase_cnt==4时输出trunc_even
    // 奇数输出：phase_cnt==0时输出trunc_odd
    //几乎不会有丢失符号位的风险，因为此时的位宽足够大，前5位一定是一致的.
    //==========================================================================
    wire signed [INTERNAL_WIDTH-1:0] trunc_even = sum_even_s2[COEF_FRAC + INTERNAL_WIDTH - 1 : COEF_FRAC];
    wire signed [INTERNAL_WIDTH-1:0] trunc_odd  = sum_odd_s2[COEF_FRAC + INTERNAL_WIDTH - 1 : COEF_FRAC];
    
    // has_valid_data: 标记是否已经有有效数据计算完成
    reg has_valid_data;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            has_valid_data <= 0;
        end else begin
            if (phase_cnt == 3) begin
                has_valid_data <= 1;  // 加法完成，下一周期可以输出
            end
        end
    end
    
    // 输出逻辑：r6_out和dout_valid在同一个always块中
    //此处需要处理一个特别的逻辑就是当前端已经将din_valid拉低了，且很久没有din_valid,dout_valid会一直保持为1，
    //这是致命的，为此需要增加一个din_valid_check_stop
    //如果前端已经出现了周期性的din_valid但是现在经过8个周期后没有，会判定为停止此次的传输.
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
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r6_out <= 0;
            dout_valid <= 0;
        end else begin
            if (phase_cnt == 4) begin//之所以这里没有了has_valid_data是因为cnt_phase此时已经准备好了
                // 偶数分量输出
                r6_out <= trunc_even;
                dout_valid <= 1;
            end else if (phase_cnt == 0 && has_valid_data && din_valid_stop_check==0) begin
                // 奇数分量输出
                r6_out <= trunc_odd;
                dout_valid <= 1;
            end else begin
                dout_valid <= 0;
                // r6_out保持不变
            end
        end
    end

endmodule
