import numpy as np

COEF_FRAC=23

DATA_WIDTH=16

DATA_INTERNAL_WIDTH=48

NUM_TEST_CYCLES=1000

TOTAL_SAMPLES = NUM_TEST_CYCLES * 16



h_dec = [

    -0.07576571478927333, -0.02963552764599851, 0.49761866763201545, 0.80373875180591614,

     0.29785779560527736, -0.09921954357684722, -0.012603967262037833, 0.032223100604042759

]



#1.信号生成

n=np.arange(TOTAL_SAMPLES)

amplitude=20000

ideal_data=amplitude * np.sin(2 * np.pi * n / 128)

ideal_data=ideal_data.astype(np.int16)





#模拟硬件进行l1的dec运算

def golden_model_floating(data,h):

   num_cycles=len(data)//16

   res=[]



   x_hist=data[9:16]

   for i in range(1,num_cycles):

      din=data[i*16:i*16+16]

      combined=np.concatenate((x_hist,din))

      for k in range(8):

         start_idx=k*2

         window=combined[start_idx:start_idx+len(h)]

         y=np.sum(window[::-1]*h)

         res.append(y)

      x_hist=din[9:16]

   return np.array(res)



ideal_data = golden_model_floating(ideal_data, h_dec)

def str2dec(hex_str):

   val=int(hex_str,16)#将input的字符串转换为十进制数,无符号的

   if val >=2**(DATA_INTERNAL_WIDTH-1):

        val -=2**DATA_INTERNAL_WIDTH#如果最高位为1，为负数，则需要进行补码转换

   return val



OUTPUT_A_from_verilog = "D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/a1_output.txt"

sim_results = []



#读取verilog计算产生的数据

try:

    with open(OUTPUT_A_from_verilog, 'r') as f:

        for line in f:

            parts = line.strip().split(',')

            for p in parts:

                p = p.strip()

                if p:

                    sim_results.append(str2dec(p) / (2**COEF_FRAC))

except Exception as e:

    print(f"读取仿真文件失败: {e}")

    exit()



sim_results = np.array(sim_results)



#4. 结果比对与分析

# ==========================================

min_len = min(len(ideal_data), len(sim_results))

print(len(ideal_data), len(sim_results), min_len)

a1_p = ideal_data[8:min_len]

a1_v = sim_results[8:min_len]



# 计算残差

error = a1_v - a1_p

max_err = np.max(np.abs(error))

rmse = np.sqrt(np.mean(error**2))



print("=" * 60)

print(f"比对数据长度: {min_len} 个采样点")

print(f"硬件输出前5点: {a1_v[8:30]}")

print(f"理想模型前5点: {a1_p[8:30]}")

print("-" * 60)

print(f"最大绝对误差: {max_err:.8f}")

print(f"均方根误差 (RMSE): {rmse:.8f}")

print(f"量化信噪比估计: {20 * np.log10(amplitude/rmse):.2f} dB")

print("=" * 60)

