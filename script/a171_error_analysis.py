#分析分解重构部分的误差
import numpy as np
import os

# ==========================================
# 1. 全局配置与系数
# ==========================================
COEF_FRAC = 23
DATA_WIDTH = 16
DATA_INTERNAL_WIDTH = 48
NUM_TEST_CYCLES = 2000
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
seed = 121
np.random.seed(seed)
amplitude = 20000
#raw_input = amplitude * np.sin(2 * np.pi * n / 128)
raw_input = np.random.uniform(-amplitude, amplitude, TOTAL_SAMPLES)
# 使用 round 模拟更好的量化，或者保持 astype(int16) 视你硬件输入而定
ideal_data_input = raw_input.astype(np.int16)

# ==========================================
# 3. Python 黄金模型 (L1 -> L2 -> L3 -> L4 ->L5 ->L6->L7)
# ==========================================

# --- L1 模型 (Block Size: 16 -> 8) ---
def dec_L1(data, h):
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
def dec_L2(data, h):
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
def dec_L3(data, h):
    block_size = 4
    num_cycles = len(data) // block_size
    res = []
    x_hist = data[1:8] 
    for i in range(2, num_cycles):
        din = data[i*block_size : (i+1)*block_size] # 长度 4
        
        combined = np.concatenate((x_hist, din)) # 7 + 4 = 11
        
        for k in range(2): # 输出 2 点
            start_idx = k * 2
            window = combined[start_idx : start_idx + len(h)]
            y = np.sum(window[::-1] * h)
            res.append(y)
        x_hist = combined[4:11] 
        
    return np.array(res)

# --- L4 模型 (Block Size: 2 -> 1) ---
def dec_L4(data, h):
    block_size = 2
    num_cycles = len(data) // block_size
    res = []
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
#L5 模型 (Block Size: 1 -> 1)
def dec_L5(data, h):
    block_size = 1
    num_cycles = len(data) // block_size
    res = []
    x_hist = data[0:7]
    phase=0 #记录是否应该计算输出，因为l5以后是每2个点输出1个点
    
    # i 从 8 开始 (跳过 0~6 7个块)
    for i in range(7, num_cycles):
        if phase==0:
            phase=1
        else:
            phase=0

        din = data[i*block_size : (i+1)*block_size] # 长度 1
        combined = np.concatenate((x_hist, din)) # 7 + 1 = 8
        if phase == 1:
            for k in range(1): # 输出 1 点
                start_idx = k * 2
                window = combined[start_idx : start_idx + len(h)]
                y = np.sum(window[::-1] * h)
                res.append(y)
        x_hist = combined[1:8]
        

    return np.array(res)

def dec_L6(data, h):
    block_size = 1
    num_cycles = len(data) // block_size
    res = []
    x_hist = data[0:7]
    phase=0

    for i in range(7, num_cycles):
        if phase==0:
            phase=1
        else:
            phase=0
        din = data[i*block_size : (i+1)*block_size] # 长度 1
        combined = np.concatenate((x_hist, din)) # 7 + 1 = 8
        
        if phase == 1:
            for k in range(1): # 输出 1 点
                start_idx = k * 2
                window = combined[start_idx : start_idx + len(h)]
                y = np.sum(window[::-1] * h)
                res.append(y)
        x_hist = combined[1:8]
        
    return np.array(res)

def dec_L7(data, h):
    block_size = 1
    num_cycles = len(data) // block_size
    res = []
    x_hist = data[0:7]
    phase=0

    for i in range(7, num_cycles):
        if phase==0:
            phase=1
        else:
            phase=0
        din = data[i*block_size : (i+1)*block_size] # 长度 1
        combined = np.concatenate((x_hist, din)) # 7 + 1 = 8
        
        if phase == 1:
            for k in range(1): # 输出 1 点
                start_idx = k * 2
                window = combined[start_idx : start_idx + len(h)]
                y = np.sum(window[::-1] * h)
                res.append(y)
        x_hist = combined[1:8]
        
    return np.array(res)
# ==========================================
# 4. 执行级联计算 (L1 -> L2 -> L3 -> L4 -> L5 -> L6 -> L7)
# ==========================================
print("开始 Python 级联计算...")
# L1
l1_out = dec_L1(ideal_data_input, h_dec)
print(f"L1 输出长度: {len(l1_out)}")

