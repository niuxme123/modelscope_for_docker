#!/usr/bin/env python3
"""
用法:
    python3 download-info.py <监控目录> [总大小]
    python3 download-info.py --once <监控目录> [总大小]

总大小省略（或写 0/auto）时，只显示已下载量与速度，不算百分比/ETA。

环境变量:
    SAMPLE_INTERVAL  采样间隔秒数（默认 10）
    HOST_DIR         宿主机上的对应目录（仅用于展示）
"""

import os
import sys
import time
import re
import shutil
import signal
from pathlib import Path

UNIT_MAP = {
    'B': 1, 'K': 1024, 'KB': 1024, 'M': 1024 ** 2, 'MB': 1024 ** 2,
    'G': 1024 ** 3, 'GB': 1024 ** 3, 'T': 1024 ** 4, 'TB': 1024 ** 4,
    'P': 1024 ** 5, 'PB': 1024 ** 5,
}

SAMPLE_INTERVAL = int(os.environ.get("SAMPLE_INTERVAL", "10"))
# 宿主机对应目录（仅用于展示，由 entrypoint 传入）
HOST_DIR = os.environ.get("HOST_DIR", "").strip()


def parse_size(size_str: str) -> int:
    s = size_str.strip().upper().replace(' ', '')
    m = re.fullmatch(r'([0-9]*\.?[0-9]+)([A-Z]*)', s)
    if not m:
        raise ValueError(f"无法解析大小: {size_str!r}，示例: 1.56T / 500G")
    num = float(m.group(1))
    unit = m.group(2) or 'B'
    if unit not in UNIT_MAP:
        raise ValueError(f"未知单位: {unit!r}")
    return int(num * UNIT_MAP[unit])


def get_dir_stats(path: Path):
    logical = 0
    actual = 0
    for entry in path.rglob('*'):
        # hubdl 自己的缓存目录（.hubdl）不计入下载量
        if '.hubdl' in entry.parts:
            continue
        if entry.is_file():
            try:
                st = entry.stat()
                logical += st.st_size
                actual += st.st_blocks * 512
            except OSError:
                pass
    return logical, actual


def format_bytes(size: float) -> str:
    for unit in ['B', 'KB', 'MB', 'GB', 'TB', 'PB']:
        if size < 1024.0:
            return f"{size:.2f}{unit}"
        size /= 1024.0
    return f"{size:.2f}EB"


def format_duration(seconds: float) -> str:
    seconds = int(max(seconds, 0))
    days, seconds = divmod(seconds, 86400)
    hours, seconds = divmod(seconds, 3600)
    minutes, seconds = divmod(seconds, 60)
    if days > 0:
        return f"{days}d{hours:02d}:{minutes:02d}:{seconds:02d}"
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}"


def terminal_width() -> int:
    try:
        return shutil.get_terminal_size().columns
    except Exception:
        return 80


def render_status(elapsed, logical, actual, total,
                  speed_mbps, monitor_avg, eta_seconds) -> str:
    head = f"已用:{format_duration(elapsed)}"
    if total <= 0:
        # 总大小未知：只报已下载量与速度
        return (
            f"{head} "
            f"| 已下载:{format_bytes(actual)}(名义{format_bytes(logical)}) "
            f"| 窗口:{speed_mbps:5.1f}MB/s "
            f"| 监控均:{monitor_avg:5.1f}MB/s"
        )
    logical_pct = (logical / total) * 100 if total > 0 else 0
    actual_pct = (actual / total) * 100 if total > 0 else 0
    remaining = max(total - actual, 0)
    return (
        f"{head} "
        f"| 名义:{logical_pct:5.2f}%({format_bytes(logical)}) "
        f"| 真实:{actual_pct:5.2f}%({format_bytes(actual)}) "
        f"| 剩余:{format_bytes(remaining)} "
        f"| 窗口:{speed_mbps:5.1f}MB/s "
        f"| 监控均:{monitor_avg:5.1f}MB/s "
        f"| ETA:{format_duration(eta_seconds)}"
    )


def main():
    args = list(sys.argv[1:])
    once = False
    if "--once" in args:
        once = True
        args.remove("--once")

    if len(args) not in (1, 2):
        print(__doc__)
        sys.exit(1)

    model_dir = Path(args[0])
    total_size_bytes = 0
    if len(args) == 2:
        raw_total = args[1].strip()
        if raw_total and raw_total.lower() not in ("auto", "0", "unknown", "-"):
            try:
                total_size_bytes = parse_size(raw_total)
            except ValueError as exc:
                print(f"警告: {exc}，按『未知总大小』处理", file=sys.stderr)
                total_size_bytes = 0

    if not model_dir.exists():
        print(f"错误: 目录不存在 {model_dir}", file=sys.stderr)
        sys.exit(1)

    tty = sys.stdout.isatty()

    if once:
        logical, actual = get_dir_stats(model_dir)
        print(render_status(0, logical, actual, total_size_bytes, 0, 0, 0))
        return

    start_time = time.time()
    last_logical, last_actual = get_dir_stats(model_dir)
    baseline_actual = last_actual
    baseline_time = start_time
    last_time = start_time

    print(f"监控目录: {HOST_DIR or model_dir}")
    if HOST_DIR:
        print(f"容器内路径: {model_dir}")
    if total_size_bytes > 0:
        print(f"预计总大小: {format_bytes(total_size_bytes)}")
    else:
        print("预计总大小: 未知（只显示已下载量与速度）")
    print(f"采样窗口: {SAMPLE_INTERVAL}s")
    print(f"输出模式: {'TTY(单行刷新)' if tty else 'LOG(每次一行)'}")
    print("-" * min(terminal_width(), 120))
    sys.stdout.flush()

    stop_flag = {"v": False}

    def _on_term(signum, frame):
        stop_flag["v"] = True

    signal.signal(signal.SIGTERM, _on_term)

    try:
        while not stop_flag["v"]:
            # 用短睡眠切片，保证 SIGTERM 能尽快生效
            slept = 0.0
            while slept < SAMPLE_INTERVAL and not stop_flag["v"]:
                time.sleep(0.2)
                slept += 0.2
            if stop_flag["v"]:
                break

            logical, actual = get_dir_stats(model_dir)
            current_time = time.time()
            elapsed = current_time - start_time

            delta_actual = actual - last_actual
            delta_time = current_time - last_time
            speed_mbps = (delta_actual / (1024 * 1024)) / delta_time if delta_time > 0 else 0

            delta_from_baseline = actual - baseline_actual
            monitor_elapsed = current_time - baseline_time
            monitor_avg = (delta_from_baseline / (1024 * 1024)) / monitor_elapsed if monitor_elapsed > 0 else 0

            remaining_actual = max(total_size_bytes - actual, 0)
            eta_seconds = remaining_actual / (speed_mbps * 1024 * 1024) if speed_mbps > 0 else 0

            line = render_status(elapsed, logical, actual, total_size_bytes,
                                 speed_mbps, monitor_avg, eta_seconds)

            if tty:
                sys.stdout.write("\033[2K\r" + line)
            else:
                sys.stdout.write(line + "\n")
            sys.stdout.flush()

            last_logical, last_actual = logical, actual
            last_time = current_time

    except KeyboardInterrupt:
        pass
    finally:
        if tty:
            sys.stdout.write("\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
