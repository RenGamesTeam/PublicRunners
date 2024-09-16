import time

def countdown(total_seconds):
    print(f"Starting countdown for {total_seconds // 60} minutes ({total_seconds} seconds):")

    # 计算下一个打印时间点的初始值
    next_print_time = total_seconds

    while total_seconds > 0:
        # 如果当前时间超过了下一个打印时间点，或者剩余时间小于 2 分钟时
        if total_seconds <= next_print_time or total_seconds % 120 == 0:
            mins, secs = divmod(total_seconds, 60)
            time_format = f'{mins:02}:{secs:02}'
            print(f"Remaining time: {time_format}")

            # 设置下一个打印时间点（每 2 分钟）
            next_print_time -= 120
        
        time.sleep(1)
        total_seconds -= 1

    print("Time's up!")

if __name__ == "__main__":
    countdown(18000)