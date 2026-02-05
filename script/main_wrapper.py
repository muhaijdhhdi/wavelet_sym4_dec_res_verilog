#产生数据--x_gen.py
#比较软件和硬件产生的数据--hw_vs_sw.py
#使用的是将14个模块封装起来的总的模块，可以输出信号与baseline的比较
#其中数据可以是从其他地方加载过来的.
from x_gen import x_gen
from hw_vs_sw_wrapper import hw_vs_sw
from generate_verilog_coeffs import generate_verilog_coeffs
import numpy as np
if __name__=="__main__":
    
    COEF_WIDTH=25
    COEF_FRAC=23
    COEF_INT=COEF_WIDTH-COEF_FRAC

    ##  0.系数产生
    print(f"产生数据，系数的格式为{COEF_INT}.{COEF_FRAC}")
    generate_verilog_coeffs(coef_width=COEF_WIDTH,coef_frac=COEF_FRAC)
    print("数据产生成功")

    # 1. 产生数据
    # print("[1/4] Generating input data...")
    # #x_gen(seed=45, num_test_cycles=10000, amplitude=20000)#如果需要产生模拟数据则调用该函数,它会覆盖原来的数据，否则只需要原来的数据即可
    # print("-> x_input.txt has been generated.")

    # 2. 手动运行仿真
    print("\n" + "="*50)
    print("【请注意】：现在请去 Vivado 界面中，点击 'Run Simulation',结果使用16位来接收")
    print("等待仿真结束，且 base_output.txt 更新完成后...")
    print("="*50 + "\n")
    input(">>> 仿真完成后，请按【回车键】继续后续分析...")

    error_16=hw_vs_sw(output_num_bits=16)

    print("="*50)
    print("\n" + "="*50)
    print("【请注意】：现在请去 Vivado 界面中，点击 'Run Simulation',结果使用17位来接收")
    print("等待仿真结束，且 base_output.txt 更新完成后...")
    print("="*50 + "\n")
    input(">>> 仿真完成后，请按【回车键】继续后续分析...")

    error_17=hw_vs_sw(output_num_bits=17)
   
    print("="*50)
    print("对比使用16位接收 clean signal vs 使用17位接收 clean signal 的误差")
   
    # 打印数据
    for i in range(100):
        idx = i + 10000
        # <10 表示左对齐，占10个字符宽度
        print(f"{idx:<10} | {error_16[idx]:<15.4f} | {error_17[idx]:<15.4f}")
   
        
    print("-" * 50)
    print(f"最大绝对误差 (16-bit): {np.max(np.abs(error_16)):.4f}")
    print(f"最大绝对误差 (17-bit): {np.max(np.abs(error_17)):.4f}")

    # 计算 16位接收和17位接收 之间的差异 (如果硬件截断导致了误差，这个差值会很明显)
    # 注意：确保 error_16 和 error_17 长度一致，如果不一致需取交集
    min_len = min(len(error_16), len(error_17))
    diff_between_bits = error_16[:min_len] - error_17[:min_len]

    import matplotlib.pyplot as plt
    plt.figure(figsize=(12, 6))

    # 绘制两条误差曲线的对比(16bits和17bits的)
    plt.subplot(2, 1, 1)
    plt.plot(error_16[:min_len], label='Error with 16-bit Output', alpha=0.7)
    plt.plot(error_17[:min_len], label='Error with 17-bit Output', alpha=0.7, linestyle='--')
    plt.title('Comparison of HW-SW Errors (16-bit vs 17-bit Hardware Reception)')
    plt.ylabel('Error Amplitude')
    plt.legend()
    plt.grid(True, linestyle='--', alpha=0.5)

    # 绘制两者的差值 (显示增加 1 bit 带来的精度改善或溢出修正)
    plt.subplot(2, 1, 2)
    plt.plot(diff_between_bits, color='green', label='Difference (Error16 - Error17)')
    plt.title('Delta Error: Impact of Adding 1-bit Precision')
    plt.xlabel('Samples')
    plt.ylabel('Delta')
    plt.legend()
    plt.grid(True, linestyle='--', alpha=0.5)

    plt.tight_layout()
    plt.show()

    print("绘图完成。如果 Delta Error 在脉冲点处很大，说明 16 位接收确实存在溢出或严重的截断误差。")

    #结论，使用16位和17位的结果几乎一致，在baseline去除后，在脉冲处依旧有很大的误差，clean 比平时处大的原因不是由于16位减去16位溢出造成.





