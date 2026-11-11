#!/usr/bin/env bash
set -euo pipefail

print_help() {
    cat <<'EOF'
用法:
  docker run ... <IMAGE> [MODEL] [LOCAL_DIR] [RATE] [X] [J] [TOTAL_SIZE]

位置参数（按顺序，均可省略，省略则回落到对应环境变量/默认值）:
  MODEL       模型 ID           (env: MODEL,        默认: moonshotai/Kimi-K3.1-Pro)
  LOCAL_DIR   容器内下载目录    (env: LOCAL_DIR,    默认: /data)
  RATE        限速 Mbps         (env: RATE,         默认: 400)
  X           每文件连接数      (env: X,            默认: 16)
  J           并行文件数        (env: J,            默认: 4)
  TOTAL_SIZE  预计总大小(算进度)(env: TOTAL_SIZE,   默认: 1.56T)

可选环境变量:
  SAMPLE_INTERVAL       监控采样间隔秒数            (默认: 10)
  MODELSCOPE_ENDPOINT   ModelScope 端点地址
  MODELSCOPE_API_TOKEN  私有/受限模型令牌
  EXTRA_ARGS            透传给 hubdl 的额外参数 (空格分隔, 如 "--exclude '*.gguf'")

示例:
  docker run -d --name hubdl-dl \
    -v /mnt/disk0/models/Kimi-K3.1-Pro:/data \
    hubdl-downloader:latest \
    moonshotai/Kimi-K3.1-Pro /data 400 16 4 1.56T
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
TOTAL_SIZE="${6:-${TOTAL_SIZE:-1.56T}}"

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

if [[ -n "${MODELSCOPE_ENDPOINT:-}" ]]; then
    export MODELSCOPE_ENDPOINT
    echo "[entrypoint] MODELSCOPE_ENDPOINT=$MODELSCOPE_ENDPOINT"
fi

echo "[entrypoint] 模型:        $MODEL"
echo "[entrypoint] 保存目录:    $LOCAL_DIR"
echo "[entrypoint] 限速:        ${RATE} Mbps"
echo "[entrypoint] 每文件连接:  $X"
echo "[entrypoint] 并行文件数:  $J"
echo "[entrypoint] 预计总大小:  $TOTAL_SIZE"
echo "[entrypoint] 采样间隔:    ${SAMPLE_INTERVAL}s"
[[ -n "$EXTRA_ARGS" ]] && echo "[entrypoint] 额外参数:    $EXTRA_ARGS"
echo "[entrypoint] 开始下载..."
echo "------------------------------------------------------------"

# ---- 启动 hubdl（后台；原始输出写文件，避免污染监控行） ----
hubdl ms "$MODEL" \
    --local-dir "$LOCAL_DIR" \
    --rate-mbps "$RATE" \
    -x "$X" \
    -j "$J" \
    "${EXTRA_ARRAY[@]}" \
    >> "$LOG_FILE" 2>&1 &
DOWNLOAD_PID=$!

# ---- 启动监控 ----
python3 /opt/download-info.py "$LOCAL_DIR" "$TOTAL_SIZE" &
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
    echo "[entrypoint] ✅ 下载完成。最终汇总："
    python3 /opt/download-info.py --once "$LOCAL_DIR" "$TOTAL_SIZE" || true
else
    echo
    echo "[entrypoint] ❌ 下载进程退出，返回码=$RC。最近 80 行日志："
    tail -n 80 "$LOG_FILE" || true
fi

exit "$RC"
