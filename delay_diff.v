`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: delay_diff
// Description: 16通道延迟差分模块
//              计算：diff = data_current - data_delayed
//              延迟：2个时钟周期 (≈25.6ns @ 78.125MHz，等效32个ADC时钟周期)
//
// 输入：滤波后的16通道数据 (Q16.4格式, 20位×16通道 = 320位)
// 输出：差分结果 (Q16.4格式, 20位×16通道 = 320位)
//
// 流水线结构（3级）：
//   Stage 0: 输入寄存
//   Stage 1: 延迟链
//   Stage 2: 差分计算 + 输出寄存
//
// 流水线延迟：DELAY_CYCLES + 1 个时钟周期
//////////////////////////////////////////////////////////////////////////////////

module delay_diff #(
    parameter NUM_CHANNELS = 16,
    parameter DATA_WIDTH = 20,              // Q16.4格式
    parameter DELAY_CYCLES = 2              // 以78.125MHz的周期为单位
)(
    input  wire                                  clk,
    input  wire                                  valid_in,
    input  wire [NUM_CHANNELS*DATA_WIDTH-1:0]   data_in,      // 320位输入
    
    output reg  [NUM_CHANNELS*DATA_WIDTH-1:0]   diff_out,            // 320位差分结果
    output reg  [NUM_CHANNELS*DATA_WIDTH-1:0]   data_before_diff_out, // 320位差分前信号（被减数，与diff_out对齐）
    output reg                                   valid_out
);

    //==========================================================================
    // Stage 0: 输入寄存（改善时序）
    //==========================================================================
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] data_in_reg;
    reg valid_in_reg;
    
    always @(posedge clk) begin
        data_in_reg <= data_in;
        valid_in_reg <= valid_in;
    end

    //==========================================================================
    // Stage 1: 延迟寄存器链
    //==========================================================================
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] delay_reg [0:DELAY_CYCLES-1];
    reg [DELAY_CYCLES-1:0] valid_delay;
    
    integer i;
    always @(posedge clk) begin
        // 延迟链
        delay_reg[0] <= data_in_reg;
        for (i = 1; i < DELAY_CYCLES; i = i + 1) begin
            delay_reg[i] <= delay_reg[i-1];
        end
        
        // valid信号延迟
        valid_delay <= {valid_delay[DELAY_CYCLES-2:0], valid_in_reg};
    end
    
    //==========================================================================
    // Stage 2: 差分计算 + 输出寄存
    // 差分直接在时序逻辑中完成，避免组合逻辑路径过长
    // 同时输出差分前的信号（被减数），与diff_out相位对齐
    //==========================================================================
    
    integer j;
    always @(posedge clk) begin
        valid_out <= valid_delay[DELAY_CYCLES-1];
        
        // 差分计算：current - delayed（直接在寄存器中完成）
        for (j = 0; j < NUM_CHANNELS; j = j + 1) begin
            diff_out[j*DATA_WIDTH +: DATA_WIDTH] <= 
                $signed(data_in_reg[j*DATA_WIDTH +: DATA_WIDTH]) - 
                $signed(delay_reg[DELAY_CYCLES-1][j*DATA_WIDTH +: DATA_WIDTH]);
            // 同时输出差分前的信号（被减数），用于脉冲幅度判断
            data_before_diff_out[j*DATA_WIDTH +: DATA_WIDTH] <= 
                data_in_reg[j*DATA_WIDTH +: DATA_WIDTH];
        end
    end

endmodule

