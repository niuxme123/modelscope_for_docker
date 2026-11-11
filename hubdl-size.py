#!/usr/bin/env python3
"""
按 hubdl 的文件清单估算仓库总大小（用于进度百分比/ETA），无需手工传 TOTAL_SIZE。

用法:
    python3 hubdl-size.py <repo_id> [选项]
    python3 hubdl-size.py --repo-id <repo_id> [选项]

选项:
    --hub {ms,hf}        默认 ms
    --local-dir DIR      容器内目录（参与路径安全校验，默认 /data）
    --dataset            数据集仓库
    --revision REV       分支/版本
    --include PATTERN    包含通配（可多次）
    --exclude PATTERN    排除通配（可多次）
    --endpoint URL       覆盖 API 端点（默认回落 MODELSCOPE_ENDPOINT / HF_ENDPOINT）
    --token TOKEN        访问令牌（默认回落 MODELSCOPE_API_TOKEN / HF_TOKEN）
    --bytes              输出字节数（默认输出人类可读大小，如 55.60GB）

stdout 只输出大小字符串；诊断信息走 stderr。
"""

import contextlib
import io
import os
import sys
from pathlib import Path


def _is_flag(token: str, name: str) -> bool:
    return token == name or token.startswith(name + "=")


def scan_args(argv):
    """手工扫描参数：忽略所有不认识的 hubdl 参数（--dry-run / -x / -j 等）。"""
    opts = {
        "repo_id": "",
        "hub": "ms",
        "local_dir": "/data",
        "dataset": False,
        "revision": "",
        "endpoint": "",
        "token": "",
        "include": [],
        "exclude": [],
        "bytes": False,
    }
    # 需要取值的选项
    value_flags = {
        "--repo-id": "repo_id",
        "--hub": "hub",
        "--local-dir": "local_dir",
        "--revision": "revision",
        "--endpoint": "endpoint",
        "--token": "token",
    }
    list_flags = {"--include": "include", "--exclude": "exclude"}

    i = 0
    n = len(argv)
    while i < n:
        token = argv[i]
        matched = False

        for flag, key in value_flags.items():
            if _is_flag(token, flag):
                if "=" in token:
                    opts[key] = token.split("=", 1)[1]
                else:
                    i += 1
                    if i < n:
                        opts[key] = argv[i]
                matched = True
                break
        if matched:
            i += 1
            continue

        for flag, key in list_flags.items():
            if _is_flag(token, flag):
                if "=" in token:
                    opts[key].append(token.split("=", 1)[1])
                else:
                    i += 1
                    if i < n:
                        opts[key].append(argv[i])
                matched = True
                break
        if matched:
            i += 1
            continue

        if _is_flag(token, "--dataset"):
            opts["dataset"] = True
        elif _is_flag(token, "--bytes"):
            opts["bytes"] = True
        elif not token.startswith("-") and not opts["repo_id"]:
            opts["repo_id"] = token
        i += 1

    return opts


def format_bytes(size: float) -> str:
    for unit in ["B", "KB", "MB", "GB", "TB", "PB"]:
        if size < 1024.0:
            return f"{size:.2f}{unit}"
        size /= 1024.0
    return f"{size:.2f}EB"


def main() -> int:
    opts = scan_args(sys.argv[1:])
    repo_id = opts["repo_id"]
    if not repo_id:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    hub = opts["hub"].lower()
    if hub in ("modelscope", "msd"):
        hub = "ms"
    elif hub in ("huggingface", "hfdx"):
        hub = "hf"

    endpoint = opts["endpoint"]
    token = opts["token"]
    if not endpoint:
        endpoint = os.environ.get(
            "MODELSCOPE_ENDPOINT" if hub == "ms" else "HF_ENDPOINT", ""
        )
    if not token:
        token = os.environ.get(
            "MODELSCOPE_API_TOKEN" if hub == "ms" else "HF_TOKEN", ""
        ) or os.environ.get("MODELSCOPE_TOKEN", "")

    try:
        from hubdl.core.config import RunConfig
        from hubdl.core.httputil import HttpClient
        from hubdl.hubs import get_hub
    except Exception as exc:  # pragma: no cover
        print(f"[size] 无法导入 hubdl: {exc}", file=sys.stderr)
        return 1

    cfg = RunConfig(
        hub=hub,
        repo_id=repo_id,
        local_dir=Path(opts["local_dir"]),
        revision=opts["revision"],
        dataset=opts["dataset"],
        token=token,
        endpoint=endpoint,
        include=opts["include"],
        exclude=opts["exclude"],
    )
    cfg.finalize()

    try:
        hub_obj = get_hub(cfg.hub)
        hub_obj.validate_repo_id(cfg.repo_id)
        http = HttpClient(
            cfg.endpoint,
            token=cfg.token,
            allow_http=cfg.allow_http,
            proxy=cfg.proxy,
        )
        # hubdl 列清单时会往 stdout 打分页信息，这里屏蔽掉，保持 stdout 干净
        sink = io.StringIO()
        with contextlib.redirect_stdout(sink):
            rows, _meta = hub_obj.fetch_file_rows(cfg, http)
    except Exception as exc:
        print(f"[size] 获取文件清单失败: {exc}", file=sys.stderr)
        return 1

    total = sum(int(r[0] or 0) for r in rows)
    if total <= 0:
        print("[size] 清单里没有可下载文件，无法计算总大小", file=sys.stderr)
        return 1

    pages = [ln for ln in sink.getvalue().splitlines() if ln.strip()]
    if pages:
        print(f"[size] 分页: {' / '.join(p.strip() for p in pages)}", file=sys.stderr)

    print(
        f"[size] 仓库: {repo_id}  文件数: {len(rows)}  总大小: {format_bytes(total)}",
        file=sys.stderr,
    )

    if opts["bytes"]:
        print(total)
    else:
        print(format_bytes(total))
    return 0


if __name__ == "__main__":
    sys.exit(main())
