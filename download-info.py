#!/usr/bin/env python3
"""
用法:
    python3 download-info.py <监控目录> [总大小]
    python3 download-info.py --once [--done] <监控目录> [总大小]

总大小省略（或写 0/auto）时，只显示已下载量与速度，不算百分比/ETA。
--once  只输出一行快照；--done 表示下载已成功结束，输出最终汇总。

进度以「实际落盘字节」(st_blocks*512) 为准：
aria2 用 -x N 多连接写入时，文件 st_size 会瞬间接近完整大小（写入偏移分散），
所以「逻辑大小」不能当进度用，这里不再展示。

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
    """返回 (逻辑字节, 实际落盘字节, 文件数)。

    跳过 hubdl 缓存目录 .hubdl 与 aria2 控制文件 *.aria2。
    """
    logical = 0
    actual = 0
    files = 0
    for entry in path.rglob('*'):
        # hubdl 自己的缓存目录（.hubdl）不计入下载量
        if '.hubdl' in entry.parts:
            continue
        if entry.is_file():
            if entry.name.endswith('.aria2'):  # aria2 控制文件，非数据
                continue
            try:
                st = entry.stat()
                logical += st.st_size
                actual += st.st_blocks * 512
                files += 1
            except OSError:
                pass
    return logical, actual, files


def read_manifest(model_dir: Path):
    """读取 hubdl 写的 .hubdl/manifest，返回 {相对路径: 大小}；不存在返回 None。

    manifest 是 hubdl 本次真正要下载的文件清单（已应用 --include/--exclude），
    比 API 估算的总大小更贴近实际。
    """
    manifest = model_dir / '.hubdl' / 'manifest'
    if not manifest.is_file():
        return None
    entries = {}
    try:
        with manifest.open('r', encoding='utf-8', errors='replace') as fh:
            for line in fh:
                line = line.rstrip('\n')
                if not line or line.startswith('#'):
                    continue
                parts = line.split('\t')
                if len(parts) < 3:
                    continue
                try:
                    size = int(parts[0])
                except ValueError:
                    continue
                entries[parts[-1]] = size
    except OSError:
        return None
    return entries or None


def manifest_report(model_dir: Path, entries) -> dict:
    """按 manifest 比对落盘情况（用于下载结束后的最终汇总）。"""
    expected = 0
    done = 0
    complete = 0
    incomplete = []
    for rel, size in entries.items():
        expected += size
        try:
            cur = (model_dir / rel).stat().st_size
        except OSError:
            cur = None
        if cur is not None and cur >= size:
            done += size
            complete += 1
        else:
            incomplete.append((rel, size, cur))
    return {
        'expected': expected,
        'done': done,
        'complete': complete,
        'total_files': len(entries),
        'incomplete': incomplete,
    }


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


def render_status(elapsed, actual, total,
                  speed_mbps, monitor_avg, eta_seconds) -> str:
    head = f"已用:{format_duration(elapsed)}"
    if total <= 0:
        # 总大小未知：只报已下载量与速度
        return (
            f"{head} "
            f"| 已下载:{format_bytes(actual)} "
            f"| 窗口:{speed_mbps:5.1f}MB/s "
            f"| 监控均:{monitor_avg:5.1f}MB/s"
        )
    pct = min(actual / total * 100, 100.0)
    remaining = max(total - actual, 0)
    return (
        f"{head} "
        f"| 进度:{pct:5.2f}%({format_bytes(actual)}) "
        f"| 剩余:{format_bytes(remaining)} "
        f"| 窗口:{speed_mbps:5.1f}MB/s "
        f"| 监控均:{monitor_avg:5.1f}MB/s "
        f"| ETA:{format_duration(eta_seconds)}"
    )


def render_done(actual, files, total, report=None) -> str:
    """下载成功结束时的汇总：以 hubdl manifest 为准，不报『剩余』。"""
    if report:
        expected = report['expected']
        done = report['done']
        pct = (done / expected * 100) if expected > 0 else 100.0
        line = (
            f"已完整:{format_bytes(done)} / 清单:{format_bytes(expected)}"
            f"（{report['complete']}/{report['total_files']} 个文件，{pct:.2f}%）"
        )
        if report['incomplete']:
            line += "  ⚠ 以下文件未完整："
            for rel, size, cur in report['incomplete'][:5]:
                lack = size - (cur or 0)
                line += f"\n    - {rel}（缺 {format_bytes(lack)}）"
            rest = len(report['incomplete']) - 5
            if rest > 0:
                line += f"\n    - ... 还有 {rest} 个"
        return line

    # 没有 manifest（老版本 hubdl / 清空了 .hubdl）时退回按总量估算
    head = f"已落盘:{format_bytes(actual)}"
    if total <= 0:
        return f"{head}（{files} 个文件）"
    pct = min(actual / total * 100, 100.0)
    return f"{head} / 清单:{format_bytes(total)}（{pct:.2f}%，{files} 个文件）"


def main():
    args = list(sys.argv[1:])
    once = False
    done = False
    if "--once" in args:
        once = True
        args.remove("--once")
    if "--done" in args:
        done = True
        once = True
        args.remove("--done")

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
        if done:
            _, actual, files = get_dir_stats(model_dir)
            entries = read_manifest(model_dir)
            report = manifest_report(model_dir, entries) if entries else None
            print(render_done(actual, files, total_size_bytes, report))
        else:
            _, actual, files = get_dir_stats(model_dir)
            print(render_status(0, actual, total_size_bytes, 0, 0, 0))
        return

    start_time = time.time()
    _, last_actual, _ = get_dir_stats(model_dir)
    baseline_actual = last_actual
    baseline_time = start_time
    last_time = start_time
    manifest_state = {"mtime": None, "entries": None}

    def manifest_total():
        """hubdl 写出 manifest 后，用它的总量作为进度分母（更准）。"""
        manifest = model_dir / '.hubdl' / 'manifest'
        try:
            mtime = manifest.stat().st_mtime
        except OSError:
            return None
        if manifest_state["mtime"] != mtime:
            manifest_state["mtime"] = mtime
            manifest_state["entries"] = read_manifest(model_dir)
        entries = manifest_state["entries"]
        return sum(entries.values()) if entries else None

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

            _, actual, _ = get_dir_stats(model_dir)
            effective_total = manifest_total() or total_size_bytes
            current_time = time.time()
            elapsed = current_time - start_time

            delta_actual = actual - last_actual
            delta_time = current_time - last_time
            speed_mbps = (delta_actual / (1024 * 1024)) / delta_time if delta_time > 0 else 0

            delta_from_baseline = actual - baseline_actual
            monitor_elapsed = current_time - baseline_time
            monitor_avg = (delta_from_baseline / (1024 * 1024)) / monitor_elapsed if monitor_elapsed > 0 else 0

            remaining_actual = max(effective_total - actual, 0)
            eta_seconds = remaining_actual / (speed_mbps * 1024 * 1024) if speed_mbps > 0 else 0

            line = render_status(elapsed, actual, effective_total,
                                 speed_mbps, monitor_avg, eta_seconds)

            if tty:
                sys.stdout.write("\033[2K\r" + line)
            else:
                sys.stdout.write(line + "\n")
            sys.stdout.flush()

            last_actual = actual
            last_time = current_time

    except KeyboardInterrupt:
        pass
    finally:
        if tty:
            sys.stdout.write("\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
