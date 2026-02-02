`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: ones_mate_v2
// Description: 过零点配对模块（基于方向信息的增强版）
//
// 功能：
//   1. 根据过零方向（正向/负向）进行配对
//   2. 正向过零（负→正）= 脉冲起点，负向过零（正→负）= 脉冲终点
//   3. 配对规则：正向 + 其后的负向 = 一个完整脉冲
//   4. 跨周期处理：只有正向过零点会进入 pending 状态
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
// 配对逻辑：
//   1. 如果有历史 pending（正向），与本周期第1个负向配对
//   2. 本周期内：按顺序，正向与其后的负向配对
//   3. 最后剩余的正向 → 新 pending
//
// 流水线延迟：4个时钟周期
//////////////////////////////////////////////////////////////////////////////////

module ones_mate_v2 #(
    parameter NUM_CHANNELS = 16,
    parameter MAX_PAIRS = 8
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     valid_in,
    input  wire [NUM_CHANNELS-1:0]  zero_mask,       // 过零掩码
    input  wire [NUM_CHANNELS-1:0]  zero_direction,  // 过零方向（1=正向，0=负向）
    
    // 配对结果
    output reg  [MAX_PAIRS-1:0]     pair_valid,      // 每对是否有效
    output reg  [MAX_PAIRS*4-1:0]   pair_pos_a,      // 起点位置（正向）
    output reg  [MAX_PAIRS*4-1:0]   pair_pos_b,      // 终点位置（负向）
    output reg  [MAX_PAIRS-1:0]     pair_cross_cycle,// 是否跨周期
    output reg  [4:0]               total_pairs,     // 有效配对数
    output reg                      valid_out,
    
    // pending 状态输出
    output reg                      pending_valid_out,   // 是否有未配对的正向过零点
    output reg  [3:0]               pending_pos_out,     // pending 位置
    output reg                      new_pending_out,     // 是否产生新 pending
    output reg  [3:0]               new_pending_pos_out, // 新 pending 位置
    
    // 流水线延迟指示
    output wire [2:0]               pipeline_delay
);

    assign pipeline_delay = 3'd4;

    //==========================================================================
    // Pending 状态（跨周期未配对的正向过零点）
    // 注意：只有正向过零点才会进入 pending
    //==========================================================================
    reg pending_valid;
    reg [3:0] pending_pos;

    //==========================================================================
    // Stage 1: 输入寄存 + 分离正向/负向 + Prefix Sum 计算
    //==========================================================================
    reg [NUM_CHANNELS-1:0] mask_s1;
    reg [NUM_CHANNELS-1:0] direction_s1;
    reg [NUM_CHANNELS-1:0] pos_mask_s1;   // 正向过零掩码
    reg [NUM_CHANNELS-1:0] neg_mask_s1;   // 负向过零掩码
    reg [4:0] pos_prefix_s1 [0:NUM_CHANNELS-1];  // 正向前缀和
    reg [4:0] neg_prefix_s1 [0:NUM_CHANNELS-1];  // 负向前缀和
    reg [4:0] total_pos_s1;  // 正向过零点总数
    reg [4:0] total_neg_s1;  // 负向过零点总数
    reg pending_valid_s1;
    reg [3:0] pending_pos_s1;
    reg valid_s1;
    
    // 分离正向和负向掩码（组合逻辑）
    wire [NUM_CHANNELS-1:0] pos_mask_comb;
    wire [NUM_CHANNELS-1:0] neg_mask_comb;
    
    genvar g;
    generate
        for (g = 0; g < NUM_CHANNELS; g = g + 1) begin : gen_separate
            assign pos_mask_comb[g] = zero_mask[g] && zero_direction[g];   // 正向
            assign neg_mask_comb[g] = zero_mask[g] && !zero_direction[g];  // 负向
        end
    endgenerate
    
    // 正向前缀和（组合逻辑）
    wire [4:0] pos_prefix_comb [0:NUM_CHANNELS-1];
    assign pos_prefix_comb[0] = 5'd0;
    generate
        for (g = 1; g < NUM_CHANNELS; g = g + 1) begin : gen_pos_prefix
            assign pos_prefix_comb[g] = pos_prefix_comb[g-1] + pos_mask_comb[g-1];
        end
    endgenerate
    wire [4:0] total_pos_comb = pos_prefix_comb[NUM_CHANNELS-1] + pos_mask_comb[NUM_CHANNELS-1];
    
    // 负向前缀和（组合逻辑）
    wire [4:0] neg_prefix_comb [0:NUM_CHANNELS-1];
    assign neg_prefix_comb[0] = 5'd0;
    generate
        for (g = 1; g < NUM_CHANNELS; g = g + 1) begin : gen_neg_prefix
            assign neg_prefix_comb[g] = neg_prefix_comb[g-1] + neg_mask_comb[g-1];
        end
    endgenerate
    wire [4:0] total_neg_comb = neg_prefix_comb[NUM_CHANNELS-1] + neg_mask_comb[NUM_CHANNELS-1];
    
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mask_s1 <= 0;
            direction_s1 <= 0;
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
            mask_s1 <= zero_mask;
            direction_s1 <= zero_direction;
            pos_mask_s1 <= pos_mask_comb;
            neg_mask_s1 <= neg_mask_comb;
            total_pos_s1 <= total_pos_comb;
            total_neg_s1 <= total_neg_comb;
            pending_valid_s1 <= pending_valid;
            pending_pos_s1 <= pending_pos;
            valid_s1 <= valid_in;
            
            for (i = 0; i < NUM_CHANNELS; i = i + 1) begin
                pos_prefix_s1[i] <= pos_prefix_comb[i];
                neg_prefix_s1[i] <= neg_prefix_comb[i];
            end
        end
    end

    //==========================================================================
    // Stage 2: 位置提取
    // 使用 prefix sum 确定每个过零点是"第几个"
    //==========================================================================
    
    // 正向：is_pos_nth[i][n] = 1 表示位置i是第n+1个正向过零点
    wire is_pos_nth [0:NUM_CHANNELS-1][0:MAX_PAIRS-1];
    generate
        for (g = 0; g < NUM_CHANNELS; g = g + 1) begin : gen_is_pos_nth_outer
            genvar n;
            for (n = 0; n < MAX_PAIRS; n = n + 1) begin : gen_is_pos_nth_inner
                assign is_pos_nth[g][n] = pos_mask_s1[g] && (pos_prefix_s1[g] == n);
            end
        end
    endgenerate
    
    // 负向：is_neg_nth[i][n] = 1 表示位置i是第n+1个负向过零点
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
    reg [3:0] pos_pos_s2 [0:MAX_PAIRS-1];  // 正向过零点位置
    reg [3:0] neg_pos_s2 [0:MAX_PAIRS-1];  // 负向过零点位置
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

    //==========================================================================
    // Stage 3: 配对逻辑
    // 规则：
    //   1. 如果有 pending（正向），与第1个负向配对（跨周期）
    //   2. 本周期内：正向[i] 与 负向[j] 配对
    //      - 需要找到位置 > 正向位置的第一个负向
    //   3. 最后剩余的正向 → 新 pending
    //
    // 简化逻辑：
    //   - 由于正向和负向是交替出现的（物理特性）
    //   - 如果有 pending：pending 配 neg[0]，pos[0] 配 neg[1]，pos[1] 配 neg[2]...
    //   - 如果无 pending：pos[0] 配 neg[0]，pos[1] 配 neg[1]...
    //   - 但需要验证 neg 位置 > pos 位置
    //==========================================================================
    
    reg [MAX_PAIRS-1:0] pair_valid_s3;
    reg [3:0] pair_pos_a_s3 [0:MAX_PAIRS-1];
    reg [3:0] pair_pos_b_s3 [0:MAX_PAIRS-1];
    reg [MAX_PAIRS-1:0] pair_cross_s3;
    reg [4:0] total_pairs_s3;
    reg new_pending_valid_s3;
    reg [3:0] new_pending_pos_s3;
    reg pending_hold_s3;
    reg valid_s3;
    reg pending_valid_s3_out;
    reg [3:0] pending_pos_s3_out;
    
    // 配对数计算
    // 有效配对数 = min(正向数 + pending, 负向数)
    wire [4:0] effective_pos = total_pos_s2 + pending_valid_s2;
    wire [4:0] calc_pairs = (effective_pos <= total_neg_s2) ? effective_pos : total_neg_s2;
    // 新 pending：如果正向数 + pending > 负向数，则有剩余正向
    wire has_new_pending = (effective_pos > total_neg_s2) && (total_pos_s2 > 0);
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pair_valid_s3 <= 0;
            pair_cross_s3 <= 0;
            total_pairs_s3 <= 0;
            new_pending_valid_s3 <= 0;
            new_pending_pos_s3 <= 0;
            pending_hold_s3 <= 0;
            valid_s3 <= 0;
            pending_valid_s3_out <= 0;
            pending_pos_s3_out <= 0;
            for (i = 0; i < MAX_PAIRS; i = i + 1) begin
                pair_pos_a_s3[i] <= 0;
                pair_pos_b_s3[i] <= 0;
            end
        end
        else begin
            valid_s3 <= valid_s2;
            total_pairs_s3 <= calc_pairs;
            pending_valid_s3_out <= pending_valid_s2;
            pending_pos_s3_out <= pending_pos_s2;
            
            if (pending_valid_s2 && total_neg_s2 == 0) begin
                // 有 pending 但本周期没有负向过零点
                // pending 保持，等待下一周期
                pair_valid_s3 <= 0;
                pair_cross_s3 <= 0;
                for (i = 0; i < MAX_PAIRS; i = i + 1) begin
                    pair_pos_a_s3[i] <= 0;
                    pair_pos_b_s3[i] <= 0;
                end
                
                // 如果本周期有新的正向过零点，最后一个成为新 pending
                // 否则保持原 pending
                if (total_pos_s2 > 0) begin
                    // 有新正向，最后一个正向成为新 pending
                    new_pending_valid_s3 <= 1'b1;
                    new_pending_pos_s3 <= pos_pos_s2[total_pos_s2 - 1];
                    pending_hold_s3 <= 1'b0;  // 新产生
                end
                else begin
                    // 无新正向，保持原 pending
                    new_pending_valid_s3 <= 1'b1;
                    new_pending_pos_s3 <= pending_pos_s2;
                    pending_hold_s3 <= 1'b1;  // 保持
                end
            end
            else if (pending_valid_s2) begin
                // 有 pending，与第1个负向配对（跨周期）
                pair_pos_a_s3[0] <= pending_pos_s2;
                pair_pos_b_s3[0] <= neg_pos_s2[0];
                pair_valid_s3[0] <= (total_neg_s2 >= 1);
                pair_cross_s3[0] <= 1'b1;  // 跨周期
                
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
                
                // 新 pending：如果正向数 > 负向数 - 1（因为 neg[0] 被 pending 消耗）
                new_pending_valid_s3 <= has_new_pending;
                pending_hold_s3 <= 1'b0;
                if (has_new_pending) begin
                    // 最后一个未配对的正向
                    // 已配对的正向数 = min(total_pos, total_neg - 1)
                    // 新 pending 位置 = pos_pos_s2[已配对数]
                    case (total_neg_s2)
                        5'd1:  new_pending_pos_s3 <= pos_pos_s2[0];
                        5'd2:  new_pending_pos_s3 <= pos_pos_s2[1];
                        5'd3:  new_pending_pos_s3 <= pos_pos_s2[2];
                        5'd4:  new_pending_pos_s3 <= pos_pos_s2[3];
                        5'd5:  new_pending_pos_s3 <= pos_pos_s2[4];
                        5'd6:  new_pending_pos_s3 <= pos_pos_s2[5];
                        5'd7:  new_pending_pos_s3 <= pos_pos_s2[6];
                        default: new_pending_pos_s3 <= pos_pos_s2[7];
                    endcase
                end
                else begin
                    new_pending_pos_s3 <= 4'd0;
                end
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
                
                // 新 pending：如果正向数 > 负向数
                new_pending_valid_s3 <= has_new_pending;
                pending_hold_s3 <= 1'b0;
                if (has_new_pending) begin
                    // 最后一个未配对的正向 = pos_pos_s2[total_neg_s2]
                    case (total_neg_s2)
                        5'd0:  new_pending_pos_s3 <= pos_pos_s2[0];
                        5'd1:  new_pending_pos_s3 <= pos_pos_s2[1];
                        5'd2:  new_pending_pos_s3 <= pos_pos_s2[2];
                        5'd3:  new_pending_pos_s3 <= pos_pos_s2[3];
                        5'd4:  new_pending_pos_s3 <= pos_pos_s2[4];
                        5'd5:  new_pending_pos_s3 <= pos_pos_s2[5];
                        5'd6:  new_pending_pos_s3 <= pos_pos_s2[6];
                        5'd7:  new_pending_pos_s3 <= pos_pos_s2[7];
                        default: new_pending_pos_s3 <= 4'd0;
                    endcase
                end
                else begin
                    new_pending_pos_s3 <= 4'd0;
                end
            end
        end
    end

    //==========================================================================
    // Stage 4: 输出寄存 + Pending 状态更新
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pair_valid <= 0;
            pair_pos_a <= 0;
            pair_pos_b <= 0;
            pair_cross_cycle <= 0;
            total_pairs <= 0;
            valid_out <= 0;
            pending_valid_out <= 0;
            pending_pos_out <= 0;
            new_pending_out <= 0;
            new_pending_pos_out <= 0;
            pending_valid <= 0;
            pending_pos <= 0;
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
            
            // 输出 pending 状态
            pending_valid_out <= pending_valid_s3_out;
            pending_pos_out <= pending_pos_s3_out;
            
            // 输出新 pending 标志（只有真正新产生时才为 1）
            new_pending_out <= new_pending_valid_s3 && valid_s3 && !pending_hold_s3;
            new_pending_pos_out <= new_pending_pos_s3;
            
            // 更新全局 pending 状态
            if (valid_s3) begin
                pending_valid <= new_pending_valid_s3;
                pending_pos <= new_pending_pos_s3;
            end
        end
    end

endmodule
