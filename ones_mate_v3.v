`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: ones_mate_v3
// Description: 过零点配对模块（基于方向信息的增强版）
//
// 功能：
//   1. 根据过零方向（正向/负向）进行配对
//   2. 正向过零（负→正）= 脉冲起点，负向过零（正→负）= 脉冲终点
//   3. 配对规则：正向 + 其后的负向 = 一个完整脉冲
//   4. 跨周期处理：只有正向过零点会进入 pending 状态
//
// 架构：双路径设计（v3 改进）
//   快速路径（1周期）：pending_valid/pos 的更新，供下一周期使用
//   慢速路径（4周期）：配对细节计算，流水线输出
//
// 输入：
//   zero_mask[15:0]：过零掩码
//   zero_direction[15:0]：过零方向（1=正向，0=负向）
//
// 输出：
//   pair_valid[MAX_PAIRS-1:0]：每对是否有效
//   pair_pos_a[MAX_PAIRS*4-1:0]：每对的起点位置（正向过零点）
//   pair_pos_b[MAX_PAIRS*4-1:0]：每对的终点位置（负向过零点）
//   pair_cross_cycle[MAX_PAIRS-1:0]：该对是否跨周期
//   total_pairs[4:0]：有效配对数
//   new_pending_out：是否产生新的 pending
//   new_pending_pos_out[3:0]：新 pending 的位置
//
// 流水线延迟：4个时钟周期（配对输出）
// pending 更新延迟：1个时钟周期（快速路径）
//////////////////////////////////////////////////////////////////////////////////

module ones_mate_v3 #(
    parameter NUM_CHANNELS = 16,
    parameter MAX_PAIRS = 8
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     valid_in,
    input  wire [NUM_CHANNELS-1:0]  zero_mask,       // 过零掩码
    input  wire [NUM_CHANNELS-1:0]  zero_direction,  // 过零方向（1=正向，0=负向）
    
    // 配对结果（慢速路径，4周期延迟）
    output reg  [MAX_PAIRS-1:0]     pair_valid,      // 每对是否有效
    output reg  [MAX_PAIRS*4-1:0]   pair_pos_a,      // 起点位置（正向）
    output reg  [MAX_PAIRS*4-1:0]   pair_pos_b,      // 终点位置（负向）
    output reg  [MAX_PAIRS-1:0]     pair_cross_cycle,// 是否跨周期
    output reg  [4:0]               total_pairs,     // 有效配对数
    output reg                      valid_out,
    
    // pending 状态输出（快速路径，1周期延迟）
    output reg                      pending_valid_out,   // 当前是否有 pending
    output reg  [3:0]               pending_pos_out,     // pending 位置
    output reg                      new_pending_out,     // 是否产生新 pending
    output reg  [3:0]               new_pending_pos_out, // 新 pending 位置
    
    // 流水线延迟指示
    output wire [2:0]               pipeline_delay
);

    assign pipeline_delay = 3'd4;

    //==========================================================================
    // 快速路径：Pending 状态计算（组合逻辑 + 1级寄存）
    // 必须在 1 个周期内完成，供下一周期使用
    //==========================================================================
    
    // Pending 状态寄存器
    reg pending_valid_reg;
    reg [3:0] pending_pos_reg;
    
    //--------------------------------------------------------------------------
    // 组合逻辑：分离正向/负向掩码
    //--------------------------------------------------------------------------
    wire [NUM_CHANNELS-1:0] pos_mask_comb;
    wire [NUM_CHANNELS-1:0] neg_mask_comb;
    
    genvar g;
    generate
        for (g = 0; g < NUM_CHANNELS; g = g + 1) begin : gen_separate
            assign pos_mask_comb[g] = zero_mask[g] && zero_direction[g];   // 正向
            assign neg_mask_comb[g] = zero_mask[g] && !zero_direction[g];  // 负向
        end
    endgenerate
    
    //--------------------------------------------------------------------------
    // 组合逻辑：计算 total_pos 和 total_neg（前缀和）
    //--------------------------------------------------------------------------
    wire [4:0] pos_prefix_comb [0:NUM_CHANNELS];
    wire [4:0] neg_prefix_comb [0:NUM_CHANNELS];
    
    assign pos_prefix_comb[0] = 5'd0;
    assign neg_prefix_comb[0] = 5'd0;
    
    generate
        for (g = 0; g < NUM_CHANNELS; g = g + 1) begin : gen_prefix
            assign pos_prefix_comb[g+1] = pos_prefix_comb[g] + pos_mask_comb[g];
            assign neg_prefix_comb[g+1] = neg_prefix_comb[g] + neg_mask_comb[g];
        end
    endgenerate
    
    wire [4:0] total_pos_comb = pos_prefix_comb[NUM_CHANNELS];
    wire [4:0] total_neg_comb = neg_prefix_comb[NUM_CHANNELS];
    
    //--------------------------------------------------------------------------
    // 组合逻辑：判断下一周期是否有 pending
    //--------------------------------------------------------------------------
    // 有效正向数 = 本周期正向 + 历史 pending
    wire [4:0] effective_pos_comb = total_pos_comb + pending_valid_reg;
    
    // 情况1：新产生的 pending（本周期有正向过零点未被配对）
    wire new_pending_from_current = (effective_pos_comb > total_neg_comb) && (total_pos_comb > 0);
    
    // 情况2：保持上周期的 pending（有历史 pending 且本周期没有负向来消耗它）
    wire pending_hold_comb = pending_valid_reg && (total_neg_comb == 0);
    
    // 下一周期是否有 pending（两种情况的或）
    wire next_pending_valid_comb = new_pending_from_current || pending_hold_comb;
    
    // 是否是"新产生"的 pending（用于输出 new_pending_out 信号）
    wire new_pending_valid_comb = new_pending_from_current;
    
    // new_pending 是第几个正向过零点（0-based 索引）
    // 如果有历史 pending：已配对的本周期正向数 = total_neg - 1
    // 如果无历史 pending：已配对的本周期正向数 = total_neg
    // new_pending 索引 = 已配对数（因为是 0-based）
    wire [4:0] pending_idx_comb = pending_valid_reg ? (total_neg_comb - 1) : total_neg_comb;
    
    //--------------------------------------------------------------------------
    // 组合逻辑：提取第 pending_idx 个正向过零点的位置
    // 使用并行优先编码器
    //--------------------------------------------------------------------------
    
    // 预计算每个正向过零点的位置
    // pos_positions[n] = 第 n 个正向过零点的位置（0-based）
    wire [3:0] pos_positions_comb [0:MAX_PAIRS-1];
    
    // 使用 prefix sum 判断每个位置是"第几个"正向过零点
    // 如果 pos_mask_comb[i]=1 且 pos_prefix_comb[i]=n，则位置 i 是第 n 个正向
    
    generate
        for (g = 0; g < MAX_PAIRS; g = g + 1) begin : gen_pos_positions
            // 找到第 g 个正向过零点的位置
            assign pos_positions_comb[g] = 
                (pos_mask_comb[0]  && pos_prefix_comb[0]  == g) ? 4'd0  :
                (pos_mask_comb[1]  && pos_prefix_comb[1]  == g) ? 4'd1  :
                (pos_mask_comb[2]  && pos_prefix_comb[2]  == g) ? 4'd2  :
                (pos_mask_comb[3]  && pos_prefix_comb[3]  == g) ? 4'd3  :
                (pos_mask_comb[4]  && pos_prefix_comb[4]  == g) ? 4'd4  :
                (pos_mask_comb[5]  && pos_prefix_comb[5]  == g) ? 4'd5  :
                (pos_mask_comb[6]  && pos_prefix_comb[6]  == g) ? 4'd6  :
                (pos_mask_comb[7]  && pos_prefix_comb[7]  == g) ? 4'd7  :
                (pos_mask_comb[8]  && pos_prefix_comb[8]  == g) ? 4'd8  :
                (pos_mask_comb[9]  && pos_prefix_comb[9]  == g) ? 4'd9  :
                (pos_mask_comb[10] && pos_prefix_comb[10] == g) ? 4'd10 :
                (pos_mask_comb[11] && pos_prefix_comb[11] == g) ? 4'd11 :
                (pos_mask_comb[12] && pos_prefix_comb[12] == g) ? 4'd12 :
                (pos_mask_comb[13] && pos_prefix_comb[13] == g) ? 4'd13 :
                (pos_mask_comb[14] && pos_prefix_comb[14] == g) ? 4'd14 :
                (pos_mask_comb[15] && pos_prefix_comb[15] == g) ? 4'd15 : 4'd0;
        end
    endgenerate
    
    // 根据 pending_idx 选择 new_pending 的位置
    wire [3:0] new_pending_pos_comb;
    assign new_pending_pos_comb = 
        (pending_idx_comb[2:0] == 3'd0) ? pos_positions_comb[0] :
        (pending_idx_comb[2:0] == 3'd1) ? pos_positions_comb[1] :
        (pending_idx_comb[2:0] == 3'd2) ? pos_positions_comb[2] :
        (pending_idx_comb[2:0] == 3'd3) ? pos_positions_comb[3] :
        (pending_idx_comb[2:0] == 3'd4) ? pos_positions_comb[4] :
        (pending_idx_comb[2:0] == 3'd5) ? pos_positions_comb[5] :
        (pending_idx_comb[2:0] == 3'd6) ? pos_positions_comb[6] :
        pos_positions_comb[7];
    
    //--------------------------------------------------------------------------
    // 快速路径寄存器更新（1周期延迟）
    //--------------------------------------------------------------------------
    reg valid_fast;
    
    // 下一周期的 pending 位置
    // - 如果是新产生的 pending：使用 new_pending_pos_comb
    // - 如果是保持的 pending：保持原来的 pending_pos_reg
    wire [3:0] next_pending_pos_comb = new_pending_from_current ? new_pending_pos_comb : pending_pos_reg;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending_valid_reg <= 1'b0;
            pending_pos_reg <= 4'd0;
            pending_valid_out <= 1'b0;
            pending_pos_out <= 4'd0;
            new_pending_out <= 1'b0;
            new_pending_pos_out <= 4'd0;
            valid_fast <= 1'b0;
        end
        else begin
            valid_fast <= valid_in;
            
            if (valid_in) begin
                // 更新 pending 状态（供下一周期使用）
                // 使用 next_pending_valid_comb（包含新产生和保持两种情况）
                pending_valid_reg <= next_pending_valid_comb;
                pending_pos_reg <= next_pending_valid_comb ? next_pending_pos_comb : 4'd0;
                
                // 输出当前周期的 pending 信息（更新前的值）
                pending_valid_out <= pending_valid_reg;
                pending_pos_out <= pending_pos_reg;
                
                // 输出 new_pending 信息（只有真正新产生时才为 1）
                new_pending_out <= new_pending_valid_comb;
                new_pending_pos_out <= new_pending_pos_comb;
            end
        end
    end

    //==========================================================================
    // 慢速路径：配对细节计算（4级流水线）
    // 这些数据不需要给下一周期使用，可以慢慢算
    //==========================================================================
    
    //--------------------------------------------------------------------------
    // Stage 1: 输入寄存 + 保存快速路径计算结果
    //--------------------------------------------------------------------------
    reg [NUM_CHANNELS-1:0] pos_mask_s1;
    reg [NUM_CHANNELS-1:0] neg_mask_s1;
    reg [4:0] pos_prefix_s1 [0:NUM_CHANNELS-1];
    reg [4:0] neg_prefix_s1 [0:NUM_CHANNELS-1];
    reg [4:0] total_pos_s1;
    reg [4:0] total_neg_s1;
    reg pending_valid_s1;  // 本周期使用的 pending（来自上周期）
    reg [3:0] pending_pos_s1;
    reg valid_s1;
    
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pos_mask_s1 <= 0;
            neg_mask_s1 <= 0;
            total_pos_s1 <= 0;
            total_neg_s1 <= 0;
            pending_valid_s1 <= 0;
            pending_pos_s1 <= 0;
            valid_s1 <= 0;
            for (i = 0; i < NUM_CHANNELS; i = i + 1) begin
                pos_prefix_s1[i] <= 0;
                neg_prefix_s1[i] <= 0;
            end
        end
        else begin
            pos_mask_s1 <= pos_mask_comb;
            neg_mask_s1 <= neg_mask_comb;
            total_pos_s1 <= total_pos_comb;
            total_neg_s1 <= total_neg_comb;
            // 注意：这里保存的是"本周期使用的 pending"，即更新前的值
            pending_valid_s1 <= pending_valid_reg;
            pending_pos_s1 <= pending_pos_reg;
            valid_s1 <= valid_in;
            
            for (i = 0; i < NUM_CHANNELS; i = i + 1) begin
                pos_prefix_s1[i] <= pos_prefix_comb[i];
                neg_prefix_s1[i] <= neg_prefix_comb[i];
            end
        end
    end

    //--------------------------------------------------------------------------
    // Stage 2: 位置提取
    //--------------------------------------------------------------------------
    
    // 正向：is_pos_nth[i][n] = 1 表示位置 i 是第 n 个正向过零点
    wire is_pos_nth [0:NUM_CHANNELS-1][0:MAX_PAIRS-1];
    generate
        for (g = 0; g < NUM_CHANNELS; g = g + 1) begin : gen_is_pos_nth_outer
            genvar n;
            for (n = 0; n < MAX_PAIRS; n = n + 1) begin : gen_is_pos_nth_inner
                assign is_pos_nth[g][n] = pos_mask_s1[g] && (pos_prefix_s1[g] == n);
            end
        end
    endgenerate
    
    // 负向：is_neg_nth[i][n] = 1 表示位置 i 是第 n 个负向过零点
    wire is_neg_nth [0:NUM_CHANNELS-1][0:MAX_PAIRS-1];
    generate
        for (g = 0; g < NUM_CHANNELS; g = g + 1) begin : gen_is_neg_nth_outer
            genvar n;
            for (n = 0; n < MAX_PAIRS; n = n + 1) begin : gen_is_neg_nth_inner
                assign is_neg_nth[g][n] = neg_mask_s1[g] && (neg_prefix_s1[g] == n);
            end
        end
    endgenerate
    
    // 提取正向过零点位置
    wire [3:0] pos_extracted [0:MAX_PAIRS-1];
    generate
        for (g = 0; g < MAX_PAIRS; g = g + 1) begin : gen_pos_extract
            assign pos_extracted[g] = 
                is_pos_nth[0][g]  ? 4'd0  :
                is_pos_nth[1][g]  ? 4'd1  :
                is_pos_nth[2][g]  ? 4'd2  :
                is_pos_nth[3][g]  ? 4'd3  :
                is_pos_nth[4][g]  ? 4'd4  :
                is_pos_nth[5][g]  ? 4'd5  :
                is_pos_nth[6][g]  ? 4'd6  :
                is_pos_nth[7][g]  ? 4'd7  :
                is_pos_nth[8][g]  ? 4'd8  :
                is_pos_nth[9][g]  ? 4'd9  :
                is_pos_nth[10][g] ? 4'd10 :
                is_pos_nth[11][g] ? 4'd11 :
                is_pos_nth[12][g] ? 4'd12 :
                is_pos_nth[13][g] ? 4'd13 :
                is_pos_nth[14][g] ? 4'd14 :
                is_pos_nth[15][g] ? 4'd15 : 4'd0;
        end
    endgenerate
    
    // 提取负向过零点位置
    wire [3:0] neg_extracted [0:MAX_PAIRS-1];
    generate
        for (g = 0; g < MAX_PAIRS; g = g + 1) begin : gen_neg_extract
            assign neg_extracted[g] = 
                is_neg_nth[0][g]  ? 4'd0  :
                is_neg_nth[1][g]  ? 4'd1  :
                is_neg_nth[2][g]  ? 4'd2  :
                is_neg_nth[3][g]  ? 4'd3  :
                is_neg_nth[4][g]  ? 4'd4  :
                is_neg_nth[5][g]  ? 4'd5  :
                is_neg_nth[6][g]  ? 4'd6  :
                is_neg_nth[7][g]  ? 4'd7  :
                is_neg_nth[8][g]  ? 4'd8  :
                is_neg_nth[9][g]  ? 4'd9  :
                is_neg_nth[10][g] ? 4'd10 :
                is_neg_nth[11][g] ? 4'd11 :
                is_neg_nth[12][g] ? 4'd12 :
                is_neg_nth[13][g] ? 4'd13 :
                is_neg_nth[14][g] ? 4'd14 :
                is_neg_nth[15][g] ? 4'd15 : 4'd0;
        end
    endgenerate
    
    // Stage 2 寄存
    reg [3:0] pos_pos_s2 [0:MAX_PAIRS-1];
    reg [3:0] neg_pos_s2 [0:MAX_PAIRS-1];
    reg [4:0] total_pos_s2;
    reg [4:0] total_neg_s2;
    reg pending_valid_s2;
    reg [3:0] pending_pos_s2;
    reg valid_s2;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            total_pos_s2 <= 0;
            total_neg_s2 <= 0;
            pending_valid_s2 <= 0;
            pending_pos_s2 <= 0;
            valid_s2 <= 0;
            for (i = 0; i < MAX_PAIRS; i = i + 1) begin
                pos_pos_s2[i] <= 0;
                neg_pos_s2[i] <= 0;
            end
        end
        else begin
            total_pos_s2 <= total_pos_s1;
            total_neg_s2 <= total_neg_s1;
            pending_valid_s2 <= pending_valid_s1;
            pending_pos_s2 <= pending_pos_s1;
            valid_s2 <= valid_s1;
            
            for (i = 0; i < MAX_PAIRS; i = i + 1) begin
                pos_pos_s2[i] <= pos_extracted[i];
                neg_pos_s2[i] <= neg_extracted[i];
            end
        end
    end

    //--------------------------------------------------------------------------
    // Stage 3: 配对逻辑
    //--------------------------------------------------------------------------
    
    reg [MAX_PAIRS-1:0] pair_valid_s3;
    reg [3:0] pair_pos_a_s3 [0:MAX_PAIRS-1];
    reg [3:0] pair_pos_b_s3 [0:MAX_PAIRS-1];
    reg [MAX_PAIRS-1:0] pair_cross_s3;
    reg [4:0] total_pairs_s3;
    reg valid_s3;
    
    // 配对数计算
    wire [4:0] effective_pos_s2 = total_pos_s2 + pending_valid_s2;
    wire [4:0] calc_pairs = (effective_pos_s2 <= total_neg_s2) ? effective_pos_s2 : total_neg_s2;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pair_valid_s3 <= 0;
            pair_cross_s3 <= 0;
            total_pairs_s3 <= 0;
            valid_s3 <= 0;
            for (i = 0; i < MAX_PAIRS; i = i + 1) begin
                pair_pos_a_s3[i] <= 0;
                pair_pos_b_s3[i] <= 0;
            end
        end
        else begin
            valid_s3 <= valid_s2;
            total_pairs_s3 <= calc_pairs;
            
            if (pending_valid_s2 && total_neg_s2 == 0) begin
                // 有 pending 但本周期没有负向过零点 - 无配对
                pair_valid_s3 <= 0;
                pair_cross_s3 <= 0;
                for (i = 0; i < MAX_PAIRS; i = i + 1) begin
                    pair_pos_a_s3[i] <= 0;
                    pair_pos_b_s3[i] <= 0;
                end
            end
            else if (pending_valid_s2) begin
                // 有 pending，与第1个负向配对（跨周期）
                pair_pos_a_s3[0] <= pending_pos_s2;
                pair_pos_b_s3[0] <= neg_pos_s2[0];
                pair_valid_s3[0] <= (total_neg_s2 >= 1);
                pair_cross_s3[0] <= 1'b1;
                
                // 后续配对：pos[i] 配 neg[i+1]
                pair_pos_a_s3[1] <= pos_pos_s2[0];
                pair_pos_b_s3[1] <= neg_pos_s2[1];
                pair_valid_s3[1] <= (total_pos_s2 >= 1) && (total_neg_s2 >= 2);
                pair_cross_s3[1] <= 1'b0;
                
                pair_pos_a_s3[2] <= pos_pos_s2[1];
                pair_pos_b_s3[2] <= neg_pos_s2[2];
                pair_valid_s3[2] <= (total_pos_s2 >= 2) && (total_neg_s2 >= 3);
                pair_cross_s3[2] <= 1'b0;
                
                pair_pos_a_s3[3] <= pos_pos_s2[2];
                pair_pos_b_s3[3] <= neg_pos_s2[3];
                pair_valid_s3[3] <= (total_pos_s2 >= 3) && (total_neg_s2 >= 4);
                pair_cross_s3[3] <= 1'b0;
                
                pair_pos_a_s3[4] <= pos_pos_s2[3];
                pair_pos_b_s3[4] <= neg_pos_s2[4];
                pair_valid_s3[4] <= (total_pos_s2 >= 4) && (total_neg_s2 >= 5);
                pair_cross_s3[4] <= 1'b0;
                
                pair_pos_a_s3[5] <= pos_pos_s2[4];
                pair_pos_b_s3[5] <= neg_pos_s2[5];
                pair_valid_s3[5] <= (total_pos_s2 >= 5) && (total_neg_s2 >= 6);
                pair_cross_s3[5] <= 1'b0;
                
                pair_pos_a_s3[6] <= pos_pos_s2[5];
                pair_pos_b_s3[6] <= neg_pos_s2[6];
                pair_valid_s3[6] <= (total_pos_s2 >= 6) && (total_neg_s2 >= 7);
                pair_cross_s3[6] <= 1'b0;
                
                pair_pos_a_s3[7] <= pos_pos_s2[6];
                pair_pos_b_s3[7] <= neg_pos_s2[7];
                pair_valid_s3[7] <= (total_pos_s2 >= 7) && (total_neg_s2 >= 8);
                pair_cross_s3[7] <= 1'b0;
            end
            else begin
                // 无 pending，正常配对：pos[i] 配 neg[i]
                pair_pos_a_s3[0] <= pos_pos_s2[0];
                pair_pos_b_s3[0] <= neg_pos_s2[0];
                pair_valid_s3[0] <= (total_pos_s2 >= 1) && (total_neg_s2 >= 1);
                pair_cross_s3[0] <= 1'b0;
                
                pair_pos_a_s3[1] <= pos_pos_s2[1];
                pair_pos_b_s3[1] <= neg_pos_s2[1];
                pair_valid_s3[1] <= (total_pos_s2 >= 2) && (total_neg_s2 >= 2);
                pair_cross_s3[1] <= 1'b0;
                
                pair_pos_a_s3[2] <= pos_pos_s2[2];
                pair_pos_b_s3[2] <= neg_pos_s2[2];
                pair_valid_s3[2] <= (total_pos_s2 >= 3) && (total_neg_s2 >= 3);
                pair_cross_s3[2] <= 1'b0;
                
                pair_pos_a_s3[3] <= pos_pos_s2[3];
                pair_pos_b_s3[3] <= neg_pos_s2[3];
                pair_valid_s3[3] <= (total_pos_s2 >= 4) && (total_neg_s2 >= 4);
                pair_cross_s3[3] <= 1'b0;
                
                pair_pos_a_s3[4] <= pos_pos_s2[4];
                pair_pos_b_s3[4] <= neg_pos_s2[4];
                pair_valid_s3[4] <= (total_pos_s2 >= 5) && (total_neg_s2 >= 5);
                pair_cross_s3[4] <= 1'b0;
                
                pair_pos_a_s3[5] <= pos_pos_s2[5];
                pair_pos_b_s3[5] <= neg_pos_s2[5];
                pair_valid_s3[5] <= (total_pos_s2 >= 6) && (total_neg_s2 >= 6);
                pair_cross_s3[5] <= 1'b0;
                
                pair_pos_a_s3[6] <= pos_pos_s2[6];
                pair_pos_b_s3[6] <= neg_pos_s2[6];
                pair_valid_s3[6] <= (total_pos_s2 >= 7) && (total_neg_s2 >= 7);
                pair_cross_s3[6] <= 1'b0;
                
                pair_pos_a_s3[7] <= pos_pos_s2[7];
                pair_pos_b_s3[7] <= neg_pos_s2[7];
                pair_valid_s3[7] <= (total_pos_s2 >= 8) && (total_neg_s2 >= 8);
                pair_cross_s3[7] <= 1'b0;
            end
        end
    end

    //--------------------------------------------------------------------------
    // Stage 4: 输出寄存
    //--------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pair_valid <= 0;
            pair_pos_a <= 0;
            pair_pos_b <= 0;
            pair_cross_cycle <= 0;
            total_pairs <= 0;
            valid_out <= 0;
        end
        else begin
            valid_out <= valid_s3;
            pair_valid <= pair_valid_s3;
            pair_cross_cycle <= pair_cross_s3;
            total_pairs <= total_pairs_s3;
            
            // 打包位置到一维向量
            pair_pos_a <= {pair_pos_a_s3[7], pair_pos_a_s3[6], pair_pos_a_s3[5], pair_pos_a_s3[4],
                          pair_pos_a_s3[3], pair_pos_a_s3[2], pair_pos_a_s3[1], pair_pos_a_s3[0]};
            pair_pos_b <= {pair_pos_b_s3[7], pair_pos_b_s3[6], pair_pos_b_s3[5], pair_pos_b_s3[4],
                          pair_pos_b_s3[3], pair_pos_b_s3[2], pair_pos_b_s3[1], pair_pos_b_s3[0]};
        end
    end

endmodule
