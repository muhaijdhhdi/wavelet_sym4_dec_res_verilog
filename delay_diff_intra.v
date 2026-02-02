`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: delay_diff_intra
// Description: 16通道亚周期精度延迟差分模块
//              计算：diff = data_delayed - data_current（历史减当前）
//              延迟精度：0.8ns（1个ADC采样周期 @ 1.25GHz）
//              延迟范围：1~64个采样点（0.8ns ~ 51.2ns）
//
// 输入：滤波后的16通道数据 (Q16.4格式, 20位×16通道 = 320位)
// 输出：差分结果 (Q16.4格式, 20位×16通道 = 320位)
//
// 数据矩阵模型（5列×16行）：
//   - 列：从左到右代表时间从新到老（列0=当前周期，列4=4周期前）
//   - 行：从上到下代表同周期内时间从新到老（行0=ch15最新，行15=ch0最老）
//   - 每列跨度12.8ns，每行跨度0.8ns
//
// 流水线结构（3级）：
//   Stage 1: 输入寄存 + 矩阵更新
//   Stage 2: 索引计算 + MUX选择 + 寄存
//   Stage 3: 差分计算 + 输出寄存
//
// 流水线延迟：3个时钟周期
//////////////////////////////////////////////////////////////////////////////////

module delay_diff_intra #(
    parameter NUM_CHANNELS = 16,
    parameter DATA_WIDTH = 20              // Q16.4格式
)(
    input  wire                                  clk,
    input  wire [6:0]                            delay_sel,    // 延迟选择：1~64，单位0.8ns（7位，有效值1~64）
    input  wire                                  valid_in,
    input  wire [NUM_CHANNELS*DATA_WIDTH-1:0]   data_in,      // 320位输入
    
    output reg  [NUM_CHANNELS*DATA_WIDTH-1:0]   diff_out,            // 320位差分结果
    output reg  [NUM_CHANNELS*DATA_WIDTH-1:0]   data_before_diff_out, // 320位当前信号（与diff_out对齐）
    output reg                                   valid_out
);

    //==========================================================================
    // 参数定义
    //==========================================================================
    localparam MATRIX_COLS = 5;             // 5列（当前+4个历史周期）
    localparam MATRIX_ROWS = 16;            // 16行（16个通道）

    //==========================================================================
    // 二维矩阵存储
    // buffer[col][row]：col=0最新，col=4最老；row=0是ch15（最新），row=15是ch0（最老）
    //==========================================================================
    reg [DATA_WIDTH-1:0] buffer [0:MATRIX_COLS-1][0:MATRIX_ROWS-1];

    //==========================================================================
    // Stage 1: 输入寄存 + 矩阵级联更新
    //==========================================================================
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] data_stage1;
    reg valid_stage1;
    reg [6:0] delay_sel_stage1;
    
    integer col, row;
    always @(posedge clk) begin
        // 流水线寄存
        data_stage1 <= data_in;
        valid_stage1 <= valid_in;
        delay_sel_stage1 <= delay_sel;
        
        // 矩阵级联移位：一级一级地缓存
        // buffer[4] <= buffer[3]
        // buffer[3] <= buffer[2]
        // buffer[2] <= buffer[1]
        // buffer[1] <= buffer[0]
        for (col = MATRIX_COLS - 1; col >= 1; col = col - 1) begin
            for (row = 0; row < MATRIX_ROWS; row = row + 1) begin
                buffer[col][row] <= buffer[col-1][row];
            end
        end
        
        // 新数据写入 buffer[0]（列0，当前周期）
        // 映射：buffer[0][row] = ch(15-row)，即row=0存ch15（最新），row=15存ch0（最老）
        for (row = 0; row < MATRIX_ROWS; row = row + 1) begin
            buffer[0][row] <= data_in[(15-row)*DATA_WIDTH +: DATA_WIDTH];
        end
    end

    //==========================================================================
    // 索引计算（组合逻辑）
    // 对于输出通道k（0~15），延迟N个采样点后：
    //   time_offset = (15 - k) + N
    //   col_sel = time_offset / 16
    //   row_sel = time_offset % 16
    //==========================================================================
    wire [6:0] time_offset [0:NUM_CHANNELS-1];  // 最大79，需要7位
    wire [2:0] col_sel [0:NUM_CHANNELS-1];      // 列选择，0~4
    wire [3:0] row_sel [0:NUM_CHANNELS-1];      // 行选择，0~15
    
    genvar k;
    generate
        for (k = 0; k < NUM_CHANNELS; k = k + 1) begin : INDEX_CALC
            // 通道k在当前周期的时间偏移是(15-k)
            // 延迟delay_sel个采样点后，总偏移为(15-k)+delay_sel
            assign time_offset[k] = (7'd15 - k[6:0]) + delay_sel_stage1;
            assign col_sel[k] = time_offset[k][6:4];  // 除以16
            assign row_sel[k] = time_offset[k][3:0];  // 模16
        end
    endgenerate

    //==========================================================================
    // Stage 2: MUX选择 + 寄存
    // 根据col_sel和row_sel从buffer中选择延迟数据
    //==========================================================================
    reg [DATA_WIDTH-1:0] delayed_data_stage2 [0:NUM_CHANNELS-1];
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] data_stage2;
    reg valid_stage2;
    
    integer ch;
    always @(posedge clk) begin
        // 流水线寄存
        data_stage2 <= data_stage1;
        valid_stage2 <= valid_stage1;
        
        // MUX选择：根据col_sel和row_sel从buffer中选择延迟数据
        for (ch = 0; ch < NUM_CHANNELS; ch = ch + 1) begin
            delayed_data_stage2[ch] <= buffer[col_sel[ch]][row_sel[ch]];
        end
    end

    //==========================================================================
    // Stage 3: 差分计算 + 输出寄存
    // 差分公式：diff = data_delayed - data_current（历史减当前）
    //==========================================================================
    integer j;
    always @(posedge clk) begin
        valid_out <= valid_stage2;
        
        for (j = 0; j < NUM_CHANNELS; j = j + 1) begin
            // 差分计算：延迟数据（历史）- 当前数据
            diff_out[j*DATA_WIDTH +: DATA_WIDTH] <= 
                $signed(delayed_data_stage2[j]) - 
                $signed(data_stage2[j*DATA_WIDTH +: DATA_WIDTH]);
            
            // 输出当前数据（与diff_out时间对齐）
            data_before_diff_out[j*DATA_WIDTH +: DATA_WIDTH] <= 
                data_stage2[j*DATA_WIDTH +: DATA_WIDTH];
        end
    end

endmodule
