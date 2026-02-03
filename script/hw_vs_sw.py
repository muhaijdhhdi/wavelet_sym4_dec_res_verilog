#本脚本比较实现的硬件方式的小波分解重构和python内部的小波分解重构的差异
import numpy as np
import pywt
import os

def hw_vs_sw():
    decompose_level=7
    mode='periodization'
    # mode='sym'
    #====================================
    x_input_path = "D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/x_input.txt"

    read_data = []
    if os.path.exists(x_input_path):
        with open(x_input_path, 'r') as f:
            for line in f:
                parts = line.strip().split(',')
                for p in parts:
                    if p:
                        # 16位 16进制转有符号十进制
                        val = int(p, 16)
                        if val >= 32768: 
                            val -= 65536
                        read_data.append(val)
    else:
        raise FileNotFoundError(f"找不到输入文件: {x_input_path}")

    input_data = np.array(read_data, dtype=np.int16)

    # 重新推导相关参数以防后续代码使用
    total_samples = len(input_data)
    num_test_cycles = total_samples // 16
    n = np.arange(total_samples)


    #============================================================
    coeffs=pywt.wavedec(input_data,'sym4',level=7,mode=mode)
    # for i, c in enumerate(coeffs):
    #     name = f"cA{decompose_level}" if i == 0 else f"cD{decompose_level - i + 1}"
    #     print(f"Layer {i}: {name} shape = {c.shape}")

    # reconstructed_signal=pywt.waverec(coeffs,'sym4',mode=mode)
    # error = np.max(np.abs(input_data - reconstructed_signal))
    # print(f"最大重建误差: {error:.2e}")
    #===============================================================
    coeffs_baseline = [coeffs[0]] + [np.zeros_like(c) for c in coeffs[1:]] 
    baseline_sw = pywt.waverec(coeffs_baseline, 'sym4', mode=mode)



    # ==========================================
    #绘制原始信号与提取基线的对比图
    import matplotlib.pyplot as plt
    plt.figure(figsize=(12, 6))
    plot_range = 1000 

    plt.plot(input_data[:plot_range], label='Original Signal', color='lightgray', alpha=0.7)
    plt.plot(baseline_sw[:plot_range], label='Extracted Baseline (cA7)', color='red', linewidth=2)

    plt.title('Comparison of Original Signal and Wavelet Baseline (Level 7)')
    plt.xlabel('Samples')
    plt.ylabel('Amplitude')
    plt.legend()
    plt.grid(True, linestyle='--', alpha=0.6)

    plt.tight_layout()
    plt.show()
    # ==========================================

    hw_file_path=hw_file_path = "D:/project/zu9_modifield+pulse_iir/PL/FMC_FH8052_zu9/FMC_FH8052.srcs/sources_1/imports/src/simulation/base_output.txt"
    def str2dec(hex_str, bits=16):
        val = int(hex_str, 16)
        if val >= 2**(bits-1):
            val -= 2**bits
        return val

    baseline_hw = []
    if os.path.exists(hw_file_path):
        try:
            with open(hw_file_path, 'r') as f:
                for line in f:
                    parts = line.strip().split(',')
                    for p in parts:
                        p = p.strip()
                        if p:
                            # 解析为16位有符号整数
                            baseline_hw.append(str2dec(p, 16))
        except Exception as e:
            print(f"读取文件出错: {e}")
    else:
        print(f"文件未找到: {hw_file_path}")

    baseline_hw = np.array(baseline_hw)
    search_range=2500
    best_lag=0
    min_rmse=float('inf')#将初始的均方差设为+无穷大

    compare_len=min(len(baseline_hw),len(baseline_sw))
    calc_len=min((compare_len),2000*16)

    if len(baseline_hw)>0:
        for lag in range (search_range):
            #baseline_sw[lag:lag+cal_len]
            #baseline_hw[:cal_len]
            if lag+calc_len>len(baseline_sw):break
            sw_segment=baseline_sw[lag:lag+calc_len]
            hw_segment=baseline_hw[:calc_len]

            #计算rmse
            diff=sw_segment-hw_segment
            rmse=np.array(np.mean(diff**2))

            if rmse<min_rmse:
                min_rmse=rmse
                best_lag=lag

        print("=" * 50)       
        print(f"自动对齐完成: 最佳延迟 offset = {best_lag} samples")
        print("-" * 50)

        #通过最佳的lag对齐后的软件和硬件的基线
        baseline_sw=baseline_sw[best_lag:best_lag+len(baseline_hw)]
        baseline_hw=baseline_hw[:len(baseline_sw)]

        final_error = baseline_sw - baseline_hw
        final_rmse = np.sqrt(np.mean(final_error**2))
        max_abs_err = np.max(np.abs(final_error))

        print(f"比对长度: {len(baseline_hw)} 点")
        print(f"Python SW Baseline (前5点): {baseline_sw[:20]}")
        print(f"Verilog HW Baseline (前5点): {baseline_hw[:20]}")
        print("-" * 50)
        print(f"最大绝对误差 (Max Abs Error): {max_abs_err:.4f}")
        print(f"均方根误差 (RMSE): {final_rmse:.4f}")

        if final_rmse > 0:
            signal_power = np.mean(baseline_sw**2)
            snr = 10 * np.log10(signal_power / final_rmse**2)
            print(f"量化信噪比 (SQNR): {snr:.2f} dB")
        else:
            print("量化信噪比 (SQNR): Inf dB (完全一致)")
        print("=" * 50)

        # 4. 绘图
        plt.figure(figsize=(12, 8))
        
        plt.subplot(2, 1, 1)
        plt.title(f'Baseline Comparison (Aligned at offset {best_lag})')
        # 只画前 100000 个点以便观察细节
        plot_len = min(50000, len(baseline_hw))
        plt.plot(baseline_sw[:plot_len], label='Python (pywt)', linewidth=2, alpha=0.8)
        plt.plot(baseline_hw[:plot_len], label='Hardware (Sim)', linestyle='--', linewidth=2, alpha=0.8)
        plt.legend()
        plt.grid(True)
        
        plt.subplot(2, 1, 2)
        plt.title('Error (SW - HW)')
        plt.plot(final_error[:plot_len], color='red', label='Difference')
        plt.legend()
        plt.grid(True)
        
        plt.tight_layout()
        plt.show()

    else:
        print("未读取到硬件数据，无法进行对比。")

    print(f"软件基线均值: {np.mean(np.abs(baseline_sw))}")
    print(f"硬件基线均值: {np.mean(np.abs(baseline_hw))}")

            



