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
raw_input = amplitude * np.sin(2 * np.pi * n / 128)
# 使用 round 模拟更好的量化，或者保持 astype(int16) 视你硬件输入而定
ideal_data_input = raw_input.astype(np.int16)

# ==========================================
# 3. Python 黄金模型 (L1 -> L2 -> L3 -> L4)
# ==========================================

# --- L1 模型 (Block Size: 16 -> 8) ---
def golden_model_floating_L1(data, h):
    block_size = 16
    num_cycles = len(data) // block_size
    res = []
    
    # 初始化历史：取第0块的最后7个点
    x_hist = data[9:16] 
    
    # 从第1块开始计算
    for i in range(1, num_cycles):
        din = data[i*block_size : (i+1)*block_size]
        combined = np.concatenate((x_hist, din))
        for k in range(8):
            start_idx = k * 2
            window = combined[start_idx : start_idx + len(h)]
            y = np.sum(window[::-1] * h)
            res.append(y)
        x_hist = din[9:16]
    return np.array(res)

# --- L2 模型 (Block Size: 8 -> 4) ---
def golden_model_floating_L2(data, h):
    block_size = 8
    num_cycles = len(data) // block_size
    res = []
    
    # 初始化历史：取第0块(长度8)的最后7个点 -> data[1:8]
    x_hist = data[1:8]
    
    for i in range(1, num_cycles):
        din = data[i*block_size : (i+1)*block_size]
        combined = np.concatenate((x_hist, din))
        for k in range(4):
            start_idx = k * 2
            window = combined[start_idx : start_idx + len(h)]
            y = np.sum(window[::-1] * h)
            res.append(y)
        x_hist = din[1:8]
    return np.array(res)

# --- L3 模型 (Block Size: 4 -> 2) ---
def golden_model_floating_L3(data, h):
    block_size = 4
    num_cycles = len(data) // block_size
    res = []

    # 初始化历史：需要7个点。
    # L3输入块大小是4。为了凑够7个点，我们需要"跨越周期"。
    # 但在展平的 data 数组中，我们只需要取前两个块(共8点)的最后7个点。
    # 为了保持逻辑一致性（跳过前面的数据建立稳态），我们这里直接跳过前 8 个点(2个块)。
    # 取 data[1:8] 作为历史，意味着我们跳过了 data[0] 以及 data[1]~data[7] 作为历史。
    # 这相当于跳过了前 2 个硬件周期。
    x_hist = data[1:8] 
    
    # 从第 2 个块（索引2，对应硬件第3个周期）开始计算？
    # 不，为了简化模型，我们假设 data 输入足够长，直接取前 8 个做历史。
    # 这里的 num_cycles 是按 block_size=4 算的。
    # 所以 i 从 2 开始循环（跳过前两个块 0 和 1）
    
    for i in range(2, num_cycles):
        din = data[i*block_size : (i+1)*block_size] # 长度 4
        
        combined = np.concatenate((x_hist, din)) # 7 + 4 = 11
        
        for k in range(2): # 输出 2 点
            start_idx = k * 2
            window = combined[start_idx : start_idx + len(h)]
            y = np.sum(window[::-1] * h)
            res.append(y)
            
        # 更新历史：取 combined 的最后 7 个点
        # combined 长度 11。最后 7 个是 indices 4~10。
        # 也就是 x_hist[4:7] + din[0:4]
        x_hist = combined[4:11] 
        
    return np.array(res)

# --- L4 模型 (Block Size: 2 -> 1) ---
def golden_model_floating_L4(data, h):
    block_size = 2
    num_cycles = len(data) // block_size
    res = []

    # 初始化历史：需要 7 个点。
    # L4 输入块大小是 2。需要 4 个块 (8点) 才能凑够历史。
    # 我们跳过前 4 个块 (data[0]...data[7])。
    x_hist = data[1:8] # 取前8个点中的后7个
    
    # i 从 4 开始 (跳过 0,1,2,3 四个块)
    for i in range(4, num_cycles):
        din = data[i*block_size : (i+1)*block_size] # 长度 2
        
        combined = np.concatenate((x_hist, din)) # 7 + 2 = 9
        
        for k in range(1): # 输出 1 点
            start_idx = k * 2
            window = combined[start_idx : start_idx + len(h)]
            y = np.sum(window[::-1] * h)
            res.append(y)
            
        # 更新历史：取 combined 的最后 7 个点
        # combined 长度 9。取 2~8
        x_hist = combined[2:9]
        
    return np.array(res)

# ==========================================
# 4. 执行级联计算 (L1 -> L2 -> L3 -> L4)
# ==========================================
print("开始 Python 级联计算...")
# L1
l1_out = golden_model_floating_L1(ideal_data_input, h_dec)
print(f"L1 输出长度: {len(l1_out)}")

# L2
l2_out = golden_model_floating_L2(l1_out, h_dec)
print(f"L2 输出长度: {len(l2_out)}")

# L3
l3_out = golden_model_floating_L3(l2_out, h_dec)
print(f"L3 输出长度: {len(l3_out)}")

# L4
# 最终的理想数据
ideal_data_final = golden_model_floating_L4(l3_out, h_dec)
print(f"L4 输出长度: {len(ideal_data_final)}")


# ==========================================
# 5. 读取 Verilog L4 输出文件
# ==========================================
def str2dec(hex_str):
    val = int(hex_str, 16)
    if val >= 2**(DATA_INTERNAL_WIDTH-1):
        val -= 2**DATA_INTERNAL_WIDTH
    return val 

# 这里的路径改为 a4_output.txt
OUTPUT_FROM_VERILOG = "D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/a4_output.txt"
sim_results = []

try:
    with open(OUTPUT_FROM_VERILOG, 'r') as f:
        for line in f:
            # L4 输出格式: 每行 1 个 hex 数据
            parts = line.strip().split(',')
            for p in parts:
                p = p.strip()
                if p:
                    sim_results.append(str2dec(p) / (2**COEF_FRAC))
except Exception as e:
    print(f"读取仿真文件失败: {e}")
    exit()

sim_results = np.array(sim_results)

# ==========================================
# 6. 结果比对与分析
# ==========================================
min_len = min(len(ideal_data_final), len(sim_results))
print(f"对比长度: {min_len}")

print(f"硬件 L4 前10点: {sim_results[:10]}")
print(f"Python L4 前10点: {ideal_data_final[:10]}")



# # 使用最佳偏移进行最终对比
a4_v = sim_results[ : min_len]
a4_p = ideal_data_final[:min_len]

error = a4_v - a4_p
max_err = np.max(np.abs(error))
rmse = np.sqrt(np.mean(error**2))

print("=" * 60)
print(f"L4 四级级联仿真误差分析")
print("-" * 60)
print(f"硬件输出示例: {a4_v[10:15]}")
print(f"理想模型示例: {a4_p[10:15]}")
print("-" * 60)
print(f"最大绝对误差: {max_err:.8f}")
print(f"均方根误差 (RMSE): {rmse:.8f}")

if rmse > 0:
    # 注意：经过4级下采样，信号幅度可能衰减或放大，信噪比计算仅供参考
    sig_power = np.mean(a4_p**2)
    print(f"量化信噪比估计: {10 * np.log10(sig_power / rmse**2):.2f} dB")
else:
    print("量化信噪比估计: Inf dB")
print("=" * 60)