# L2
l2_out = dec_L2(l1_out, h_dec)
print(f"L2 输出长度: {len(l2_out)}")

# L3
l3_out = dec_L3(l2_out, h_dec)
print(f"L3 输出长度: {len(l3_out)}")

# L4
# 最终的理想数据
l4_out = dec_L4(l3_out, h_dec)
print(f"L4 输出长度: {len(l4_out)}")

# L5
l5_out = dec_L5(l4_out, h_dec)
print(f"L5 输出长度: {len(l5_out)}")

# L6
l6_out = dec_L6(l5_out, h_dec)
print(f"L6 输出长度: {len(l6_out)}")

# L7
l7_out = dec_L7(l6_out, h_dec)
print(f"L7 输出长度: {len(l7_out)}")

# ==========================================
# 5. 读取 Verilog L7 输出文件将其转化为10进制数
# ==========================================
def str2dec(hex_str,shift_num=DATA_INTERNAL_WIDTH):
    val = int(hex_str, 16)
    if val >= 2**(shift_num-1):
        val -= 2**shift_num
    return val 

# 这里的路径改为 a7_output.txt
OUTPUT_FROM_VERILOG = "D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/a7_output.txt"
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
    # exit() # 为了后续重构代码能运行，暂时屏蔽退出

sim_results = np.array(sim_results)

# ==========================================
# 6. 结果比对与分析
# ==========================================
ideal_data_final = l7_out
# 对齐数据长度
min_len = min(len(ideal_data_final), len(sim_results))
print(f"对比长度: {min_len}")

if min_len > 0:
    print(f"硬件 L7  前10点: {sim_results[:10]}")
    print(f"Python L7 前10点: {ideal_data_final[:10]}")

    # # 使用最佳偏移进行最终对比
    a7_v = sim_results[ : min_len]
    a7_p = ideal_data_final[:min_len]

    error = a7_v - a7_p
    max_err = np.max(np.abs(error))
    rmse = np.sqrt(np.mean(error**2))

    print("=" * 60)
    print(f"L7 七级级联仿真误差分析")
    print("-" * 60)
    print(f"硬件输出示例: {a7_v[10:15]}")
    print(f"理想模型示例: {a7_p[10:15]}")
    print("-" * 60)
    print(f"最大绝对误差: {max_err:.8f}")
    print(f"均方根误差 (RMSE): {rmse:.8f}")

    if rmse > 0:
        # 注意：经过5级下采样，信号幅度可能衰减或放大，信噪比计算仅供参考
        sig_power = np.mean(a7_p**2)
        print(f"量化信噪比估计: {10 * np.log10(sig_power / rmse**2):.2f} dB")
    else:
        print("量化信噪比估计: Inf dB")
    print("=" * 60)
else:
    print("未读取到足够的 L7 硬件数据，跳过误差分析。")

###以下为将重构的模块添加到分解的部分后面
# ==========================================
def res_L7(data,h):
    block_size=1
    num_cycles=len(data)//block_size
    res=[]
    x_hist=data[0:3]
    h_even=h[::2]
    h_odd=h[1::2]

    for i in range(3,num_cycles):
        
        din=data[i]
        window=np.concatenate((x_hist,[din]))
        y_even=np.sum(window[::-1]*h_even)
        res.append(y_even)
        y_odd=np.sum(window[::-1]*h_odd)
        res.append(y_odd)
        x_hist=window[1:4]
    return np.array(res)

def res_L6(data,h):
    block_size=1
    num_cycle=len(data)//block_size
    res=[]
    x_hist=data[0:3]
    h_even=h[::2]
    h_odd=h[1::2]

    for i in range(3,num_cycle):
        din=data[i]
        window=np.concatenate((x_hist,[din]))
        y_even=np.sum(window[::-1]*h_even)
        res.append(y_even)
        y_odd=np.sum(window[::-1]*h_odd)
        res.append(y_odd)
        x_hist=window[1:4]
    return np.array(res)

def res_L5(data,h):#1/2->1
    block_size=1
    num_cycle=len(data)//block_size
    res=[]
    x_hist=data[0:3]
    h_even=h[::2]
    h_odd=h[1::2]

    for i in range(3,num_cycle):
        din=data[i]
        window=np.concatenate((x_hist,[din]))
        y_even=np.sum(window[::-1]*h_even)
        res.append(y_even)
        y_odd=np.sum(window[::-1]*h_odd)
        res.append(y_odd)
        x_hist=window[1:4]
    return np.array(res)

