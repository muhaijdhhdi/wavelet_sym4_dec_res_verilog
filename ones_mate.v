`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: ones_mate
// Description: 过零点配对逻辑模块（流水线实现）
//              从16-bit过零掩码中提取所有1的位置，并进行配对
//
// 配对规则：
//   - 如果有上周期未配对的过零点(pending)，当前第一个1与之配对
//   - 剩余的1两两配对
//   - 如果最后剩一个1，成为新的pending
//
// 流水线结构（4级）：
//   Stage 1: 前缀和计算
//   Stage 2: 位置提取
//   Stage 3: 配对生成
//   Stage 4: 输出 + Pending更新
//
// 输出：
//   - 每个配对的两个位置（pos_a, pos_b）打包为一维向量
//   - 配对有效标志
//   - 配对是否跨周期（用于从正确的缓存级取值）
//   - pending 位置和新 pending 标志（供外部保存 diff/abs）
//////////////////////////////////////////////////////////////////////////////////

module ones_mate #(
    parameter NUM_CHANNELS = 16,
    parameter MAX_PAIRS = 8              // 最多8对（16个1）
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          valid_in,
    input  wire [NUM_CHANNELS-1:0]       zero_mask,        // 16-bit过零掩码
    
    // 配对输出（展开为一维向量）
    output reg  [MAX_PAIRS-1:0]          pair_valid,       // 配对有效标志
    output reg  [MAX_PAIRS*4-1:0]        pair_pos_a,       // 配对的第一个位置（8个×4位=32位）
    output reg  [MAX_PAIRS*4-1:0]        pair_pos_b,       // 配对的第二个位置（8个×4位=32位）
    output reg  [MAX_PAIRS-1:0]          pair_cross_cycle, // 配对是否跨周期（pos_a来自上周期）
    output reg  [4:0]                    total_pairs,      // 有效配对总数
    output reg                           valid_out,
    
    // pending 状态输出（供外部索引 diff/abs）
    output reg                           pending_valid_out,  // 当前是否有 pending
    output reg  [3:0]                    pending_pos_out,    // pending 的通道位置
    output reg                           new_pending_out,    // 本周期产生了新的 pending（用于触发外部保存）
    output reg  [3:0]                    new_pending_pos_out,// 新 pending 的通道位置（与 new_pending_out 同步）
    
    // 流水线延迟信息（供外部缓存对齐）
    output wire [2:0]                    pipeline_delay    // 流水线延迟周期数
);

    assign pipeline_delay = 3'd4;  // 4级流水线

    //==========================================================================
    // Pending 状态（跨周期未配对的过零点）
    //==========================================================================
    reg pending_valid;
    reg [3:0] pending_pos;

    //==========================================================================
    // 内部数组（用于计算）
    //==========================================================================
    reg [3:0] pair_pos_a_int [0:MAX_PAIRS-1];
    reg [3:0] pair_pos_b_int [0:MAX_PAIRS-1];

    //==========================================================================
    // Stage 1: 前缀和计算
    // prefix[i] = mask[0] + mask[1] + ... + mask[i-1]
    //==========================================================================
    reg [NUM_CHANNELS-1:0] mask_s1;
    reg [4:0] prefix_s1 [0:NUM_CHANNELS-1];
    reg [4:0] total_ones_s1;
    reg pending_valid_s1;
    reg [3:0] pending_pos_s1;
    reg valid_s1;
    
    // 前缀（每一个周期内通道前面的zero_mask(过零点）的个数，为16位，例如，prefix[0]表示的是本周期内第0路前的过零点数
    // 为0）和计算（组合逻辑，用于流水线寄存）
    wire [4:0] prefix_comb [0:NUM_CHANNELS-1];
    wire [4:0] total_ones_comb;
    
    assign prefix_comb[0] = 5'd0;
    genvar g;
    generate
        for (g = 1; g < NUM_CHANNELS; g = g + 1) begin : gen_prefix
            assign prefix_comb[g] = prefix_comb[g-1] + zero_mask[g-1];
        end
    endgenerate
    assign total_ones_comb = prefix_comb[NUM_CHANNELS-1] + zero_mask[NUM_CHANNELS-1];
    
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mask_s1 <= 0;
            total_ones_s1 <= 0;
            pending_valid_s1 <= 0;
            pending_pos_s1 <= 0;
            valid_s1 <= 0;
            for (i = 0; i < NUM_CHANNELS; i = i + 1) begin
                prefix_s1[i] <= 0;
            end
        end
        else begin
            mask_s1 <= zero_mask;
            total_ones_s1 <= total_ones_comb;
            pending_valid_s1 <= pending_valid;
            pending_pos_s1 <= pending_pos;
            valid_s1 <= valid_in;
            
            for (i = 0; i < NUM_CHANNELS; i = i + 1) begin
                prefix_s1[i] <= prefix_comb[i];
            end
        end
    end

    //==========================================================================
    // Stage 2: 位置提取
    // 确定每个1是"第几个"，并提取位置
    //==========================================================================
    reg [3:0] pos_s2 [0:NUM_CHANNELS-1];  // pos_s2[N] = 第N+1个1的位置
    reg [4:0] total_ones_s2;
    reg pending_valid_s2;
    reg [3:0] pending_pos_s2;
    reg valid_s2;
    
    // 位置提取（组合逻辑）第ch i上是第n+1个过零点.
    // is_nth[i][n] = 1 表示位置i是第n+1个1
    wire is_nth [0:NUM_CHANNELS-1][0:NUM_CHANNELS-1];
    generate
        for (g = 0; g < NUM_CHANNELS; g = g + 1) begin : gen_is_nth_outer
            genvar n;
            for (n = 0; n < NUM_CHANNELS; n = n + 1) begin : gen_is_nth_inner
                assign is_nth[g][n] = mask_s1[g] && (prefix_s1[g] == n);
            end
        end
    endgenerate
    
    // 提取每个序号对应的位置，例如extrated_pos[1]表示第2个过零点在的位置.
    // 但是当在该区间内的过零点数目为0时，按照逻辑，因为extrated_pos[0]-[15]=0
    // 单单从这个角度看会有认为第0个过零点在ch0处，第1个过零点在0处......
    // 但是下文提供了保护的机制，通过pair_valid来进行保护.
    wire [3:0] extracted_pos [0:NUM_CHANNELS-1];
    generate
        for (g = 0; g < NUM_CHANNELS; g = g + 1) begin : gen_extract_pos
            // 第g+1个1的位置
            assign extracted_pos[g] = 
                is_nth[0][g]  ? 4'd0  :
                is_nth[1][g]  ? 4'd1  :
                is_nth[2][g]  ? 4'd2  :
                is_nth[3][g]  ? 4'd3  :
                is_nth[4][g]  ? 4'd4  :
                is_nth[5][g]  ? 4'd5  :
                is_nth[6][g]  ? 4'd6  :
                is_nth[7][g]  ? 4'd7  :
                is_nth[8][g]  ? 4'd8  :
                is_nth[9][g]  ? 4'd9  :
                is_nth[10][g] ? 4'd10 :
                is_nth[11][g] ? 4'd11 :
                is_nth[12][g] ? 4'd12 :
                is_nth[13][g] ? 4'd13 :
                is_nth[14][g] ? 4'd14 :
                is_nth[15][g] ? 4'd15 : 4'd0;
        end
    endgenerate
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            total_ones_s2 <= 0;
            pending_valid_s2 <= 0;
            pending_pos_s2 <= 0;
            valid_s2 <= 0;
            for (i = 0; i < NUM_CHANNELS; i = i + 1) begin
                pos_s2[i] <= 0;
            end
        end
        else begin
            total_ones_s2 <= total_ones_s1;
            pending_valid_s2 <= pending_valid_s1;
            pending_pos_s2 <= pending_pos_s1;
            valid_s2 <= valid_s1;
            
            for (i = 0; i < NUM_CHANNELS; i = i + 1) begin
                pos_s2[i] <= extracted_pos[i];
            end
        end
    end

    //==========================================================================
    // Stage 3: 配对生成
    //==========================================================================
    reg [MAX_PAIRS-1:0] pair_valid_s3;
    reg [3:0] pair_pos_a_s3 [0:MAX_PAIRS-1];
    reg [3:0] pair_pos_b_s3 [0:MAX_PAIRS-1];
    reg [MAX_PAIRS-1:0] pair_cross_s3;  // 跨周期标志 只有第一对（pair[0]）在有 pending 时才可能跨周期
    reg [4:0] total_pairs_s3;
    reg new_pending_valid_s3;
    reg [3:0] new_pending_pos_s3;
    reg pending_hold_s3;     // pending 保持标志（区分保持和新产生）
    reg valid_s3;
    reg pending_valid_s3_out;  // 传递当前 pending 状态供输出
    reg [3:0] pending_pos_s3_out;
    
    // 配对逻辑（组合逻辑）
    // total_ones_s2是由前面的stage1通过prefix[15]+zero_mask[15]来计算的，
    // 而pending_valid_s2是上一次挂起的,是上一个周期剩余的(0或者1).
    // 如果当前有7个那么配对成3对，而且还剩下一个单着，给下一个周期.
    wire [4:0] effective_ones = total_ones_s2 + pending_valid_s2;
    wire [4:0] calc_pairs = effective_ones >> 1;
    wire has_new_pending = effective_ones[0];  // 奇数
    
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
            
            // 传递当前 pending 状态供输出
            pending_valid_s3_out <= pending_valid_s2;
            pending_pos_s3_out <= pending_pos_s2;
            
            if (pending_valid_s2 && total_ones_s2 == 0) begin
                // 特殊情况：有上周期 pending，但当前周期没有过零点
                // pending 应该保持不变，等待下一个周期
                pair_valid_s3 <= 0;
                pair_cross_s3 <= 0;
                for (i = 0; i < MAX_PAIRS; i = i + 1) begin
                    pair_pos_a_s3[i] <= 0;
                    pair_pos_b_s3[i] <= 0;
                end
                
                // pending 保持（不是新产生的，不需要重新保存 diff/abs）
                new_pending_valid_s3 <= 1'b1;
                new_pending_pos_s3 <= pending_pos_s2;
                pending_hold_s3 <= 1'b1;  // 标记为保持，而非新产生
            end
            else if (pending_valid_s2) begin
                // 有上周期pending，且当前周期有过零点，第一对是 (pending, pos[0])
                pair_pos_a_s3[0] <= pending_pos_s2;
                pair_pos_b_s3[0] <= pos_s2[0];  // pos_s2[i]是第i个配对点所在的位置
                pair_valid_s3[0] <= (effective_ones >= 2);  // 判断该pair是否是valid的
                pair_cross_s3[0] <= 1'b1;  // 跨周期
                
                // 后续配对
                pair_pos_a_s3[1] <= pos_s2[1];
                pair_pos_b_s3[1] <= pos_s2[2];
                pair_valid_s3[1] <= (effective_ones >= 4);
                pair_cross_s3[1] <= 1'b0;
                
                pair_pos_a_s3[2] <= pos_s2[3];
                pair_pos_b_s3[2] <= pos_s2[4];
                pair_valid_s3[2] <= (effective_ones >= 6);
                pair_cross_s3[2] <= 1'b0;
                
                pair_pos_a_s3[3] <= pos_s2[5];
                pair_pos_b_s3[3] <= pos_s2[6];
                pair_valid_s3[3] <= (effective_ones >= 8);
                pair_cross_s3[3] <= 1'b0;
                
                pair_pos_a_s3[4] <= pos_s2[7];
                pair_pos_b_s3[4] <= pos_s2[8];
                pair_valid_s3[4] <= (effective_ones >= 10);
                pair_cross_s3[4] <= 1'b0;
                
                pair_pos_a_s3[5] <= pos_s2[9];
                pair_pos_b_s3[5] <= pos_s2[10];
                pair_valid_s3[5] <= (effective_ones >= 12);
                pair_cross_s3[5] <= 1'b0;
                
                pair_pos_a_s3[6] <= pos_s2[11];
                pair_pos_b_s3[6] <= pos_s2[12];
                pair_valid_s3[6] <= (effective_ones >= 14);
                pair_cross_s3[6] <= 1'b0;
                
                pair_pos_a_s3[7] <= pos_s2[13];
                pair_pos_b_s3[7] <= pos_s2[14];
                pair_valid_s3[7] <= (effective_ones >= 16);
                pair_cross_s3[7] <= 1'b0;
                
                // 新pending：当前周期过零点数为偶数时无新pending，奇数时有
                new_pending_valid_s3 <= has_new_pending && (total_ones_s2 > 0);
                pending_hold_s3 <= 1'b0;  // 不是保持，可能产生新 pending
                case (total_ones_s2)
                    5'd1:  new_pending_pos_s3 <= 4'd0;
                    5'd2:  new_pending_pos_s3 <= pos_s2[1];
                    5'd3:  new_pending_pos_s3 <= pos_s2[2];
                    5'd4:  new_pending_pos_s3 <= pos_s2[3];
                    5'd5:  new_pending_pos_s3 <= pos_s2[4];
                    5'd6:  new_pending_pos_s3 <= pos_s2[5];
                    5'd7:  new_pending_pos_s3 <= pos_s2[6];
                    5'd8:  new_pending_pos_s3 <= pos_s2[7];
                    5'd9:  new_pending_pos_s3 <= pos_s2[8];
                    5'd10: new_pending_pos_s3 <= pos_s2[9];
                    5'd11: new_pending_pos_s3 <= pos_s2[10];
                    5'd12: new_pending_pos_s3 <= pos_s2[11];
                    5'd13: new_pending_pos_s3 <= pos_s2[12];
                    5'd14: new_pending_pos_s3 <= pos_s2[13];
                    5'd15: new_pending_pos_s3 <= pos_s2[14];
                    default: new_pending_pos_s3 <= 4'd0;
                endcase
            end
            else begin
                // 无pending，正常配对
                pair_pos_a_s3[0] <= pos_s2[0];
                pair_pos_b_s3[0] <= pos_s2[1];
                pair_valid_s3[0] <= (total_ones_s2 >= 2);
                pair_cross_s3[0] <= 1'b0;
                
                pair_pos_a_s3[1] <= pos_s2[2];
                pair_pos_b_s3[1] <= pos_s2[3];
                pair_valid_s3[1] <= (total_ones_s2 >= 4);
                pair_cross_s3[1] <= 1'b0;
                
                pair_pos_a_s3[2] <= pos_s2[4];
                pair_pos_b_s3[2] <= pos_s2[5];
                pair_valid_s3[2] <= (total_ones_s2 >= 6);
                pair_cross_s3[2] <= 1'b0;
                
                pair_pos_a_s3[3] <= pos_s2[6];
                pair_pos_b_s3[3] <= pos_s2[7];
                pair_valid_s3[3] <= (total_ones_s2 >= 8);
                pair_cross_s3[3] <= 1'b0;
                
                pair_pos_a_s3[4] <= pos_s2[8];
                pair_pos_b_s3[4] <= pos_s2[9];
                pair_valid_s3[4] <= (total_ones_s2 >= 10);
                pair_cross_s3[4] <= 1'b0;
                
                pair_pos_a_s3[5] <= pos_s2[10];
                pair_pos_b_s3[5] <= pos_s2[11];
                pair_valid_s3[5] <= (total_ones_s2 >= 12);
                pair_cross_s3[5] <= 1'b0;
                
                pair_pos_a_s3[6] <= pos_s2[12];
                pair_pos_b_s3[6] <= pos_s2[13];
                pair_valid_s3[6] <= (total_ones_s2 >= 14);
                pair_cross_s3[6] <= 1'b0;
                
                pair_pos_a_s3[7] <= pos_s2[14];
                pair_pos_b_s3[7] <= pos_s2[15];
                pair_valid_s3[7] <= (total_ones_s2 >= 16);
                pair_cross_s3[7] <= 1'b0;
                
                // 新pending（只记录位置）
                new_pending_valid_s3 <= has_new_pending;
                pending_hold_s3 <= 1'b0;  // 不是保持
                case (total_ones_s2)
                    5'd1:  new_pending_pos_s3 <= pos_s2[0];
                    5'd3:  new_pending_pos_s3 <= pos_s2[2];
                    5'd5:  new_pending_pos_s3 <= pos_s2[4];
                    5'd7:  new_pending_pos_s3 <= pos_s2[6];
                    5'd9:  new_pending_pos_s3 <= pos_s2[8];
                    5'd11: new_pending_pos_s3 <= pos_s2[10];
                    5'd13: new_pending_pos_s3 <= pos_s2[12];
                    5'd15: new_pending_pos_s3 <= pos_s2[14];
                    default: new_pending_pos_s3 <= 4'd0;
                endcase
            end
        end
    end

    //==========================================================================
    // Stage 4: 输出 + 更新Pending状态
    // 将内部数组展开为一维向量输出
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pair_valid <= 0;
            pair_cross_cycle <= 0;
            total_pairs <= 0;
            valid_out <= 0;
            pending_valid <= 0;
            pending_pos <= 0;
            pending_valid_out <= 0;
            pending_pos_out <= 0;
            new_pending_out <= 0;
            new_pending_pos_out <= 0;
            pair_pos_a <= 0;
            pair_pos_b <= 0;
            for (i = 0; i < MAX_PAIRS; i = i + 1) begin
                pair_pos_a_int[i] <= 0;
                pair_pos_b_int[i] <= 0;
            end
        end
        else begin
            pair_valid <= pair_valid_s3;
            pair_cross_cycle <= pair_cross_s3;
            total_pairs <= total_pairs_s3;
            valid_out <= valid_s3;
            
            // 输出当前 pending 状态（用于跨周期配对验证）
            pending_valid_out <= pending_valid_s3_out;
            pending_pos_out <= pending_pos_s3_out;
            
            // 输出新 pending 标志和位置（触发外部保存 diff/abs）
            // 只有真正产生新 pending 时才为 1，pending 保持时为 0
            new_pending_out <= new_pending_valid_s3 && valid_s3 && !pending_hold_s3;
            new_pending_pos_out <= new_pending_pos_s3;
            
            // 将内部数组转换为一维向量输出
            for (i = 0; i < MAX_PAIRS; i = i + 1) begin
                pair_pos_a_int[i] <= pair_pos_a_s3[i];
                pair_pos_b_int[i] <= pair_pos_b_s3[i];
            end
            
            // 展开为一维向量
            pair_pos_a <= {pair_pos_a_s3[7], pair_pos_a_s3[6], pair_pos_a_s3[5], pair_pos_a_s3[4],
                          pair_pos_a_s3[3], pair_pos_a_s3[2], pair_pos_a_s3[1], pair_pos_a_s3[0]};
            pair_pos_b <= {pair_pos_b_s3[7], pair_pos_b_s3[6], pair_pos_b_s3[5], pair_pos_b_s3[4],
                          pair_pos_b_s3[3], pair_pos_b_s3[2], pair_pos_b_s3[1], pair_pos_b_s3[0]};
            
            // 更新全局pending状态
            if (valid_s3) begin
                pending_valid <= new_pending_valid_s3;
                pending_pos <= new_pending_pos_s3;
            end
        end
    end

endmodule
