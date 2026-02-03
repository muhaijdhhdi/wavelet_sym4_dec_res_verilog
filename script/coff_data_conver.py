#计算分解重构的系数以及量化
import math

# 配置
TOTAL_WIDTH = 25
FRAC_WIDTH = 23
SCALE_FACTOR = 1 << FRAC_WIDTH
MASK = (1 << TOTAL_WIDTH) - 1

# 输入数据
h_dec = [
    -0.07576571478927333, -0.02963552764599851, 0.49761866763201545, 0.80373875180591614,
     0.29785779560527736, -0.09921954357684722, -0.012603967262037833, 0.032223100604042759
]

h_rec = [
     0.032223100604042759, -0.012603967262037833, -0.09921954357684722, 0.29785779560527736,
     0.80373875180591614, 0.49761866763201545, -0.02963552764599851, -0.07576571478927333
]

def print_table(name, data):
    print(f"\n--- {name} ---")
    print(f"{'Idx':<3} | {'Float':<12} | {'Decimal':<10} | {'Binary (25 bits)'}")
    print("-" * 60)
    for i, val in enumerate(data):
        # 量化
        int_val = int(round(val * SCALE_FACTOR))
        # 补码处理
        twos_comp = int_val & MASK
        # 格式化
        bin_str = f"{twos_comp:0{TOTAL_WIDTH}b}"
        print(f"{i:<3} | {val:<12.8f} | {int_val:<10} | {bin_str}")

print_table("h_dec", h_dec)
print_table("h_rec", h_rec)