def res_L4(data,h):#1->2
    num_cycle=len(data)//1
    res=[]
    x_hist=data[0:3]
    h_even=h[::2]
    h_odd=h[1::2]


    for i in range(3,num_cycle):
        din=data[i]
        window=np.concatenate((x_hist,[din]))
        y_even=np.sum(window[::-1]*h_even)
        res.append(y_even)
        y_odd=np.sum(window[::-1]*h_odd)
        res.append(y_odd)
        x_hist=window[1:4]
    return np.array(res)

def res_L3(data,h):#2->4
    block_size=2
    num_cycles=len(data)//block_size
    res=[]
    x_hist=data[1:4]
    h_even=h[::2]
    h_odd=h[1::2]
    for i in range(2,num_cycles):
        for j in range(block_size):
            din=data[i*block_size+j]
            for k in range(2):#奇偶 k=1,奇数
                if(k==0):
                    h2=h_even
                else:
                    h2=h_odd                                               
                window=np.concatenate((x_hist,[din]))                                 
                y=np.sum(window[::-1]*h2)                                           
                res.append(y)
            x_hist=window[1:4]
    return np.array(res)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            

def res_L2(data,h):#4->8
    block_size=4
    num_cycles=len(data)//block_size
    res=[]
    x_hist=data[1:4]

    for i in range(1,num_cycles):
        for j in range(block_size):
            din=data[block_size*i+j]
            for k in range(2):
                if(k==0):
                    h2=h[::2]
                else: 
                    h2=h[1::2]
                window=np.concatenate((x_hist,[din]))
                y=np.sum(window[::-1]*h2)
                res.append(y)
            x_hist=window[1:4]
    return np.array(res)

def res_L1(data,h):#8->16
    block_size=8
    num_cycles=len(data)//block_size
    res=[]
    x_hist=data[5:8]
    
    for i in range(1,num_cycles):
        for j in range(block_size):
            din=data[i*block_size+j]
            for k in range(2):
                if(k==0):
                    h2=h[::2]
                else:
                    h2=h[1::2]
                window=np.concatenate((x_hist,[din]))
                y=np.sum(window[::-1]*h2)
                res.append(y)
            x_hist=window[1:4]
    return np.array(res)
                    
    

# ==========================================
# 7. 执行重构级联与 Baseline 对比
# ==========================================
print("\n" + "="*30)
print("开始 Python 重构级联计算...")
print("="*30)

# 级联调用
h_res=h_dec[::-1]
try:
    rec_r6 = res_L7(l7_out, h_res)
    print(f"Reconstruct L7 -> r6 shape: {rec_r6.shape}")

    rec_r5 = res_L6(rec_r6, h_res)
    print(f"Reconstruct L6 -> r5 shape: {rec_r5.shape}")

    rec_r4 = res_L5(rec_r5, h_res)
    print(f"Reconstruct L5 -> r4 shape: {rec_r4.shape}")

    rec_r3 = res_L4(rec_r4, h_res)
    print(f"Reconstruct L4 -> r3 shape: {rec_r3.shape}")

    rec_r2 = res_L3(rec_r3, h_res)
    print(f"Reconstruct L3 -> r2 shape: {rec_r2.shape}")

    rec_r1 = res_L2(rec_r2, h_res)
    print(f"Reconstruct L2 -> r1 shape: {rec_r1.shape}")

    final_baseline_rec = res_L1(rec_r1, h_res)
    print(f"Reconstruct L1 -> Baseline shape: {final_baseline_rec.shape}")

except Exception as e:
    print(f"级联计算中断: {e}")
    final_baseline_rec = np.array([])
    # 为避免下方报错，给中间变量也赋空值
    rec_r6 = np.array([])
    rec_r5 = np.array([])
    rec_r4 = np.array([])
    rec_r3 = np.array([])
    rec_r2 = np.array([])
    rec_r1 = np.array([])

# ==========================================
# 7.1 中间级重构误差分析 (Added)
# ==========================================
print("\n" + "="*60)
print("开始 中间级重构 (r6...r1) 误差分析")
print("="*60)

