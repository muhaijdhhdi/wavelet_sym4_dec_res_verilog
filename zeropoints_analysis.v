`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: zeropoints_analysis
// Description: 零点分析器模块
//              包含多级缓存、配对逻辑调用、有效脉冲验证
//
// 功能：
//   1. 多级缓存：过零掩码、差分值、绝对电平（5级 + 流水线对齐）
//   2. 调用 ones_mate 进行过零点配对
//   3. 验证每个配对：差分值>0、差分幅度达标、绝对幅度达标
//   4. 输出有效脉冲数
//
// 验证条件（三者同时满足）：
//   1. 配对的两个过零点之间差分值 > 0（负脉冲特征）
//   2. 差分幅度 > diff_threshold
//   3. 绝对电平 > abs_threshold
//
// 流水线优化（验证逻辑 3 级）：
//   Stage V1: 索引选择 + 跨周期 MUX
//   Stage V2: 比较运算（diff_positive, diff_amp_ok, abs_amp_ok）
//   Stage V3: 综合验证（与门）+ popcount
//
// 优化：
//   - ones_mate 不再接收 diff/abs 数据，只输出 pending 位置
//   - zeropoints_analysis 检测到新 pending 时，自己保存对应的 diff/abs
//////////////////////////////////////////////////////////////////////////////////

module zeropoints_analysis #(
    parameter NUM_CHANNELS = 16,
    parameter DATA_WIDTH = 20,             // Q16.4格式
    parameter BUFFER_DEPTH = 9,            // 5级原始 + 4级流水线对齐
    parameter MAX_PAIRS = 8
)(
    input  wire                                  clk,
    input  wire                                  rst_n,
    input  wire                                  valid_in,
    input  wire [NUM_CHANNELS-1:0]              zero_mask,        // 过零掩码
    input  wire [NUM_CHANNELS*DATA_WIDTH-1:0]   diff_in,          // 差分数据
    input  wire [NUM_CHANNELS*DATA_WIDTH-1:0]   abs_in,           // 绝对电平数据
    input  wire signed [DATA_WIDTH-1:0]         diff_threshold,   // 差分阈值
    input  wire signed [DATA_WIDTH-1:0]         abs_threshold,    // 绝对阈值
    
    output reg  [4:0]                           pulse_count,      // 有效脉冲数（0~16）
    output reg                                  valid_out,
    
    // 调试输出
    output wire [MAX_PAIRS-1:0]                 dbg_pair_valid,
    output wire [4:0]                           dbg_total_pairs
);

    //==========================================================================
    // ones_mate 实例化
    //==========================================================================
    wire [MAX_PAIRS-1:0] mate_pair_valid;   // 每一对是否有效
    wire [MAX_PAIRS*4-1:0] mate_pair_pos_a;  // 一维向量，32位
    wire [MAX_PAIRS*4-1:0] mate_pair_pos_b;  // 一维向量，32位
    wire [MAX_PAIRS-1:0] mate_pair_cross;
    wire [4:0] mate_total_pairs;
    wire mate_valid_out;
    wire [2:0] mate_pipeline_delay;
    
    // pending 状态输出
    wire mate_pending_valid;
    wire [3:0] mate_pending_pos;
    wire mate_new_pending;
    wire [3:0] mate_new_pending_pos;
    
    ones_mate #(
        .NUM_CHANNELS(NUM_CHANNELS),
        .MAX_PAIRS(MAX_PAIRS)
    ) u_ones_mate (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(valid_in),
        .zero_mask(zero_mask),
        
        .pair_valid(mate_pair_valid),
        .pair_pos_a(mate_pair_pos_a),
        .pair_pos_b(mate_pair_pos_b),
        .pair_cross_cycle(mate_pair_cross),
        .total_pairs(mate_total_pairs),
        .valid_out(mate_valid_out),
        
        .pending_valid_out(mate_pending_valid),
        .pending_pos_out(mate_pending_pos),
        .new_pending_out(mate_new_pending),
        .new_pending_pos_out(mate_new_pending_pos),
        
        .pipeline_delay(mate_pipeline_delay)
    );
    
    assign dbg_pair_valid = mate_pair_valid;
    assign dbg_total_pairs = mate_total_pairs;
    
    // 从一维向量中提取各配对的位置
    wire [3:0] pair_pos_a_arr [0:MAX_PAIRS-1];
    wire [3:0] pair_pos_b_arr [0:MAX_PAIRS-1];
    
    genvar p;
    generate
        for (p = 0; p < MAX_PAIRS; p = p + 1) begin : gen_extract_pairs
            assign pair_pos_a_arr[p] = mate_pair_pos_a[p*4 +: 4];
            assign pair_pos_b_arr[p] = mate_pair_pos_b[p*4 +: 4];
        end
    endgenerate

    //==========================================================================
    // 差分值和绝对电平的多级缓存
    // 需要延迟 mate_pipeline_delay 周期以与配对结果对齐
    //==========================================================================
    localparam DELAY_STAGES = 4;  // 与 ones_mate 的流水线延迟一致
    
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] diff_delay_0;
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] diff_delay_1;
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] diff_delay_2;
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] diff_delay_3;
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] diff_delay_4;
    
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] abs_delay_0;
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] abs_delay_1;
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] abs_delay_2;
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] abs_delay_3;
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] abs_delay_4;
    
    always @(posedge clk) begin
        diff_delay_0 <= diff_in;
        diff_delay_1 <= diff_delay_0;
        diff_delay_2 <= diff_delay_1;
        diff_delay_3 <= diff_delay_2;
        diff_delay_4 <= diff_delay_3;
        
        abs_delay_0 <= abs_in;
        abs_delay_1 <= abs_delay_0;
        abs_delay_2 <= abs_delay_1;
        abs_delay_3 <= abs_delay_2;
        abs_delay_4 <= abs_delay_3;
    end
    
    // 对齐后的数据（与配对结果同步）
    wire [NUM_CHANNELS*DATA_WIDTH-1:0] diff_aligned = diff_delay_4;
    wire [NUM_CHANNELS*DATA_WIDTH-1:0] abs_aligned = abs_delay_4;
    
    // 用于新 pending 保存的数据（ones_mate Stage 4 输出时对应 delay_3）
    wire [NUM_CHANNELS*DATA_WIDTH-1:0] diff_for_pending = diff_delay_3;
    wire [NUM_CHANNELS*DATA_WIDTH-1:0] abs_for_pending = abs_delay_3;

    //==========================================================================
    // 提取各通道数据（便于索引访问）
    //==========================================================================
    wire signed [DATA_WIDTH-1:0] diff_ch [0:NUM_CHANNELS-1];
    wire signed [DATA_WIDTH-1:0] abs_ch [0:NUM_CHANNELS-1];
    wire signed [DATA_WIDTH-1:0] diff_ch_for_pending [0:NUM_CHANNELS-1];
    wire signed [DATA_WIDTH-1:0] abs_ch_for_pending [0:NUM_CHANNELS-1];
    
    genvar g;
    generate
        for (g = 0; g < NUM_CHANNELS; g = g + 1) begin : gen_extract
            assign diff_ch[g] = diff_aligned[g*DATA_WIDTH +: DATA_WIDTH];
            assign abs_ch[g] = abs_aligned[g*DATA_WIDTH +: DATA_WIDTH];
            assign diff_ch_for_pending[g] = diff_for_pending[g*DATA_WIDTH +: DATA_WIDTH];
            assign abs_ch_for_pending[g] = abs_for_pending[g*DATA_WIDTH +: DATA_WIDTH];
        end
    endgenerate

    //==========================================================================
    // Pending 数据保存
    // 当 ones_mate 产生新 pending 时，保存对应的 diff 和 abs
    //==========================================================================
    reg signed [DATA_WIDTH-1:0] saved_pending_diff;
    reg signed [DATA_WIDTH-1:0] saved_pending_abs;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            saved_pending_diff <= 0;
            saved_pending_abs <= 0;
        end
        else if (mate_new_pending) begin
            saved_pending_diff <= diff_ch_for_pending[mate_new_pending_pos];
            saved_pending_abs <= abs_ch_for_pending[mate_new_pending_pos];
        end
    end

    //==========================================================================
    // 阈值寄存（减少扇出，与 ones_mate 输出对齐）
    //==========================================================================
    reg signed [DATA_WIDTH-1:0] diff_th_reg;
    reg signed [DATA_WIDTH-1:0] diff_th_neg_reg;
    reg signed [DATA_WIDTH-1:0] abs_th_reg;
    reg signed [DATA_WIDTH-1:0] abs_th_neg_reg;
    
    always @(posedge clk) begin
        diff_th_reg <= diff_threshold;
        diff_th_neg_reg <= -diff_threshold;
        abs_th_reg <= abs_threshold;
        abs_th_neg_reg <= -abs_threshold;
    end

    //==========================================================================
    // 验证流水线 Stage V1: 索引选择 + 跨周期 MUX
    // 将 MUX 选择结果寄存，减少组合逻辑深度
    //==========================================================================
    reg signed [DATA_WIDTH-1:0] diff_a_v1 [0:MAX_PAIRS-1];
    reg signed [DATA_WIDTH-1:0] abs_a_v1 [0:MAX_PAIRS-1];
    reg [MAX_PAIRS-1:0] pair_valid_v1;
    reg valid_v1;
    
    // 阈值也需要延迟一级以对齐
    reg signed [DATA_WIDTH-1:0] diff_th_v1;
    reg signed [DATA_WIDTH-1:0] diff_th_neg_v1;
    reg signed [DATA_WIDTH-1:0] abs_th_v1;
    reg signed [DATA_WIDTH-1:0] abs_th_neg_v1;
    
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < MAX_PAIRS; i = i + 1) begin
                diff_a_v1[i] <= 0;
                abs_a_v1[i] <= 0;
            end
            pair_valid_v1 <= 0;
            valid_v1 <= 0;
            diff_th_v1 <= 0;
            diff_th_neg_v1 <= 0;
            abs_th_v1 <= 0;
            abs_th_neg_v1 <= 0;
        end
        else begin
            valid_v1 <= mate_valid_out;
            pair_valid_v1 <= mate_pair_valid;
            
            // 阈值延迟
            diff_th_v1 <= diff_th_reg;
            diff_th_neg_v1 <= diff_th_neg_reg;
            abs_th_v1 <= abs_th_reg;
            abs_th_neg_v1 <= abs_th_neg_reg;
            
            // pair[0]: 可能是跨周期配对
            diff_a_v1[0] <= mate_pair_cross[0] ? saved_pending_diff : diff_ch[pair_pos_a_arr[0]];
            abs_a_v1[0] <= mate_pair_cross[0] ? saved_pending_abs : abs_ch[pair_pos_a_arr[0]];
            
            // pair[1~7]: 当前周期内配对
            diff_a_v1[1] <= diff_ch[pair_pos_a_arr[1]];
            diff_a_v1[2] <= diff_ch[pair_pos_a_arr[2]];
            diff_a_v1[3] <= diff_ch[pair_pos_a_arr[3]];
            diff_a_v1[4] <= diff_ch[pair_pos_a_arr[4]];
            diff_a_v1[5] <= diff_ch[pair_pos_a_arr[5]];
            diff_a_v1[6] <= diff_ch[pair_pos_a_arr[6]];
            diff_a_v1[7] <= diff_ch[pair_pos_a_arr[7]];
            
            abs_a_v1[1] <= abs_ch[pair_pos_a_arr[1]];
            abs_a_v1[2] <= abs_ch[pair_pos_a_arr[2]];
            abs_a_v1[3] <= abs_ch[pair_pos_a_arr[3]];
            abs_a_v1[4] <= abs_ch[pair_pos_a_arr[4]];
            abs_a_v1[5] <= abs_ch[pair_pos_a_arr[5]];
            abs_a_v1[6] <= abs_ch[pair_pos_a_arr[6]];
            abs_a_v1[7] <= abs_ch[pair_pos_a_arr[7]];
        end
    end

    //==========================================================================
    // 验证流水线 Stage V2: 比较运算
    // diff_positive, diff_amp_ok, abs_amp_ok
    //==========================================================================
    reg [MAX_PAIRS-1:0] diff_positive_v2;
    reg [MAX_PAIRS-1:0] diff_amp_ok_v2;
    reg [MAX_PAIRS-1:0] abs_amp_ok_v2;
    reg [MAX_PAIRS-1:0] pair_valid_v2;
    reg valid_v2;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            diff_positive_v2 <= 0;
            diff_amp_ok_v2 <= 0;
            abs_amp_ok_v2 <= 0;
            pair_valid_v2 <= 0;
            valid_v2 <= 0;
        end
        else begin
            valid_v2 <= valid_v1;
            pair_valid_v2 <= pair_valid_v1;
            
            // diff_positive: diff > 0
            diff_positive_v2[0] <= (diff_a_v1[0] > 0);
            diff_positive_v2[1] <= (diff_a_v1[1] > 0);
            diff_positive_v2[2] <= (diff_a_v1[2] > 0);
            diff_positive_v2[3] <= (diff_a_v1[3] > 0);
            diff_positive_v2[4] <= (diff_a_v1[4] > 0);
            diff_positive_v2[5] <= (diff_a_v1[5] > 0);
            diff_positive_v2[6] <= (diff_a_v1[6] > 0);
            diff_positive_v2[7] <= (diff_a_v1[7] > 0);
            
            // diff_amp_ok: |diff| > threshold
            diff_amp_ok_v2[0] <= diff_a_v1[0][DATA_WIDTH-1] ? (diff_a_v1[0] < diff_th_neg_v1) : (diff_a_v1[0] > diff_th_v1);
            diff_amp_ok_v2[1] <= diff_a_v1[1][DATA_WIDTH-1] ? (diff_a_v1[1] < diff_th_neg_v1) : (diff_a_v1[1] > diff_th_v1);
            diff_amp_ok_v2[2] <= diff_a_v1[2][DATA_WIDTH-1] ? (diff_a_v1[2] < diff_th_neg_v1) : (diff_a_v1[2] > diff_th_v1);
            diff_amp_ok_v2[3] <= diff_a_v1[3][DATA_WIDTH-1] ? (diff_a_v1[3] < diff_th_neg_v1) : (diff_a_v1[3] > diff_th_v1);
            diff_amp_ok_v2[4] <= diff_a_v1[4][DATA_WIDTH-1] ? (diff_a_v1[4] < diff_th_neg_v1) : (diff_a_v1[4] > diff_th_v1);
            diff_amp_ok_v2[5] <= diff_a_v1[5][DATA_WIDTH-1] ? (diff_a_v1[5] < diff_th_neg_v1) : (diff_a_v1[5] > diff_th_v1);
            diff_amp_ok_v2[6] <= diff_a_v1[6][DATA_WIDTH-1] ? (diff_a_v1[6] < diff_th_neg_v1) : (diff_a_v1[6] > diff_th_v1);
            diff_amp_ok_v2[7] <= diff_a_v1[7][DATA_WIDTH-1] ? (diff_a_v1[7] < diff_th_neg_v1) : (diff_a_v1[7] > diff_th_v1);
            
            // abs_amp_ok: |abs| > threshold
            abs_amp_ok_v2[0] <= abs_a_v1[0][DATA_WIDTH-1] ? (abs_a_v1[0] < abs_th_neg_v1) : (abs_a_v1[0] > abs_th_v1);
            abs_amp_ok_v2[1] <= abs_a_v1[1][DATA_WIDTH-1] ? (abs_a_v1[1] < abs_th_neg_v1) : (abs_a_v1[1] > abs_th_v1);
            abs_amp_ok_v2[2] <= abs_a_v1[2][DATA_WIDTH-1] ? (abs_a_v1[2] < abs_th_neg_v1) : (abs_a_v1[2] > abs_th_v1);
            abs_amp_ok_v2[3] <= abs_a_v1[3][DATA_WIDTH-1] ? (abs_a_v1[3] < abs_th_neg_v1) : (abs_a_v1[3] > abs_th_v1);
            abs_amp_ok_v2[4] <= abs_a_v1[4][DATA_WIDTH-1] ? (abs_a_v1[4] < abs_th_neg_v1) : (abs_a_v1[4] > abs_th_v1);
            abs_amp_ok_v2[5] <= abs_a_v1[5][DATA_WIDTH-1] ? (abs_a_v1[5] < abs_th_neg_v1) : (abs_a_v1[5] > abs_th_v1);
            abs_amp_ok_v2[6] <= abs_a_v1[6][DATA_WIDTH-1] ? (abs_a_v1[6] < abs_th_neg_v1) : (abs_a_v1[6] > abs_th_v1);
            abs_amp_ok_v2[7] <= abs_a_v1[7][DATA_WIDTH-1] ? (abs_a_v1[7] < abs_th_neg_v1) : (abs_a_v1[7] > abs_th_v1);
        end
    end

    //==========================================================================
    // 验证流水线 Stage V3: 综合验证（与门）
    //==========================================================================
    reg [MAX_PAIRS-1:0] pair_verified_v3;
    reg valid_v3;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pair_verified_v3 <= 0;
            valid_v3 <= 0;
        end
        else begin
            valid_v3 <= valid_v2;
            
            pair_verified_v3[0] <= pair_valid_v2[0] && diff_positive_v2[0] && diff_amp_ok_v2[0] && abs_amp_ok_v2[0];
            pair_verified_v3[1] <= pair_valid_v2[1] && diff_positive_v2[1] && diff_amp_ok_v2[1] && abs_amp_ok_v2[1];
            pair_verified_v3[2] <= pair_valid_v2[2] && diff_positive_v2[2] && diff_amp_ok_v2[2] && abs_amp_ok_v2[2];
            pair_verified_v3[3] <= pair_valid_v2[3] && diff_positive_v2[3] && diff_amp_ok_v2[3] && abs_amp_ok_v2[3];
            pair_verified_v3[4] <= pair_valid_v2[4] && diff_positive_v2[4] && diff_amp_ok_v2[4] && abs_amp_ok_v2[4];
            pair_verified_v3[5] <= pair_valid_v2[5] && diff_positive_v2[5] && diff_amp_ok_v2[5] && abs_amp_ok_v2[5];
            pair_verified_v3[6] <= pair_valid_v2[6] && diff_positive_v2[6] && diff_amp_ok_v2[6] && abs_amp_ok_v2[6];
            pair_verified_v3[7] <= pair_valid_v2[7] && diff_positive_v2[7] && diff_amp_ok_v2[7] && abs_amp_ok_v2[7];
        end
    end

    //==========================================================================
    // 计数有效脉冲（popcount）+ 输出寄存
    //==========================================================================
    wire [4:0] popcount_result;
    assign popcount_result = pair_verified_v3[0] + pair_verified_v3[1] + pair_verified_v3[2] + pair_verified_v3[3] +
                             pair_verified_v3[4] + pair_verified_v3[5] + pair_verified_v3[6] + pair_verified_v3[7];
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pulse_count <= 0;
            valid_out <= 0;
        end
        else begin
            valid_out <= valid_v3;
            pulse_count <= popcount_result;
        end
    end

endmodule
