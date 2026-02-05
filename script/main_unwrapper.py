#产生数据--x_gen.py
#分析误差--a171_error_analysis.py
#比较软件和硬件产生的数据--hw_vs_sw.py
#使用的是没有将14的模块包装起来的分离模块
from x_gen import x_gen
from hw_vs_sw_unwrapper import hw_vs_sw
from a171_error_analysis_unwrapper import a171_error_analysis
from generate_verilog_coeffs import generate_verilog_coeffs
if __name__ == "__main__":
     
    COEF_WIDTH=25
    COEF_FRAC=23
    COEF_INT=COEF_WIDTH-COEF_FRAC

    ##  0.系数产生
    print(f"产生数据，系数的格式为{COEF_INT}.{COEF_FRAC}")
    generate_verilog_coeffs(coef_width=COEF_WIDTH,coef_frac=COEF_FRAC)
    print("数据产生成功")
    # 1. 产生数据
    print("[1/4] Generating input data...")
    x_gen(seed=45, num_test_cycles=10000, amplitude=20000)
    print("-> x_input.txt has been generated.")

    # 2. 手动运行仿真
    print("\n" + "="*50)
    print("【请注意】：现在请去 Vivado 界面中，点击 'Run Simulation'")
    print("等待仿真结束，且 base_output.txt 更新完成后...")
    print("="*50 + "\n")
    
    # 这里会暂停，等待你按回车
    input(">>> 仿真完成后，请按【回车键】继续后续分析...")

    # 3. 误差分析
    print("[3/4] Analyzing Error...")
    a171_error_analysis(DATA_INTERNAL_WIDTH=48,COEF_FRAC=23)

    # 4. 对比
    print("[4/4] Comparing HW vs SW...")
    hw_vs_sw()
