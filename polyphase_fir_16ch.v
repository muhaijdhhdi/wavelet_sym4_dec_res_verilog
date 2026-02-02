`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: polyphase_fir_16ch
// Description: 优化版16通道多相FIR滤波器
//
// 采样结构：
//   ADC采样率：1.25 GHz
//   并行度：16路（连续采样点）
//   处理时钟：78.125 MHz
//   每时钟周期的16路数据是连续的采样点
//
// 定点格式（Qm.n = m位整数含符号 + n位小数）：
//   ADC输入：   Q16.0 (16位)
//   系数：      Q3.18 (21位)
//   输出：      Q16.4 (20位)
//
// 资源预估（ZU9EG）：
//   DSP: 16通道 × 90 = 1440个（占用57%）
//   LUT: ~10K（加法树+控制逻辑）
//
// 流水线结构（8级）：
//   1. 输入寄存级（polyphase_fir_16ch）
//   2-7. fir_symmetric_layer内部6级
//   8. 输出打包（polyphase_fir_16ch）
//
// 时序：
//   输入时钟：78.125 MHz
//   流水线延迟：8个时钟周期
//   吞吐率：每周期16个输出
//////////////////////////////////////////////////////////////////////////////////

module polyphase_fir_16ch #(
    parameter ADC_WIDTH = 16,
    parameter NUM_PAIRS = 89,
    parameter NUM_COEFFS = 90,
    parameter COEFF_WIDTH = 21,         // Q3.18
    parameter OUTPUT_WIDTH = 20,        // Q16.4
    parameter NUM_CHANNELS = 16,
    parameter NUM_TAPS = 179,
    parameter NUM_BUFFERS = 13
)(
    input  wire                                  clk,
    input  wire                                  valid_in,
    input  wire [NUM_CHANNELS*ADC_WIDTH-1:0]     data_in,    // 256位输入
    
    // 系数输入（展平向量）
    input  wire [NUM_COEFFS*COEFF_WIDTH-1:0]     coeffs,     // 1890位
    
    // 输出（展平向量）
    output reg  [NUM_CHANNELS*OUTPUT_WIDTH-1:0]  y_out,      // 320位
    output reg                                   valid_out
);

    //==========================================================================
    // 共享移位寄存器：13级 × 256位
    //==========================================================================
    
    reg [NUM_CHANNELS*ADC_WIDTH-1:0] buffer [0:NUM_BUFFERS-1];
    
    integer k;
    always @(posedge clk) begin
        if (valid_in) begin
            buffer[0] <= data_in;
            for (k = 1; k < NUM_BUFFERS; k = k + 1) begin
                buffer[k] <= buffer[k-1];
            end
        end
    end
    
    //==========================================================================
    // 16通道FIR例化
    //==========================================================================
    
    genvar ch, j;
    
    wire [OUTPUT_WIDTH-1:0] y_out_fir [0:NUM_CHANNELS-1];
    wire valid_out_fir [0:NUM_CHANNELS-1];
    
    generate
        for (ch = 0; ch < NUM_CHANNELS; ch = ch + 1) begin : gen_channel
            
            //==================================================================
            // 样本提取
            //==================================================================
            
            wire signed [ADC_WIDTH-1:0] ch_samples_a [0:NUM_PAIRS-1];
            wire signed [ADC_WIDTH-1:0] ch_samples_b [0:NUM_PAIRS-1];
            wire signed [ADC_WIDTH-1:0] ch_sample_center;
            
            for (j = 0; j < NUM_PAIRS; j = j + 1) begin : gen_samples_a //BUF_IDX_A为当前拍第ch个通道的数据的第j个样本（对称位置之前的)在十三级缓存中的
            //的缓存级索引,相当于纵坐标，而SAMPLE_IDX_A为其样本的索引（0-15），相当于一个矩阵的横坐标。
                localparam integer BUF_IDX_A = (ch - j >= 0) ? 0 : (-(ch - j) + 15) / 16;
                localparam integer SAMPLE_IDX_A = (ch - j >= 0) ? (ch - j) : ((ch - j) + BUF_IDX_A * 16);
                
                assign ch_samples_a[j] = buffer[BUF_IDX_A][SAMPLE_IDX_A*ADC_WIDTH +: ADC_WIDTH];
            end
            
            for (j = 0; j < NUM_PAIRS; j = j + 1) begin : gen_samples_b
                localparam integer TAP_B = 178 - j;
                localparam integer BUF_IDX_B = (ch - TAP_B >= 0) ? 0 : (-(ch - TAP_B) + 15) / 16;
                localparam integer SAMPLE_IDX_B = (ch - TAP_B >= 0) ? (ch - TAP_B) : ((ch - TAP_B) + BUF_IDX_B * 16);
                
                assign ch_samples_b[j] = buffer[BUF_IDX_B][SAMPLE_IDX_B*ADC_WIDTH +: ADC_WIDTH];
            end
            
            localparam integer BUF_IDX_C = (ch - 89 >= 0) ? 0 : (-(ch - 89) + 15) / 16;
            localparam integer SAMPLE_IDX_C = (ch - 89 >= 0) ? (ch - 89) : ((ch - 89) + BUF_IDX_C * 16);
            
            assign ch_sample_center = buffer[BUF_IDX_C][SAMPLE_IDX_C*ADC_WIDTH +: ADC_WIDTH];
            
            //==================================================================
            // 样本打包
            //==================================================================
            
            wire [NUM_PAIRS*ADC_WIDTH-1:0] samples_a_flat;
            wire [NUM_PAIRS*ADC_WIDTH-1:0] samples_b_flat;
            
            for (j = 0; j < NUM_PAIRS; j = j + 1) begin : gen_flatten
                assign samples_a_flat[j*ADC_WIDTH +: ADC_WIDTH] = ch_samples_a[j];
                assign samples_b_flat[j*ADC_WIDTH +: ADC_WIDTH] = ch_samples_b[j];
            end
            
            //==================================================================
            // 输入寄存级
            //==================================================================
            
            reg [NUM_PAIRS*ADC_WIDTH-1:0] samples_a_reg;
            reg [NUM_PAIRS*ADC_WIDTH-1:0] samples_b_reg;
            reg signed [ADC_WIDTH-1:0] sample_center_reg;
            reg valid_in_reg;
            
            always @(posedge clk) begin
                valid_in_reg <= valid_in;
                samples_a_reg <= samples_a_flat;
                samples_b_reg <= samples_b_flat;
                sample_center_reg <= ch_sample_center;
            end
            
            //==================================================================
            // FIR层例化
            //==================================================================
            
            fir_symmetric_layer #(
                .CHANNEL_ID(ch),
                .ADC_WIDTH(ADC_WIDTH),
                .NUM_PAIRS(NUM_PAIRS),
                .NUM_COEFFS(NUM_COEFFS),
                .COEFF_WIDTH(COEFF_WIDTH),
                .OUTPUT_WIDTH(OUTPUT_WIDTH)
            ) u_fir_layer (
                .clk(clk),
                .valid_in(valid_in_reg),
                .samples_a(samples_a_reg),
                .samples_b(samples_b_reg),
                .sample_center(sample_center_reg),
                .coeffs(coeffs),
                .y_out(y_out_fir[ch]),
                .valid_out(valid_out_fir[ch])
            );
        end
    endgenerate
    
    //==========================================================================
    // 输出打包
    //==========================================================================
    
    integer m;
    always @(posedge clk) begin
        valid_out <= valid_out_fir[0];
        for (m = 0; m < NUM_CHANNELS; m = m + 1) begin
            y_out[m*OUTPUT_WIDTH +: OUTPUT_WIDTH] <= y_out_fir[m];
        end
    end

endmodule
