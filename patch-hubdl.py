#!/usr/bin/env python3
"""
给镜像里的 hubdl 打补丁：修复 scrub_orphan_aria2 误删 .aria2 控制文件导致无法断点续传的问题。

背景：
  aria2 -xN 多连接按偏移写入，文件 st_size 在下载一开始就达到全量，
  真实数据却只写了一部分（续传位图保存在 <file>.aria2 控制文件里）。
  hubdl 0.1.2 的 scrub_orphan_aria2 只用 st_size == expected 判断"控制文件是孤儿"，
  会把仍在下载的文件的控制文件删掉，断点续传随即失效，L3 哈希校验不过后全量重下。

补丁：
  删除控制文件前，额外校验真实落盘块数 st_blocks*512 >= size；
  落盘不足的文件视为仍在下载，保留控制文件交给 aria2 --continue。
  说明：st_blocks 在 ext4/xfs 上可信；size==0 的空文件沿用原逻辑（直接按 size 对齐放行）。

用法（Dockerfile 内）：
  COPY patch-hubdl.py /tmp/patch-hubdl.py
  RUN python3 /tmp/patch-hubdl.py && rm /tmp/patch-hubdl.py
"""

import sys
from pathlib import Path


def apply_patch(src: str, marker: str, desc: str, anchor: str, extra: str) -> str:
    """在 anchor 之后插入额外行；已打过则原样返回。锚点缺失时报错（build 应当失败）。"""
    if marker in src:
        print(f"[patch] {desc}: 已存在，跳过")
        return src
    if anchor not in src:
        print(f"[patch] {desc}: 未找到锚点，hubdl 版本可能已变更，请人工核对")
        raise SystemExit(1)
    print(f"[patch] {desc}: 已打补丁")
    return src.replace(anchor, anchor + extra, 1)


def main() -> int:
    target = Path(
        "/usr/local/lib/python3.11/site-packages/hubdl/core/download.py"
    )
    if not target.is_file():
        hits = sorted(
            Path("/usr/local/lib").glob("python*/site-packages/hubdl/core/download.py")
        )
        if len(hits) == 1:
            target = hits[0]
        else:
            print(f"[patch] 找不到 hubdl/core/download.py（glob 命中 {len(hits)} 个）")
            return 1

    src = target.read_text(encoding="utf-8")

    # 补丁 1: scrub_orphan_aria2 删 .aria2 控制文件前校验真实落盘块数
    src = apply_patch(
        src,
        marker="PATCH(hubdl-dl): aria2 多连接偏移写",
        desc="scrub_orphan_aria2 续传修复",
        anchor=(
            "        # size-aligned (including empty file expected==0)\n"
            '        if st["size"] != size:\n'
            "            continue\n"
        ),
        extra=(
            "\n"
            "        # PATCH(hubdl-dl): aria2 多连接偏移写会让 st_size 瞬间达到全量，\n"
            "        # 真实落盘块数不足时删掉 .aria2 会丢续传位图 → 断点后全量重下。\n"
            "        # 落盘块数 < size 的视为仍在下载，保留控制文件交给 aria2 --continue。\n"
            "        try:\n"
            "            if size > 0 and dest.stat().st_blocks * 512 < size:\n"
            "                continue\n"
            "        except OSError:\n"
            "            continue\n"
        ),
    )

    # 补丁 2: aria2 长尾自愈：无数据 30s 或单连接低于 512KB/s 就掐掉重试，
    # 避免 -xN 收尾时个别分段被镜像站挂起导致的「卡在 99%」。
    src = apply_patch(
        src,
        marker="PATCH(hubdl-dl-aria2-timeout)",
        desc="aria2 长尾超时参数",
        anchor=(
            '        "--max-tries=5",\n'
            '        "--retry-wait=2",\n'
        ),
        extra=(
            '        "--timeout=30",            # PATCH(hubdl-dl-aria2-timeout): 单连接无数据 30s 断开重试\n'
            '        "--connect-timeout=15",    # PATCH(hubdl-dl-aria2-timeout): 建联 15s 超时\n'
            '        "--lowest-speed-limit=512K",  # PATCH(hubdl-dl-aria2-timeout): 单连接持续低于 512KB/s 重试\n'
        ),
    )

    target.write_text(src, encoding="utf-8")
    print(f"[patch] 完成: {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
