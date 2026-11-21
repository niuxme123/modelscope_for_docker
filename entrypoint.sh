#!/usr/bin/env bash
set -euo pipefail

IMAGE_VERSION="${IMAGE_VERSION:-dev}"

print_help() {
    cat <<EOF
hubdl-dl ${IMAGE_VERSION}  —  ModelScope / HuggingFace 模型下载器（hubdl + aria2，带实时进度监控）

用法:
  docker run ... <IMAGE> [MODEL] [LOCAL_DIR] [RATE] [X] [J] [TOTAL_SIZE]

位置参数（按顺序，均可省略，省略则回落到对应环境变量/默认值）:
  MODEL       模型 ID           (env: MODEL,        默认: moonshotai/Kimi-K3.1-Pro)
              支持直接粘贴网页 URL，如:
                https://hf-mirror.com/chatrlabs/Qwen-Image-2.1-Uncensored-Omni-Quantized
                https://huggingface.co/Qwen/Qwen3-0.6B/tree/main
                https://modelscope.cn/models/Qwen/Qwen3-0.6B
  LOCAL_DIR   容器内下载目录    (env: LOCAL_DIR,    默认: /data)
  RATE        限速 Mbps         (env: RATE,         默认: 400)
  X           每文件连接数      (env: X,            默认: 16)
  J           并行文件数        (env: J,            默认: 4)
  TOTAL_SIZE  预计总大小(算进度)(env: TOTAL_SIZE,   默认: 自动按文件清单计算)

可选环境变量:
  HUB                   下载源: ms / hf           (默认: ms；粘贴 hf 网页 URL 时自动切到 hf)
  HF_ENDPOINT           HuggingFace 端点          (HUB=hf 时默认: https://hf-mirror.com)
  HF_TOKEN              HuggingFace 访问令牌（私有/受限仓库）
  HOST_DIR              宿主机上的目录（用于展示，不传则自动探测）
  SAMPLE_INTERVAL       监控采样间隔秒数            (默认: 10)
  MODELSCOPE_ENDPOINT   ModelScope 端点地址
  MODELSCOPE_API_TOKEN  私有/受限模型令牌
  EXTRA_ARGS            透传给 hubdl 的额外参数 (空格分隔, 如 "--exclude '*.gguf'")
                        只下子目录/单文件: "--include '子目录/*'" 或 "--include '路径/文件.bin'"

示例（TOTAL_SIZE 可省略，会自动算）:
  docker run -d --name hubdl-dl \\
    -v /mnt/disk0/models/Kimi-K3.1-Pro:/data \\
    hubdl-dl:${IMAGE_VERSION} \\
    moonshotai/Kimi-K3.1-Pro /data 400 16 4

  # HuggingFace（默认走 hf-mirror.com 镜像，MODEL 也能直接贴网页 URL）
  docker run -d --name hubdl-dl \
    -v /mnt/disk0/models/Qwen-Image-2.1:/data \
    hubdl-dl:${IMAGE_VERSION} \
    https://hf-mirror.com/chatrlabs/Qwen-Image-2.1-Uncensored-Omni-Quantized /data 400 16 4
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    print_help
    exit 0
fi

# ---- 参数解析：位置参数 > 环境变量 > 默认值 ----
MODEL="${1:-${MODEL:-moonshotai/Kimi-K3.1-Pro}}"
LOCAL_DIR="${2:-${LOCAL_DIR:-/data}}"
RATE="${3:-${RATE:-400}}"
X="${4:-${X:-16}}"
J="${5:-${J:-4}}"
TOTAL_SIZE="${6:-${TOTAL_SIZE:-}}"   # 留空 = 自动按 hubdl 文件清单算

SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-10}"
export SAMPLE_INTERVAL

EXTRA_ARGS="${EXTRA_ARGS:-}"
EXTRA_ARRAY=()
if [[ -n "$EXTRA_ARGS" ]]; then
    # 有意分词：EXTRA_ARGS 通常是 "--flag value" 形式，随后逐项去掉外层引号
    read -r -a EXTRA_ARRAY <<< "$EXTRA_ARGS"
    for i in "${!EXTRA_ARRAY[@]}"; do
        t="${EXTRA_ARRAY[$i]}"
        t="${t%\"}"; t="${t#\"}"; t="${t%\'}"; t="${t#\'}"
        EXTRA_ARRAY[$i]="$t"
    done
fi

# ---- HUB：ms / hf（粘贴 hf 网页 URL 时会自动切换） ----
HUB_EXPLICIT=0
if [[ -n "${HUB:-}" ]]; then
    HUB_EXPLICIT=1
    HUB="${HUB,,}"
else
    HUB="ms"
fi
case "$HUB" in
    ms|modelscope)  HUB="ms" ;;
    hf|huggingface) HUB="hf" ;;
    *) echo "错误: HUB 必须是 ms 或 hf，当前: $HUB"; exit 2 ;;
