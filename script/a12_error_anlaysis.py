import numpy as np

# ==========================================
# 1. 全局配置与系数
# ==========================================
COEF_FRAC = 23
DATA_WIDTH = 16
DATA_INTERNAL_WIDTH = 48
NUM_TEST_CYCLES = 1000
TOTAL_SAMPLES = NUM_TEST_CYCLES * 16

# Sym4 小波分解低通滤波器系数
h_dec = [
    -0.07576571478927333, -0.02963552764599851, 0.49761866763201545, 0.80373875180591614,
     0.29785779560527736, -0.09921954357684722, -0.012603967262037833, 0.032223100604042759
]

# ==========================================
# 2. 信号生成
# ==========================================
n = np.arange(TOTAL_SAMPLES)
amplitude = 20000
# 原始输入信号
raw_input = amplitude * np.sin(2 * np.pi * n / 128)
# 量化为 16位整数
ideal_data_input = raw_input.astype(np.int16)

# ==========================================
# 3. Python 黄金模型 (L1 + L2)
# ==========================================

# --- L1 模型 (保持你的逻辑: 跳过第一块) ---
def golden_model_floating_L1(data, h):
    # L1 块大小为 16
    block_size = 16
    num_cycles = len(data) // block_size
    res = []

    # 1. 使用第0块数据的最后7个点初始化历史 (data[9]...data[15])
    x_hist = data[9:16]
    
    # 2. 从第1块开始计算
    for i in range(1, num_cycles):
        din = data[i*block_size : (i+1)*block_size]
        combined = np.concatenate((x_hist, din))
        for k in range(8):
            start_idx = k * 2
            window = combined[start_idx : start_idx + len(h)]
            y = np.sum(window[::-1] * h)
            res.append(y)
        # 更新历史
        x_hist = din[9:16]
    return np.array(res)

# --- L2 模型 (修改后: 同样跳过第一块) ---
def golden_model_floating_L2(data, h):
    num_cycles = len(data) // 8
    res = []
    x_hist = data[1:8]
    
    # 2. 从第1块开始计算
    for i in range(1, num_cycles):
        din = data[i*8 : (i+1)*8]
        combined = np.concatenate((x_hist, din))
        for k in range(4):
            start_idx = k * 2
            window = combined[start_idx : start_idx + len(h)]
            y = np.sum(window[::-1] * h)
            res.append(y)
        x_hist = din[1:8]
    return np.array(res)

# ==========================================
# 4. 执行级联计算
# ==========================================

# 第一步：计算 L1 (跳过原始数据的前16个点)
l1_output_ideal = golden_model_floating_L1(ideal_data_input, h_dec)

print(f"L1 理想输出长度: {len(l1_output_ideal)}")

# 第二步：计算 L2 (跳过 L1 输出的前8个点)
# 注意：l1_output_ideal 已经比原始数据少了一块，这里会再少一块
ideal_data_final = golden_model_floating_L2(l1_output_ideal, h_dec)

print(f"L2 理想输出长度: {len(ideal_data_final)}")


# ==========================================
# 5. 读取 Verilog L2 输出文件
# ==========================================
def str2dec(hex_str):
    val = int(hex_str, 16)
    if val >= 2**(DATA_INTERNAL_WIDTH-1):
        val -= 2**DATA_INTERNAL_WIDTH
    return val 

# 输出文件路径 (请确认路径无误)
OUTPUT_A2_from_verilog = "D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/a2_output.txt"
sim_results = []

try:
    with open(OUTPUT_A2_from_verilog, 'r') as f:
        for line in f:
            # L2 输出格式: 每行 4 个 hex 数据
            parts = line.strip().split(',')
            for p in parts:
                p = p.strip()
                if p:
                    # 恢复浮点值
                    sim_results.append(str2dec(p) / (2**COEF_FRAC))
except Exception as e:
    print(f"读取仿真文件失败: {e}")
    exit()

sim_results = np.array(sim_results)

# ==========================================
# 6. 结果比对与分析
# ==========================================
# 对齐数据长度
min_len = min(len(ideal_data_final), len(sim_results))
print(f"对比长度: {min_len}")

a2_p = ideal_data_final[: min_len]
a2_v = sim_results[: min_len]

# 计算残差
error = a2_v - a2_p
max_err = np.max(np.abs(error))
rmse = np.sqrt(np.mean(error**2))

print("=" * 60)
print(f"L2 级联仿真误差分析 (Skipping First Blocks)")
print("-" * 60)
print(f"硬件输出前5点: {a2_v[0:5]}")
print(f"理想模型前5点: {a2_p[0:5]}")
print("-" * 60)
print(f"最大绝对误差: {max_err:.8f}")
print(f"均方根误差 (RMSE): {rmse:.8f}")

if rmse > 0:
    print(f"量化信噪比估计: {20 * np.log10(amplitude / rmse**2):.2f} dB")
else:
    print("量化信噪比估计: Inf dB")
print("=" * 60)