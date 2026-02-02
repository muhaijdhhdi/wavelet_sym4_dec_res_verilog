`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: zeropoints_analysis_v2
// Description: 零点分析器模块（增强版）
//              包含多级缓存、配对逻辑调用、有效脉冲验证
//
// 功能：
//   1. 多级缓存：差分值、绝对电平（用于跨周期处理）
//   2. 调用 ones_mate_v2 进行基于方向的过零点配对
//   3. 计算每对过零点之间的最大差分值和最小绝对电平
//   4. 验证每个配对是否为有效脉冲
//   5. 输出有效脉冲数
//
// 验证条件（三者同时满足）：
//   1. 差分最大值 > diff_threshold（pos_a 到 pos_b 之间）
//   2. 绝对电平最小值 < 0（负脉冲特征）
//   3. |绝对电平最小值| > abs_threshold（幅度够大）
//
// 跨周期处理：
//   - pending 可跨多个周期（最多4个周期）
//   - 累积更新 partial_max_diff 和 partial_min_abs
//
// 流水线结构（优化时序）：
//   ones_mate_v2: 4 周期（内部实例化）
//   Stage P1: 预计算分段最大/最小值（4段：0-3, 4-7, 8-11, 12-15）
//   Stage P2: 根据 pos_a/pos_b 选择并组合分段结果，计算 [pos_a, pos_b] 范围最大/最小值
//   Stage V1: 阈值比较
//   Stage V2: 综合验证（AND 门）
//   Stage V3: popcount + 输出
//
// 流水线延迟：约 10-11 个时钟周期
//   (ones_mate 4 + P1 1 + P2 1 + V1 1 + V2 1 + V3 1 = 9-10，加上内部缓存对齐)
//////////////////////////////////////////////////////////////////////////////////

module zeropoints_analysis_v2 #(
    parameter NUM_CHANNELS = 16,
    parameter DATA_WIDTH = 20,             // Q16.4格式
    parameter MAX_PAIRS = 8
)(
    input  wire                                  clk,
    input  wire                                  rst_n,
    input  wire                                  valid_in,
    input  wire [NUM_CHANNELS-1:0]              zero_mask,        // 过零掩码
    input  wire [NUM_CHANNELS-1:0]              zero_direction,   // 过零方向
    input  wire [NUM_CHANNELS*DATA_WIDTH-1:0]   diff_in,          // 差分数据
    input  wire [NUM_CHANNELS*DATA_WIDTH-1:0]   abs_in,           // 绝对电平数据
    input  wire signed [DATA_WIDTH-1:0]         diff_threshold,   // 差分阈值
    input  wire signed [DATA_WIDTH-1:0]         abs_threshold,    // 绝对阈值
    
    output reg  [4:0]                           pulse_count,      // 有效脉冲数（0~8）
    output reg                                  valid_out,
    
    // 调试输出
    output wire [MAX_PAIRS-1:0]                 dbg_pair_valid,
    output wire [4:0]                           dbg_total_pairs
);

    //==========================================================================
    // ones_mate_v2 实例化
    //==========================================================================
    wire [MAX_PAIRS-1:0] mate_pair_valid;
    wire [MAX_PAIRS*4-1:0] mate_pair_pos_a;
    wire [MAX_PAIRS*4-1:0] mate_pair_pos_b;
    wire [MAX_PAIRS-1:0] mate_pair_cross;
    wire [4:0] mate_total_pairs;
    wire mate_valid_out;
    wire mate_pending_valid;
    wire [3:0] mate_pending_pos;
    wire mate_new_pending;
    wire [3:0] mate_new_pending_pos;
    wire [2:0] mate_pipeline_delay;
    
    ones_mate_v2 #(
        .NUM_CHANNELS(NUM_CHANNELS),
        .MAX_PAIRS(MAX_PAIRS)
    ) u_ones_mate (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(valid_in),
        .zero_mask(zero_mask),
        .zero_direction(zero_direction),
        
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
    
    // 提取配对位置
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
    // 需要与 ones_mate_v2 输出对齐（4级延迟）+ 额外 2 级用于分段预计算
    //==========================================================================
    localparam DELAY_STAGES = 6;  // 增加 2 级用于 P1/P2 流水线
    
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] diff_delay [0:DELAY_STAGES];
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] abs_delay [0:DELAY_STAGES];
    
    integer d;
    always @(posedge clk) begin
        diff_delay[0] <= diff_in;
        abs_delay[0] <= abs_in;
        for (d = 1; d <= DELAY_STAGES; d = d + 1) begin
            diff_delay[d] <= diff_delay[d-1];
            abs_delay[d] <= abs_delay[d-1];
        end
    end
    
    // 对齐后的数据（用于 Stage V1，与 ones_mate 输出 + P1/P2 对齐）
    wire [NUM_CHANNELS*DATA_WIDTH-1:0] diff_aligned = diff_delay[DELAY_STAGES];
    wire [NUM_CHANNELS*DATA_WIDTH-1:0] abs_aligned = abs_delay[DELAY_STAGES];
    
    // 用于 pending 计算的数据（ones_mate Stage 3 时对应 delay[3]）
    wire [NUM_CHANNELS*DATA_WIDTH-1:0] diff_for_pending = diff_delay[3];
    wire [NUM_CHANNELS*DATA_WIDTH-1:0] abs_for_pending = abs_delay[3];
    
    // 用于 Stage P1 预计算的数据（ones_mate 输出时对应 delay[4]）
    wire [NUM_CHANNELS*DATA_WIDTH-1:0] diff_for_p1 = diff_delay[4];
    wire [NUM_CHANNELS*DATA_WIDTH-1:0] abs_for_p1 = abs_delay[4];

    //==========================================================================
    // 提取各通道数据
    //==========================================================================
    wire signed [DATA_WIDTH-1:0] diff_ch [0:NUM_CHANNELS-1];
    wire signed [DATA_WIDTH-1:0] abs_ch [0:NUM_CHANNELS-1];
    wire signed [DATA_WIDTH-1:0] diff_ch_pending [0:NUM_CHANNELS-1];
    wire signed [DATA_WIDTH-1:0] abs_ch_pending [0:NUM_CHANNELS-1];
    wire signed [DATA_WIDTH-1:0] diff_ch_p1 [0:NUM_CHANNELS-1];
    wire signed [DATA_WIDTH-1:0] abs_ch_p1 [0:NUM_CHANNELS-1];
    
    genvar g;
    generate
        for (g = 0; g < NUM_CHANNELS; g = g + 1) begin : gen_extract
            assign diff_ch[g] = diff_aligned[g*DATA_WIDTH +: DATA_WIDTH];
            assign abs_ch[g] = abs_aligned[g*DATA_WIDTH +: DATA_WIDTH];
            assign diff_ch_pending[g] = diff_for_pending[g*DATA_WIDTH +: DATA_WIDTH];
            assign abs_ch_pending[g] = abs_for_pending[g*DATA_WIDTH +: DATA_WIDTH];
            assign diff_ch_p1[g] = diff_for_p1[g*DATA_WIDTH +: DATA_WIDTH];
            assign abs_ch_p1[g] = abs_for_p1[g*DATA_WIDTH +: DATA_WIDTH];
        end
    endgenerate

    //==========================================================================
    // 当前周期的最大差分值和最小绝对电平（用于 pending 累积）
    //==========================================================================
    
    // 比较器树：计算当前周期所有通道的最大差分值
    wire signed [DATA_WIDTH-1:0] max_diff_level1 [0:7];
    wire signed [DATA_WIDTH-1:0] max_diff_level2 [0:3];
    wire signed [DATA_WIDTH-1:0] max_diff_level3 [0:1];
    wire signed [DATA_WIDTH-1:0] max_diff_all;
    
    generate
        for (g = 0; g < 8; g = g + 1) begin : gen_max_l1
            assign max_diff_level1[g] = (diff_ch_pending[g*2] > diff_ch_pending[g*2+1]) ? 
                                         diff_ch_pending[g*2] : diff_ch_pending[g*2+1];
        end
        for (g = 0; g < 4; g = g + 1) begin : gen_max_l2
            assign max_diff_level2[g] = (max_diff_level1[g*2] > max_diff_level1[g*2+1]) ? 
                                         max_diff_level1[g*2] : max_diff_level1[g*2+1];
        end
        for (g = 0; g < 2; g = g + 1) begin : gen_max_l3
            assign max_diff_level3[g] = (max_diff_level2[g*2] > max_diff_level2[g*2+1]) ? 
                                         max_diff_level2[g*2] : max_diff_level2[g*2+1];
        end
    endgenerate
    assign max_diff_all = (max_diff_level3[0] > max_diff_level3[1]) ? 
                           max_diff_level3[0] : max_diff_level3[1];
    
    // 比较器树：计算当前周期所有通道的最小绝对电平
    wire signed [DATA_WIDTH-1:0] min_abs_level1 [0:7];
    wire signed [DATA_WIDTH-1:0] min_abs_level2 [0:3];
    wire signed [DATA_WIDTH-1:0] min_abs_level3 [0:1];
    wire signed [DATA_WIDTH-1:0] min_abs_all;
    
    //为何需要找到这个周期上的最小的绝对电平呢和最大的差分电平呢？这里
    //是为了处理跨周期的pending累积状态，先将本周期的最大差分和最小绝对电平计算出来
    //如果本周期没有被配对消耗的pending，而要计算（+，-）过零点的最大值，需要
    //保留pending的ch到ch15的最大差分和最小绝对电平
    generate
        for (g = 0; g < 8; g = g + 1) begin : gen_min_l1
            assign min_abs_level1[g] = (abs_ch_pending[g*2] < abs_ch_pending[g*2+1]) ? 
                                        abs_ch_pending[g*2] : abs_ch_pending[g*2+1];
        end
        for (g = 0; g < 4; g = g + 1) begin : gen_min_l2
            assign min_abs_level2[g] = (min_abs_level1[g*2] < min_abs_level1[g*2+1]) ? 
                                        min_abs_level1[g*2] : min_abs_level1[g*2+1];
        end
        for (g = 0; g < 2; g = g + 1) begin : gen_min_l3
            assign min_abs_level3[g] = (min_abs_level2[g*2] < min_abs_level2[g*2+1]) ? 
                                        min_abs_level2[g*2] : min_abs_level2[g*2+1];
        end
    endgenerate
    assign min_abs_all = (min_abs_level3[0] < min_abs_level3[1]) ? 
                          min_abs_level3[0] : min_abs_level3[1];

    //==========================================================================
    // Pending 累积状态
    //==========================================================================
    reg signed [DATA_WIDTH-1:0] saved_pending_max_diff;
    reg signed [DATA_WIDTH-1:0] saved_pending_min_abs;
    reg pending_accumulating;  // 是否正在累积
    
    // 计算从 pending_pos 到 ch15 的最大差分值（用于新 pending）
    wire signed [DATA_WIDTH-1:0] partial_max_from_pos [0:NUM_CHANNELS-1];
    wire signed [DATA_WIDTH-1:0] partial_min_from_pos [0:NUM_CHANNELS-1];
    
    // 从位置 i 到 ch15 的最大/最小值
    generate
        // 最后一个位置
        assign partial_max_from_pos[NUM_CHANNELS-1] = diff_ch_pending[NUM_CHANNELS-1];
        assign partial_min_from_pos[NUM_CHANNELS-1] = abs_ch_pending[NUM_CHANNELS-1];
        
        // 从后往前计算
        for (g = NUM_CHANNELS-2; g >= 0; g = g - 1) begin : gen_partial
            assign partial_max_from_pos[g] = (diff_ch_pending[g] > partial_max_from_pos[g+1]) ?
                                              diff_ch_pending[g] : partial_max_from_pos[g+1];
            assign partial_min_from_pos[g] = (abs_ch_pending[g] < partial_min_from_pos[g+1]) ?
                                              abs_ch_pending[g] : partial_min_from_pos[g+1];
        end
    endgenerate
    
    // 根据 pending_pos 选择起始位置的 partial 值
    wire signed [DATA_WIDTH-1:0] new_pending_partial_max;
    wire signed [DATA_WIDTH-1:0] new_pending_partial_min;
    
    assign new_pending_partial_max = partial_max_from_pos[mate_new_pending_pos];
    assign new_pending_partial_min = partial_min_from_pos[mate_new_pending_pos];
    
    // 判断 pending 是否被消耗（跨周期配对发生）
    wire pending_consumed = mate_pair_cross[0] && mate_pair_valid[0];
    
    // 判断 pending 是否保持（有 pending 但本周期没有被消耗）
    // mate_pending_valid 表示 ones_mate 内部有 pending
    // !pending_consumed 表示本周期没有跨周期配对消耗它
    // !mate_new_pending 表示不是新产生的 pending（新产生的在另一个分支处理）
    wire pending_hold = mate_pending_valid && !pending_consumed && !mate_new_pending;
    
    // Pending 累积更新
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            saved_pending_max_diff <= {1'b1, {(DATA_WIDTH-1){1'b0}}};  // 最小负数
            saved_pending_min_abs <= {1'b0, {(DATA_WIDTH-1){1'b1}}};   // 最大正数
            pending_accumulating <= 0;
        end
        else if (mate_valid_out) begin
            if (mate_new_pending) begin
                // 新 pending 产生：初始化累积值
                saved_pending_max_diff <= new_pending_partial_max;
                saved_pending_min_abs <= new_pending_partial_min;
                pending_accumulating <= 1'b1;
            end
            else if (pending_accumulating && pending_hold) begin
                // pending 保持（本周期没有配对消耗 pending）：累积更新
                // 整个周期 [0:15] 都在 [pos_a, pos_b) 范围内
                saved_pending_max_diff <= (saved_pending_max_diff > max_diff_all) ? 
                                           saved_pending_max_diff : max_diff_all;
                saved_pending_min_abs <= (saved_pending_min_abs < min_abs_all) ? 
                                          saved_pending_min_abs : min_abs_all;
            end
            else if (pending_consumed) begin
                // pending 被配对消耗：清除累积状态
                pending_accumulating <= 1'b0;
            end
        end
    end

    //==========================================================================
    // 阈值寄存（多级延迟以对齐流水线）
    //==========================================================================
    reg signed [DATA_WIDTH-1:0] diff_th_reg [0:3];
    reg signed [DATA_WIDTH-1:0] abs_th_neg_reg [0:3];  // -abs_threshold
    
    always @(posedge clk) begin
        diff_th_reg[0] <= diff_threshold;
        abs_th_neg_reg[0] <= -abs_threshold;
        diff_th_reg[1] <= diff_th_reg[0];
        abs_th_neg_reg[1] <= abs_th_neg_reg[0];
        diff_th_reg[2] <= diff_th_reg[1];
        abs_th_neg_reg[2] <= abs_th_neg_reg[1];
        diff_th_reg[3] <= diff_th_reg[2];
        abs_th_neg_reg[3] <= abs_th_neg_reg[2];
    end

    //==========================================================================
    // Stage P1: 预计算分段最大/最小值
    // 将 16 个通道分成 4 段，每段 4 个通道
    // 计算每段的最大差分值和最小绝对电平
    //==========================================================================
    
    // 分段最大/最小值（组合逻辑，2 级比较器树）
    // seg0: ch[0:3], seg1: ch[4:7], seg2: ch[8:11], seg3: ch[12:15]
    wire signed [DATA_WIDTH-1:0] seg_max_diff [0:3];
    wire signed [DATA_WIDTH-1:0] seg_min_abs [0:3];
    
    // 每段内的最大/最小（2 级比较器树）
    wire signed [DATA_WIDTH-1:0] seg_max_l1 [0:7];  // 8 个中间结果
    wire signed [DATA_WIDTH-1:0] seg_min_l1 [0:7];
    
    generate
        // Level 1: 两两比较
        for (g = 0; g < 8; g = g + 1) begin : gen_seg_l1
            assign seg_max_l1[g] = (diff_ch_p1[g*2] > diff_ch_p1[g*2+1]) ? 
                                    diff_ch_p1[g*2] : diff_ch_p1[g*2+1];
            assign seg_min_l1[g] = (abs_ch_p1[g*2] < abs_ch_p1[g*2+1]) ? 
                                    abs_ch_p1[g*2] : abs_ch_p1[g*2+1];
        end
        // Level 2: 每段的最终结果
        for (g = 0; g < 4; g = g + 1) begin : gen_seg_l2
            assign seg_max_diff[g] = (seg_max_l1[g*2] > seg_max_l1[g*2+1]) ? 
                                      seg_max_l1[g*2] : seg_max_l1[g*2+1];
            assign seg_min_abs[g] = (seg_min_l1[g*2] < seg_min_l1[g*2+1]) ? 
                                     seg_min_l1[g*2] : seg_min_l1[g*2+1];
        end
    endgenerate
    
    // Stage P1 寄存器
    reg signed [DATA_WIDTH-1:0] seg_max_diff_p1 [0:3];
    reg signed [DATA_WIDTH-1:0] seg_min_abs_p1 [0:3];
    reg signed [DATA_WIDTH-1:0] ch_diff_p1 [0:NUM_CHANNELS-1];  // 保留各通道值用于边界处理
    reg signed [DATA_WIDTH-1:0] ch_abs_p1 [0:NUM_CHANNELS-1];
    
    // 配对信息延迟
    reg [MAX_PAIRS-1:0] pair_valid_p1;
    reg [MAX_PAIRS*4-1:0] pair_pos_a_p1;
    reg [MAX_PAIRS*4-1:0] pair_pos_b_p1;
    reg [MAX_PAIRS-1:0] pair_cross_p1;
    reg valid_p1;
    
    // Pending 信息延迟
    reg signed [DATA_WIDTH-1:0] saved_pending_max_diff_p1;
    reg signed [DATA_WIDTH-1:0] saved_pending_min_abs_p1;
    
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 4; i = i + 1) begin
                seg_max_diff_p1[i] <= 0;
                seg_min_abs_p1[i] <= 0;
            end
            for (i = 0; i < NUM_CHANNELS; i = i + 1) begin
                ch_diff_p1[i] <= 0;
                ch_abs_p1[i] <= 0;
            end
            pair_valid_p1 <= 0;
            pair_pos_a_p1 <= 0;
            pair_pos_b_p1 <= 0;
            pair_cross_p1 <= 0;
            valid_p1 <= 0;
            saved_pending_max_diff_p1 <= 0;
            saved_pending_min_abs_p1 <= 0;
        end
        else begin
            // 分段结果
            for (i = 0; i < 4; i = i + 1) begin
                seg_max_diff_p1[i] <= seg_max_diff[i];
                seg_min_abs_p1[i] <= seg_min_abs[i];
            end
            // 各通道值
            for (i = 0; i < NUM_CHANNELS; i = i + 1) begin
                ch_diff_p1[i] <= diff_ch_p1[i];
                ch_abs_p1[i] <= abs_ch_p1[i];
            end
            // 配对信息
            pair_valid_p1 <= mate_pair_valid;
            pair_pos_a_p1 <= mate_pair_pos_a;
            pair_pos_b_p1 <= mate_pair_pos_b;
            pair_cross_p1 <= mate_pair_cross;
            valid_p1 <= mate_valid_out;
            // Pending 累积值
            saved_pending_max_diff_p1 <= saved_pending_max_diff;
            saved_pending_min_abs_p1 <= saved_pending_min_abs;
        end
    end

    //==========================================================================
    // Stage P2: 根据 pos_a/pos_b 选择并组合分段结果
    // 计算 [pos_a, pos_b) 范围的最大/最小值
    //==========================================================================
    
    // 提取 P1 阶段的配对位置
    wire [3:0] pos_a_p1 [0:MAX_PAIRS-1];
    wire [3:0] pos_b_p1 [0:MAX_PAIRS-1];
    
    generate
        for (p = 0; p < MAX_PAIRS; p = p + 1) begin : gen_pos_p1
            assign pos_a_p1[p] = pair_pos_a_p1[p*4 +: 4];
            assign pos_b_p1[p] = pair_pos_b_p1[p*4 +: 4];
        end
    endgenerate
    
    // 计算从 ch0 到 pos_b（包含）的分段组合最大/最小值
    // 使用分段结果 + 边界处理
    // pos_b 所在段：seg_idx = pos_b[3:2]
    // 需要包含 seg[0] 到 seg[seg_idx-1] 的完整段 + seg[seg_idx] 中 [0, pos_b[1:0]] 的部分
    
    // 组合逻辑：计算每对的范围最大/最小值
    reg signed [DATA_WIDTH-1:0] pair_max_diff_p2 [0:MAX_PAIRS-1];
    reg signed [DATA_WIDTH-1:0] pair_min_abs_p2 [0:MAX_PAIRS-1];
    reg [MAX_PAIRS-1:0] pair_valid_p2;
    reg [MAX_PAIRS-1:0] pair_cross_p2;
    reg valid_p2;
    
    // 计算 [0, pos_b] 范围的最大/最小值（用于跨周期配对）
    // 使用组合逻辑，根据 pos_b 选择
    function signed [DATA_WIDTH-1:0] max_to_pos;
        input [3:0] pos;
        input signed [DATA_WIDTH-1:0] seg0, seg1, seg2, seg3;
        input signed [DATA_WIDTH-1:0] ch0, ch1, ch2, ch3, ch4, ch5, ch6, ch7;
        input signed [DATA_WIDTH-1:0] ch8, ch9, ch10, ch11, ch12, ch13, ch14, ch15;
        reg signed [DATA_WIDTH-1:0] result;
        reg signed [DATA_WIDTH-1:0] partial;
        reg [1:0] seg_idx;
        reg [1:0] ch_idx;
        begin
            seg_idx = pos[3:2];
            ch_idx = pos[1:0];
            
            // 根据 pos 选择边界通道值
            case (pos)
                4'd0:  partial = ch0;
                4'd1:  partial = (ch0 > ch1) ? ch0 : ch1;
                4'd2:  partial = (ch0 > ch1) ? ((ch0 > ch2) ? ch0 : ch2) : ((ch1 > ch2) ? ch1 : ch2);
                4'd3:  partial = seg0;
                4'd4:  partial = (seg0 > ch4) ? seg0 : ch4;
                4'd5:  partial = (seg0 > ch4) ? ((seg0 > ch5) ? seg0 : ch5) : ((ch4 > ch5) ? ch4 : ch5);
                4'd6:  begin
                         result = (ch4 > ch5) ? ch4 : ch5;
                         result = (result > ch6) ? result : ch6;
                         partial = (seg0 > result) ? seg0 : result;
                       end
                4'd7:  partial = (seg0 > seg1) ? seg0 : seg1;
                4'd8:  begin
                         result = (seg0 > seg1) ? seg0 : seg1;
                         partial = (result > ch8) ? result : ch8;
                       end
                4'd9:  begin
                         result = (seg0 > seg1) ? seg0 : seg1;
                         partial = (ch8 > ch9) ? ch8 : ch9;
                         partial = (result > partial) ? result : partial;
                       end
                4'd10: begin
                         result = (seg0 > seg1) ? seg0 : seg1;
                         partial = (ch8 > ch9) ? ch8 : ch9;
                         partial = (partial > ch10) ? partial : ch10;
                         partial = (result > partial) ? result : partial;
                       end
                4'd11: begin
                         result = (seg0 > seg1) ? seg0 : seg1;
                         partial = (result > seg2) ? result : seg2;
                       end
                4'd12: begin
                         result = (seg0 > seg1) ? seg0 : seg1;
                         result = (result > seg2) ? result : seg2;
                         partial = (result > ch12) ? result : ch12;
                       end
                4'd13: begin
                         result = (seg0 > seg1) ? seg0 : seg1;
                         result = (result > seg2) ? result : seg2;
                         partial = (ch12 > ch13) ? ch12 : ch13;
                         partial = (result > partial) ? result : partial;
                       end
                4'd14: begin
                         result = (seg0 > seg1) ? seg0 : seg1;
                         result = (result > seg2) ? result : seg2;
                         partial = (ch12 > ch13) ? ch12 : ch13;
                         partial = (partial > ch14) ? partial : ch14;
                         partial = (result > partial) ? result : partial;
                       end
                4'd15: begin
                         result = (seg0 > seg1) ? seg0 : seg1;
                         result = (result > seg2) ? result : seg2;
                         partial = (result > seg3) ? result : seg3;
                       end
            endcase
            max_to_pos = partial;
        end
    endfunction
    
    function signed [DATA_WIDTH-1:0] min_to_pos;
        input [3:0] pos;
        input signed [DATA_WIDTH-1:0] seg0, seg1, seg2, seg3;
        input signed [DATA_WIDTH-1:0] ch0, ch1, ch2, ch3, ch4, ch5, ch6, ch7;
        input signed [DATA_WIDTH-1:0] ch8, ch9, ch10, ch11, ch12, ch13, ch14, ch15;
        reg signed [DATA_WIDTH-1:0] result;
        reg signed [DATA_WIDTH-1:0] partial;
        begin
            case (pos)
                4'd0:  partial = ch0;
                4'd1:  partial = (ch0 < ch1) ? ch0 : ch1;
                4'd2:  partial = (ch0 < ch1) ? ((ch0 < ch2) ? ch0 : ch2) : ((ch1 < ch2) ? ch1 : ch2);
                4'd3:  partial = seg0;
                4'd4:  partial = (seg0 < ch4) ? seg0 : ch4;
                4'd5:  partial = (seg0 < ch4) ? ((seg0 < ch5) ? seg0 : ch5) : ((ch4 < ch5) ? ch4 : ch5);
                4'd6:  begin
                         result = (ch4 < ch5) ? ch4 : ch5;
                         result = (result < ch6) ? result : ch6;
                         partial = (seg0 < result) ? seg0 : result;
                       end
                4'd7:  partial = (seg0 < seg1) ? seg0 : seg1;
                4'd8:  begin
                         result = (seg0 < seg1) ? seg0 : seg1;
                         partial = (result < ch8) ? result : ch8;
                       end
                4'd9:  begin
                         result = (seg0 < seg1) ? seg0 : seg1;
                         partial = (ch8 < ch9) ? ch8 : ch9;
                         partial = (result < partial) ? result : partial;
                       end
                4'd10: begin
                         result = (seg0 < seg1) ? seg0 : seg1;
                         partial = (ch8 < ch9) ? ch8 : ch9;
                         partial = (partial < ch10) ? partial : ch10;
                         partial = (result < partial) ? result : partial;
                       end
                4'd11: begin
                         result = (seg0 < seg1) ? seg0 : seg1;
                         partial = (result < seg2) ? result : seg2;
                       end
                4'd12: begin
                         result = (seg0 < seg1) ? seg0 : seg1;
                         result = (result < seg2) ? result : seg2;
                         partial = (result < ch12) ? result : ch12;
                       end
                4'd13: begin
                         result = (seg0 < seg1) ? seg0 : seg1;
                         result = (result < seg2) ? result : seg2;
                         partial = (ch12 < ch13) ? ch12 : ch13;
                         partial = (result < partial) ? result : partial;
                       end
                4'd14: begin
                         result = (seg0 < seg1) ? seg0 : seg1;
                         result = (result < seg2) ? result : seg2;
                         partial = (ch12 < ch13) ? ch12 : ch13;
                         partial = (partial < ch14) ? partial : ch14;
                         partial = (result < partial) ? result : partial;
                       end
                4'd15: begin
                         result = (seg0 < seg1) ? seg0 : seg1;
                         result = (result < seg2) ? result : seg2;
                         partial = (result < seg3) ? result : seg3;
                       end
            endcase
            min_to_pos = partial;
        end
    endfunction
    
    // 计算 [pos_a, pos_b] 范围的最大/最小值（用于同周期配对）
    // 简化：使用 max_to_pos(pos_b) 与边界通道值比较
    function signed [DATA_WIDTH-1:0] max_range;
        input [3:0] pos_a, pos_b;
        input signed [DATA_WIDTH-1:0] seg0, seg1, seg2, seg3;
        input signed [DATA_WIDTH-1:0] ch0, ch1, ch2, ch3, ch4, ch5, ch6, ch7;
        input signed [DATA_WIDTH-1:0] ch8, ch9, ch10, ch11, ch12, ch13, ch14, ch15;
        reg signed [DATA_WIDTH-1:0] max_val;
        reg signed [DATA_WIDTH-1:0] ch_val;
        integer k;
        begin
            // 初始化为 pos_a 位置的值
            case (pos_a)
                4'd0:  max_val = ch0;   4'd1:  max_val = ch1;
                4'd2:  max_val = ch2;   4'd3:  max_val = ch3;
                4'd4:  max_val = ch4;   4'd5:  max_val = ch5;
                4'd6:  max_val = ch6;   4'd7:  max_val = ch7;
                4'd8:  max_val = ch8;   4'd9:  max_val = ch9;
                4'd10: max_val = ch10;  4'd11: max_val = ch11;
                4'd12: max_val = ch12;  4'd13: max_val = ch13;
                4'd14: max_val = ch14;  4'd15: max_val = ch15;
            endcase
            
            // 遍历 [pos_a+1, pos_b] 范围
            for (k = 0; k < 16; k = k + 1) begin
                if (k > pos_a && k <= pos_b) begin
                    case (k)
                        4'd0:  ch_val = ch0;   4'd1:  ch_val = ch1;
                        4'd2:  ch_val = ch2;   4'd3:  ch_val = ch3;
                        4'd4:  ch_val = ch4;   4'd5:  ch_val = ch5;
                        4'd6:  ch_val = ch6;   4'd7:  ch_val = ch7;
                        4'd8:  ch_val = ch8;   4'd9:  ch_val = ch9;
                        4'd10: ch_val = ch10;  4'd11: ch_val = ch11;
                        4'd12: ch_val = ch12;  4'd13: ch_val = ch13;
                        4'd14: ch_val = ch14;  4'd15: ch_val = ch15;
                    endcase
                    if (ch_val > max_val) max_val = ch_val;
                end
            end
            max_range = max_val;
        end
    endfunction
    
    function signed [DATA_WIDTH-1:0] min_range;
        input [3:0] pos_a, pos_b;
        input signed [DATA_WIDTH-1:0] seg0, seg1, seg2, seg3;
        input signed [DATA_WIDTH-1:0] ch0, ch1, ch2, ch3, ch4, ch5, ch6, ch7;
        input signed [DATA_WIDTH-1:0] ch8, ch9, ch10, ch11, ch12, ch13, ch14, ch15;
        reg signed [DATA_WIDTH-1:0] min_val;
        reg signed [DATA_WIDTH-1:0] ch_val;
        integer k;
        begin
            case (pos_a)
                4'd0:  min_val = ch0;   4'd1:  min_val = ch1;
                4'd2:  min_val = ch2;   4'd3:  min_val = ch3;
                4'd4:  min_val = ch4;   4'd5:  min_val = ch5;
                4'd6:  min_val = ch6;   4'd7:  min_val = ch7;
                4'd8:  min_val = ch8;   4'd9:  min_val = ch9;
                4'd10: min_val = ch10;  4'd11: min_val = ch11;
                4'd12: min_val = ch12;  4'd13: min_val = ch13;
                4'd14: min_val = ch14;  4'd15: min_val = ch15;
            endcase
            
            for (k = 0; k < 16; k = k + 1) begin
                if (k > pos_a && k <= pos_b) begin
                    case (k)
                        4'd0:  ch_val = ch0;   4'd1:  ch_val = ch1;
                        4'd2:  ch_val = ch2;   4'd3:  ch_val = ch3;
                        4'd4:  ch_val = ch4;   4'd5:  ch_val = ch5;
                        4'd6:  ch_val = ch6;   4'd7:  ch_val = ch7;
                        4'd8:  ch_val = ch8;   4'd9:  ch_val = ch9;
                        4'd10: ch_val = ch10;  4'd11: ch_val = ch11;
                        4'd12: ch_val = ch12;  4'd13: ch_val = ch13;
                        4'd14: ch_val = ch14;  4'd15: ch_val = ch15;
                    endcase
                    if (ch_val < min_val) min_val = ch_val;
                end
            end
            min_range = min_val;
        end
    endfunction
    
    // Stage P2 寄存器
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < MAX_PAIRS; i = i + 1) begin
                pair_max_diff_p2[i] <= 0;
                pair_min_abs_p2[i] <= 0;
            end
            pair_valid_p2 <= 0;
            pair_cross_p2 <= 0;
            valid_p2 <= 0;
        end
        else begin
            valid_p2 <= valid_p1;
            pair_valid_p2 <= pair_valid_p1;
            pair_cross_p2 <= pair_cross_p1;
            
            // pair[0]: 可能跨周期
            if (pair_cross_p1[0]) begin
                // 跨周期：使用累积的 saved_pending 值与当前周期 [0, pos_b) 比较
                pair_max_diff_p2[0] <= (saved_pending_max_diff_p1 > 
                    max_to_pos(pos_b_p1[0], 
                        seg_max_diff_p1[0], seg_max_diff_p1[1], seg_max_diff_p1[2], seg_max_diff_p1[3],
                        ch_diff_p1[0], ch_diff_p1[1], ch_diff_p1[2], ch_diff_p1[3],
                        ch_diff_p1[4], ch_diff_p1[5], ch_diff_p1[6], ch_diff_p1[7],
                        ch_diff_p1[8], ch_diff_p1[9], ch_diff_p1[10], ch_diff_p1[11],
                        ch_diff_p1[12], ch_diff_p1[13], ch_diff_p1[14], ch_diff_p1[15])) ?
                    saved_pending_max_diff_p1 :
                    max_to_pos(pos_b_p1[0],
                        seg_max_diff_p1[0], seg_max_diff_p1[1], seg_max_diff_p1[2], seg_max_diff_p1[3],
                        ch_diff_p1[0], ch_diff_p1[1], ch_diff_p1[2], ch_diff_p1[3],
                        ch_diff_p1[4], ch_diff_p1[5], ch_diff_p1[6], ch_diff_p1[7],
                        ch_diff_p1[8], ch_diff_p1[9], ch_diff_p1[10], ch_diff_p1[11],
                        ch_diff_p1[12], ch_diff_p1[13], ch_diff_p1[14], ch_diff_p1[15]);
                        
                pair_min_abs_p2[0] <= (saved_pending_min_abs_p1 < 
                    min_to_pos(pos_b_p1[0],
                        seg_min_abs_p1[0], seg_min_abs_p1[1], seg_min_abs_p1[2], seg_min_abs_p1[3],
                        ch_abs_p1[0], ch_abs_p1[1], ch_abs_p1[2], ch_abs_p1[3],
                        ch_abs_p1[4], ch_abs_p1[5], ch_abs_p1[6], ch_abs_p1[7],
                        ch_abs_p1[8], ch_abs_p1[9], ch_abs_p1[10], ch_abs_p1[11],
                        ch_abs_p1[12], ch_abs_p1[13], ch_abs_p1[14], ch_abs_p1[15])) ?
                    saved_pending_min_abs_p1 :
                    min_to_pos(pos_b_p1[0],
                        seg_min_abs_p1[0], seg_min_abs_p1[1], seg_min_abs_p1[2], seg_min_abs_p1[3],
                        ch_abs_p1[0], ch_abs_p1[1], ch_abs_p1[2], ch_abs_p1[3],
                        ch_abs_p1[4], ch_abs_p1[5], ch_abs_p1[6], ch_abs_p1[7],
                        ch_abs_p1[8], ch_abs_p1[9], ch_abs_p1[10], ch_abs_p1[11],
                        ch_abs_p1[12], ch_abs_p1[13], ch_abs_p1[14], ch_abs_p1[15]);
            end
            else begin
                // 同周期：计算 [pos_a, pos_b] 范围
                pair_max_diff_p2[0] <= max_range(pos_a_p1[0], pos_b_p1[0],
                    seg_max_diff_p1[0], seg_max_diff_p1[1], seg_max_diff_p1[2], seg_max_diff_p1[3],
                    ch_diff_p1[0], ch_diff_p1[1], ch_diff_p1[2], ch_diff_p1[3],
                    ch_diff_p1[4], ch_diff_p1[5], ch_diff_p1[6], ch_diff_p1[7],
                    ch_diff_p1[8], ch_diff_p1[9], ch_diff_p1[10], ch_diff_p1[11],
                    ch_diff_p1[12], ch_diff_p1[13], ch_diff_p1[14], ch_diff_p1[15]);
                    
                pair_min_abs_p2[0] <= min_range(pos_a_p1[0], pos_b_p1[0],
                    seg_min_abs_p1[0], seg_min_abs_p1[1], seg_min_abs_p1[2], seg_min_abs_p1[3],
                    ch_abs_p1[0], ch_abs_p1[1], ch_abs_p1[2], ch_abs_p1[3],
                    ch_abs_p1[4], ch_abs_p1[5], ch_abs_p1[6], ch_abs_p1[7],
                    ch_abs_p1[8], ch_abs_p1[9], ch_abs_p1[10], ch_abs_p1[11],
                    ch_abs_p1[12], ch_abs_p1[13], ch_abs_p1[14], ch_abs_p1[15]);
            end
            
            // pair[1~7]: 同周期配对
            for (i = 1; i < MAX_PAIRS; i = i + 1) begin
                pair_max_diff_p2[i] <= max_range(pos_a_p1[i], pos_b_p1[i],
                    seg_max_diff_p1[0], seg_max_diff_p1[1], seg_max_diff_p1[2], seg_max_diff_p1[3],
                    ch_diff_p1[0], ch_diff_p1[1], ch_diff_p1[2], ch_diff_p1[3],
                    ch_diff_p1[4], ch_diff_p1[5], ch_diff_p1[6], ch_diff_p1[7],
                    ch_diff_p1[8], ch_diff_p1[9], ch_diff_p1[10], ch_diff_p1[11],
                    ch_diff_p1[12], ch_diff_p1[13], ch_diff_p1[14], ch_diff_p1[15]);
                    
                pair_min_abs_p2[i] <= min_range(pos_a_p1[i], pos_b_p1[i],
                    seg_min_abs_p1[0], seg_min_abs_p1[1], seg_min_abs_p1[2], seg_min_abs_p1[3],
                    ch_abs_p1[0], ch_abs_p1[1], ch_abs_p1[2], ch_abs_p1[3],
                    ch_abs_p1[4], ch_abs_p1[5], ch_abs_p1[6], ch_abs_p1[7],
                    ch_abs_p1[8], ch_abs_p1[9], ch_abs_p1[10], ch_abs_p1[11],
                    ch_abs_p1[12], ch_abs_p1[13], ch_abs_p1[14], ch_abs_p1[15]);
            end
        end
    end

    //==========================================================================
    // Stage V1: 阈值比较（使用 P2 阶段的输出）
    //==========================================================================
    reg [MAX_PAIRS-1:0] diff_ok_v1;
    reg [MAX_PAIRS-1:0] abs_negative_v1;
    reg [MAX_PAIRS-1:0] abs_amp_ok_v1;
    reg [MAX_PAIRS-1:0] pair_valid_v1;
    reg valid_v1;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            diff_ok_v1 <= 0;
            abs_negative_v1 <= 0;
            abs_amp_ok_v1 <= 0;
            pair_valid_v1 <= 0;
            valid_v1 <= 0;
        end
        else begin
            valid_v1 <= valid_p2;
            pair_valid_v1 <= pair_valid_p2;
            
            for (i = 0; i < MAX_PAIRS; i = i + 1) begin
                // 差分最大值 > 阈值
                diff_ok_v1[i] <= (pair_max_diff_p2[i] > diff_th_reg[2]);
                // 绝对电平为负
                abs_negative_v1[i] <= (pair_min_abs_p2[i] < 0);
                // |绝对电平| > 阈值，即 abs < -threshold
                abs_amp_ok_v1[i] <= (pair_min_abs_p2[i] < abs_th_neg_reg[2]);
            end
        end
    end

    //==========================================================================
    // Stage V2: 综合验证
    //==========================================================================
    reg [MAX_PAIRS-1:0] pair_verified_v2;
    reg valid_v2;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pair_verified_v2 <= 0;
            valid_v2 <= 0;
        end
        else begin
            valid_v2 <= valid_v1;
            
            for (i = 0; i < MAX_PAIRS; i = i + 1) begin
                pair_verified_v2[i] <= pair_valid_v1[i] && diff_ok_v1[i] && 
                                       abs_negative_v1[i] && abs_amp_ok_v1[i];
            end
        end
    end

    //==========================================================================
    // Stage V3: 计数有效脉冲 + 输出
    //==========================================================================
    wire [4:0] popcount_result;
    assign popcount_result = pair_verified_v2[0] + pair_verified_v2[1] + 
                             pair_verified_v2[2] + pair_verified_v2[3] +
                             pair_verified_v2[4] + pair_verified_v2[5] + 
                             pair_verified_v2[6] + pair_verified_v2[7];
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pulse_count <= 0;
            valid_out <= 0;
        end
        else begin
            valid_out <= valid_v2;
            pulse_count <= popcount_result;
        end
    end

endmodule