esac

# ---- MODEL 支持直接粘贴网页 URL，自动推导 HUB / repo_id ----
if [[ "$MODEL" =~ ^https?://([^/]+)/(.+)$ ]]; then
    url_host="${BASH_REMATCH[1]}"
    url_path="${BASH_REMATCH[2]}"
    case "$url_host" in
        hf-mirror.com|www.hf-mirror.com|huggingface.co|www.huggingface.co)
            [[ "$HUB_EXPLICIT" -eq 0 ]] && HUB="hf"
            if [[ "$url_host" == *hf-mirror.com && -z "${HF_ENDPOINT:-}" ]]; then
                HF_ENDPOINT="https://hf-mirror.com"
            fi
            ;;
        modelscope.cn|www.modelscope.cn)
            [[ "$HUB_EXPLICIT" -eq 0 ]] && HUB="ms"
            # https://modelscope.cn/models/<ns>/<name> -> <ns>/<name>
            url_path="${url_path#models/}"
            ;;
        *)
            echo "错误: 无法识别的模型 URL 域名: $url_host"
            echo "      请直接传 repo_id（如 owner/name）"
            exit 2
            ;;
    esac
    # 去掉 /tree/<rev> /blob/<rev>/... 等网页后缀
    url_path="${url_path%%/tree/*}"
    url_path="${url_path%%/blob/*}"
    url_path="${url_path%/}"
    MODEL="$url_path"
fi

# ---- HF 端点：HUB=hf 时默认走 hf-mirror.com，可用 -e HF_ENDPOINT=... 覆盖 ----
if [[ "$HUB" == "hf" ]]; then
    HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
    export HF_ENDPOINT
fi

# ---- 基本校验 ----
[[ "$RATE" =~ ^[0-9]+$ ]]            || { echo "错误: RATE 必须是整数，当前: $RATE"; exit 2; }
[[ "$X"    =~ ^[0-9]+$ ]]            || { echo "错误: X 必须是整数，当前: $X"; exit 2; }
[[ "$J"    =~ ^[0-9]+$ ]]            || { echo "错误: J 必须是整数，当前: $J"; exit 2; }
[[ "$SAMPLE_INTERVAL" =~ ^[0-9]+$ ]] || { echo "错误: SAMPLE_INTERVAL 必须是整数，当前: $SAMPLE_INTERVAL"; exit 2; }

command -v hubdl >/dev/null 2>&1 || { echo "错误: 镜像内未找到 hubdl 命令"; exit 2; }

mkdir -p "$LOCAL_DIR"
LOG_FILE=/var/log/hubdl.log
mkdir -p "$(dirname "$LOG_FILE")"
: > "$LOG_FILE"

# ---- 宿主目录：HOST_DIR 优先，否则尝试从 /proc/self/mountinfo 探测 bind mount 源路径 ----
detect_host_dir() {
    python3 - "$1" <<'PY'
import os, sys

target = os.path.realpath(sys.argv[1])
try:
    with open('/proc/self/mountinfo', 'r') as f:
        lines = f.readlines()
except OSError:
    print('')
    raise SystemExit(0)

best = ''
for line in lines:
    parts = line.split(' ')
    if len(parts) < 6:
        continue
    root = parts[3].replace('\\040', ' ')
    mountpoint = parts[4].replace('\\040', ' ')
    if mountpoint != target:
        continue
    # root 为 '/' 说明此处挂的本就是某个文件系统根，无法反推宿主路径
    if root in ('', '/'):
        continue
    best = root
    break

print(best)
PY
}

HOST_DIR="${HOST_DIR:-}"
HOST_DIR_SOURCE="HOST_DIR"
if [[ -z "$HOST_DIR" ]]; then
    HOST_DIR="$(detect_host_dir "$LOCAL_DIR" || true)"
    HOST_DIR_SOURCE="自动探测"
fi
[[ -n "$HOST_DIR" ]] && export HOST_DIR

TOTAL_SIZE_SOURCE="手动指定"

if [[ -n "${MODELSCOPE_ENDPOINT:-}" ]]; then
    export MODELSCOPE_ENDPOINT
fi

