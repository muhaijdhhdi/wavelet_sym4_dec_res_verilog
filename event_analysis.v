`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: event_analysis
// Description: 事件分析模块（diff_trigger版本）
//              统计单个78.125MHz周期内的脉冲事件数和堆积事件数
//
// 设计原理：
//   接收 event_mask_gen 产生的双阈值事件掩码
//   使用全流水线化的 popcount 加法树统计每个周期内的事件数
//   无需跨周期处理（跨越阈值是瞬时点事件）
//
// 计数逻辑（方案A）：
//   pulse_this_cycle  = popcount(event_mask1) + popcount(event_mask2)
//   pileup_this_cycle = popcount(event_mask2)
//
// 物理含义：
//   - 跨越阈值1：检测到1个脉冲
//   - 跨越阈值2：检测到堆积（2个脉冲叠加），额外计1个脉冲
//
// 流水线结构（每级一拍，最优时序）：
//   Stage 1: Level 1 加法（16→8）+ 寄存
//   Stage 2: Level 2 加法（8→4）+ 寄存
//   Stage 3: Level 3 加法（4→2）+ 寄存
//   Stage 4: Level 4 加法（2→1）+ 寄存
//   Stage 5: 方案A计数逻辑 + 输出寄存
//
// 流水线延迟：5个时钟周期
//////////////////////////////////////////////////////////////////////////////////

module event_analysis #(
    parameter NUM_CHANNELS = 16
)(
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      valid_in,
    input  wire [NUM_CHANNELS-1:0]  event_mask1,      // 阈值1事件掩码
    input  wire [NUM_CHANNELS-1:0]  event_mask2,      // 阈值2事件掩码（堆积）
    
    output reg  [4:0]               pulse_this_cycle,  // 本周期脉冲数（0~32，实际最多16+16=32）
    output reg  [4:0]               pileup_this_cycle, // 本周期堆积数（0~16）
    output reg                       valid_out
);

    integer i;
    genvar g;

    //==========================================================================
    // Stage 1: Level 1 加法（16 -> 8）
    //==========================================================================
    wire [1:0] cnt1_l1 [0:7];
    wire [1:0] cnt2_l1 [0:7];
    
    generate
        for (g = 0; g < 8; g = g + 1) begin : gen_l1
            assign cnt1_l1[g] = {1'b0, event_mask1[g*2]} + {1'b0, event_mask1[g*2+1]};
            assign cnt2_l1[g] = {1'b0, event_mask2[g*2]} + {1'b0, event_mask2[g*2+1]};
        end
    endgenerate
    
    reg [1:0] cnt1_s1 [0:7];
    reg [1:0] cnt2_s1 [0:7];
    reg valid_s1;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 8; i = i + 1) begin
                cnt1_s1[i] <= 0;
                cnt2_s1[i] <= 0;
            end
            valid_s1 <= 0;
        end
        else begin
            for (i = 0; i < 8; i = i + 1) begin
                cnt1_s1[i] <= cnt1_l1[i];
                cnt2_s1[i] <= cnt2_l1[i];
            end
            valid_s1 <= valid_in;
        end
    end

    //==========================================================================
    // Stage 2: Level 2 加法（8 -> 4）
    //==========================================================================
    wire [2:0] cnt1_l2 [0:3];
    wire [2:0] cnt2_l2 [0:3];
    
    generate
        for (g = 0; g < 4; g = g + 1) begin : gen_l2
            assign cnt1_l2[g] = {1'b0, cnt1_s1[g*2]} + {1'b0, cnt1_s1[g*2+1]};
            assign cnt2_l2[g] = {1'b0, cnt2_s1[g*2]} + {1'b0, cnt2_s1[g*2+1]};
        end
    endgenerate
    
    reg [2:0] cnt1_s2 [0:3];
    reg [2:0] cnt2_s2 [0:3];
    reg valid_s2;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 4; i = i + 1) begin
                cnt1_s2[i] <= 0;
                cnt2_s2[i] <= 0;
            end
            valid_s2 <= 0;
        end
        else begin
            for (i = 0; i < 4; i = i + 1) begin
                cnt1_s2[i] <= cnt1_l2[i];
                cnt2_s2[i] <= cnt2_l2[i];
            end
            valid_s2 <= valid_s1;
        end
    end

    //==========================================================================
    // Stage 3: Level 3 加法（4 -> 2）
    //==========================================================================
    wire [3:0] cnt1_l3 [0:1];
    wire [3:0] cnt2_l3 [0:1];
    
    generate
        for (g = 0; g < 2; g = g + 1) begin : gen_l3
            assign cnt1_l3[g] = {1'b0, cnt1_s2[g*2]} + {1'b0, cnt1_s2[g*2+1]};
            assign cnt2_l3[g] = {1'b0, cnt2_s2[g*2]} + {1'b0, cnt2_s2[g*2+1]};
        end
    endgenerate
    
    reg [3:0] cnt1_s3 [0:1];
    reg [3:0] cnt2_s3 [0:1];
    reg valid_s3;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 2; i = i + 1) begin
                cnt1_s3[i] <= 0;
                cnt2_s3[i] <= 0;
            end
            valid_s3 <= 0;
        end
        else begin
            for (i = 0; i < 2; i = i + 1) begin
                cnt1_s3[i] <= cnt1_l3[i];
                cnt2_s3[i] <= cnt2_l3[i];
            end
            valid_s3 <= valid_s2;
        end
    end

    //==========================================================================
    // Stage 4: Level 4 加法（2 -> 1）
    //==========================================================================
    wire [4:0] popcount1 = {1'b0, cnt1_s3[0]} + {1'b0, cnt1_s3[1]};
    wire [4:0] popcount2 = {1'b0, cnt2_s3[0]} + {1'b0, cnt2_s3[1]};
    
    reg [4:0] popcount1_s4;
    reg [4:0] popcount2_s4;
    reg valid_s4;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            popcount1_s4 <= 0;
            popcount2_s4 <= 0;
            valid_s4 <= 0;
        end
        else begin
            popcount1_s4 <= popcount1;
            popcount2_s4 <= popcount2;
            valid_s4 <= valid_s3;
        end
    end

    //==========================================================================
    // Stage 5: 计数逻辑（方案A）+ 输出寄存
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pulse_this_cycle <= 0;
            pileup_this_cycle <= 0;
            valid_out <= 0;
        end
        else begin
            // 方案A：pulse = popcount1 + popcount2
            pulse_this_cycle <= popcount1_s4 + popcount2_s4;
            pileup_this_cycle <= popcount2_s4;
            valid_out <= valid_s4;
        end
    end

endmodule
