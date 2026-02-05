import numpy as np
import pandas as pd
import os

def x_read_write(file_src, file_des=None, scale_factor=20000, seed=14521, 
                 noise_amp=200, sine_amp=500, dc_offset=10000, num_rows_read=320000):
    """
    num_rows_read: 指定读取的行数。默认 320000 (即 20000 * 16)。
                   如果想读取全部，可以设置为 None。
    """
    if file_des is None:
        file_des = "D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/x_input.txt"

    print(f"开始读取文件: {file_src}，目标行数: {num_rows_read if num_rows_read else '全部'}")

    try:
        # 使用 nrows 参数直接限制读取行数，避免浪费内存
        df = pd.read_csv(file_src, usecols=[1], header=None, skiprows=1, nrows=num_rows_read)
        csv_data = df.iloc[:, 0].values
    except Exception as e:
        print(f"读取CSV失败: {e}")
        return

    total_samples = len(csv_data)
    np.random.seed(seed)
    n = np.arange(total_samples)
    
    noise = np.random.uniform(-noise_amp, noise_amp, total_samples)
    sine_wave = sine_amp * np.sin(2 * np.pi * n / 128)
    
    combined_data = (csv_data * scale_factor) + noise + sine_wave + dc_offset
    input_data = combined_data.astype(np.int16).astype(np.uint16)

    # 计算完整的周期数 (16个点一行)
    num_test_cycles = total_samples // 16
    
    print(f"正在写入 {file_des}，共计 {num_test_cycles} 行数据...")
    
    with open(file_des, "w") as f:
        for i in range(num_test_cycles):
            chunk = input_data[i*16 : (i+1)*16]
            hex_str = ",".join([f"{x & 0xFFFF:04x}" for x in chunk])
            f.write(hex_str + "\n")
            
        # 处理非16整数倍的剩余数据
        remaining = total_samples % 16
        if remaining > 0:
            chunk = input_data[num_test_cycles*16 :]
            hex_str = ",".join([f"{x & 0xFFFF:04x}" for x in chunk] + ["0000"]*(16-remaining))
            f.write(hex_str + "\n")
    
    print("写入完成。")

if __name__ == "__main__":
    src_path = "D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/RawData/sc-ext-3-1250.csv"
    
    # 示例：只读取前 160000 行
    x_read_write(src_path, num_rows_read=320000)