# ---- 总大小：没传就按 Hub 文件清单自动计算 ----
if [[ -z "$TOTAL_SIZE" ]]; then
    echo "[entrypoint] 未指定 TOTAL_SIZE，正在按文件清单自动计算..."
    if AUTO_SIZE="$(python3 /opt/hubdl-size.py --repo-id "$MODEL" --hub "$HUB" \
                        --local-dir "$LOCAL_DIR" "${EXTRA_ARRAY[@]}")"; then
        TOTAL_SIZE="$AUTO_SIZE"
        TOTAL_SIZE_SOURCE="自动计算"
    else
        TOTAL_SIZE=""
        TOTAL_SIZE_SOURCE="未知"
        echo "[entrypoint] ⚠ 自动计算失败，改为只显示已下载量与速度（不影响下载）"
    fi
fi

if [[ -n "${MODELSCOPE_ENDPOINT:-}" ]]; then
    echo "[entrypoint] MODELSCOPE_ENDPOINT=$MODELSCOPE_ENDPOINT"
fi

echo "[entrypoint] 镜像版本:    ${IMAGE_VERSION}"
echo "[entrypoint] Hub:         $HUB"
if [[ "$HUB" == "hf" ]]; then
    echo "[entrypoint] HF 端点:     $HF_ENDPOINT"
fi
echo "[entrypoint] 模型:        $MODEL"
echo "[entrypoint] 保存目录:    $LOCAL_DIR  (容器内路径)"
if [[ -n "$HOST_DIR" ]]; then
    echo "[entrypoint] 宿主目录:    $HOST_DIR  ($HOST_DIR_SOURCE)"
else
    echo "[entrypoint] 宿主目录:    未知，可用 -e HOST_DIR=/宿主机/目录 指定"
fi
echo "[entrypoint] 限速:        ${RATE} Mbps"
echo "[entrypoint] 每文件连接:  $X"
echo "[entrypoint] 并行文件数:  $J"
if [[ -n "$TOTAL_SIZE" ]]; then
    echo "[entrypoint] 预计总大小:  $TOTAL_SIZE  ($TOTAL_SIZE_SOURCE)"
else
    echo "[entrypoint] 预计总大小:  未知（只显示已下载量与速度）"
fi
echo "[entrypoint] 采样间隔:    ${SAMPLE_INTERVAL}s"
[[ -n "$EXTRA_ARGS" ]] && echo "[entrypoint] 额外参数:    $EXTRA_ARGS"
echo "[entrypoint] 开始下载..."
echo "------------------------------------------------------------"

# ---- 启动 hubdl（后台；原始输出写文件，避免污染监控行） ----
hubdl "$HUB" "$MODEL" \
    --local-dir "$LOCAL_DIR" \
    --rate-mbps "$RATE" \
    -x "$X" \
    -j "$J" \
    "${EXTRA_ARRAY[@]}" \
    >> "$LOG_FILE" 2>&1 &
DOWNLOAD_PID=$!

# ---- 启动监控 ----
MONITOR_ARGS=("$LOCAL_DIR")
[[ -n "$TOTAL_SIZE" ]] && MONITOR_ARGS+=("$TOTAL_SIZE")
python3 /opt/download-info.py "${MONITOR_ARGS[@]}" &
MONITOR_PID=$!

cleanup() {
    echo
    echo "[entrypoint] 收到停止信号，正在结束子进程..."
    kill -TERM "$MONITOR_PID" 2>/dev/null || true
    pkill -TERM -P "$DOWNLOAD_PID" 2>/dev/null || true
    kill -TERM "$DOWNLOAD_PID" 2>/dev/null || true
    wait "$MONITOR_PID" 2>/dev/null || true
    wait "$DOWNLOAD_PID" 2>/dev/null || true
    echo "[entrypoint] 已停止。数据在挂载目录中，下次启动可续传。"
    exit 143
}
trap cleanup SIGTERM SIGINT

RC=0
wait "$DOWNLOAD_PID" || RC=$?

kill -TERM "$MONITOR_PID" 2>/dev/null || true
wait "$MONITOR_PID" 2>/dev/null || true

if [[ $RC -eq 0 ]]; then
    echo
    echo "[entrypoint] ✅ 下载完成。最终："
    python3 /opt/download-info.py --done "${MONITOR_ARGS[@]}" || true
else
    echo
    echo "[entrypoint] ❌ 下载进程退出，返回码=$RC。最近 80 行日志："
    tail -n 80 "$LOG_FILE" || true
fi

exit "$RC"