# 定义辅助函数进行重复的读取和比较工作
def analyze_rec_stage(stage_label, filename, python_data,front_disp=5,base_or_not=False,start=0):
    base_path = "D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/"
    full_path = base_path + filename
    
    sim_data = []
    if os.path.exists(full_path):
        try:
            with open(full_path, 'r') as f:
                for line in f:
                    parts = line.strip().split(',')
                    for p in parts:
                        p = p.strip()
                        if p and not base_or_not:
                            sim_data.append(str2dec(p) / (2**COEF_FRAC))
                        elif p:
                            sim_data.append(str2dec(p,16))
            
            sim_data = np.array(sim_data)
            
            # 对齐
            min_len = min(len(python_data), len(sim_data))
            
            if min_len > 0:
                s_v = sim_data[start:min_len]
                s_p = python_data[start:min_len]
                err = s_v - s_p
                rmse = np.sqrt(np.mean(err**2))
                max_abs_err = np.max(np.abs(err))
                
                print(f"[{stage_label}] (File: {filename})")
                print(f"  - 样本数: {min_len}")
                print(f"  - 硬件前5点: {s_v[:front_disp]}")
                print(f"  - Python前5点: {s_p[:front_disp]}")
                print(f"  - Max Error: {max_abs_err:.8f}")
                print(f"  - RMSE: {rmse:.8f}")
                print("-" * 40)
            else:
                print(f"[{stage_label}] 数据长度不足 (Py:{len(python_data)}, Hw:{len(sim_data)})")
                
        except Exception as e:
            print(f"[{stage_label}] 读取或处理文件失败: {e}")
    else:
        print(f"[{stage_label}] 文件未找到: {full_path}")

# 依次执行各级分析
analyze_rec_stage("Rec_L7 -> r6", "r6_output.txt", rec_r6)
analyze_rec_stage("Rec_L6 -> r5", "r5_output.txt", rec_r5)
analyze_rec_stage("Rec_L5 -> r4", "r4_output.txt", rec_r4)
analyze_rec_stage("Rec_L4 -> r3", "r3_output.txt", rec_r3)
analyze_rec_stage("Rec_L3 -> r2", "r2_output.txt", rec_r2)
analyze_rec_stage("Rec_L2 -> r1", "r1_output.txt", rec_r1)
analyze_rec_stage("Res_L_1-> baseLine","base_output.txt",final_baseline_rec,front_disp=20,base_or_not=True)

# ==========================================
# 8. 重构各级信噪比计算
# ==========================================
def calculate_snr(stage_label, filename, python_data, base_or_not=False, start=0):
    base_path = "D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/"
    full_path = base_path + filename
    
    sim_data = []
    if os.path.exists(full_path):
        with open(full_path, 'r') as f:
            for line in f:
                parts = line.strip().split(',')
                for p in parts:
                    p = p.strip()
                    if p and not base_or_not:
                        sim_data.append(str2dec(p) / (2**COEF_FRAC))
                    elif p:
                        sim_data.append(str2dec(p, 16))
        
        sim_data = np.array(sim_data)
        min_len = min(len(python_data), len(sim_data))
        
        if min_len > start:
            s_v = sim_data[start:min_len]
            s_p = python_data[start:min_len]
            error = s_v - s_p
            rmse = np.sqrt(np.mean(error**2))
            
            if rmse > 0:
                sig_power = np.mean(s_p**2)
                snr = 10 * np.log10(sig_power / rmse**2)
                print(f"{stage_label} 量化信噪比估计: {snr:.2f} dB")
            else:
                print(f"{stage_label} 量化信噪比估计: Inf dB")

print("=" * 60)
print("重构级联信噪比分析")
print("-" * 60)
calculate_snr("Rec_L7 (r6)", "r6_output.txt", rec_r6)
calculate_snr("Rec_L6 (r5)", "r5_output.txt", rec_r5)
calculate_snr("Rec_L5 (r4)", "r4_output.txt", rec_r4)
calculate_snr("Rec_L4 (r3)", "r3_output.txt", rec_r3)
calculate_snr("Rec_L3 (r2)", "r2_output.txt", rec_r2)
calculate_snr("Rec_L2 (r1)", "r1_output.txt", rec_r1)
calculate_snr("Rec_L1 (base)", "base_output.txt", final_baseline_rec, base_or_not=True, start=8)
print("=" * 60)