#产生输入数据x
import numpy as np

seed = 121
num_test_cycles = 2000
total_samples = num_test_cycles * 16
n = np.arange(total_samples)
amplitude = 20000
#data = amplitude * np.sin(2 * np.pi * n / 128)
np.random.seed(seed)
data=np.random.uniform(-amplitude, amplitude, total_samples)
input_data = data.astype(np.int16).astype(np.uint16)#截断取整

file_path = "D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/x_input.txt"

print(data[:10])
with open(file_path, "w") as f:
    for i in range(num_test_cycles):
        chunk = input_data[i*16 : (i+1)*16]
        hex_str = ",".join([f"{x & 0xFFFF:04x}" for x in chunk])
        f.write(hex_str + "\n")

print(input_data[:10])
#当幅度很小时，input_data = data.astype(np.int16).astype(np.uint16)产生的误差较大.即|data-input_data|