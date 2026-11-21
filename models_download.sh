#!/usr/bin/env bash
# models_download.sh — hubdl-dl 一键下载包装脚本（ModelScope / HuggingFace 通用）
#
# 用法:
#   bash models_download.sh <MODEL_ID 或 网页URL> [BASE_DIR] [额外 hubdl 参数...]
#
# 示例:
#   # ModelScope，repo ID 形式（默认按 ModelScope 处理）
#   bash models_download.sh PhaiModelLab/Phai-A1-35B-1M
#
#   # HuggingFace，直接贴 hf-mirror 网页 URL，自动走镜像
#   bash models_download.sh https://hf-mirror.com/lightx2v/Minimax-h3-Turbo/tree/main
#
#   # URL 指向仓库里的某个子目录 → 只下载该子目录下的文件
#   bash models_download.sh https://hf-mirror.com/TenStrip/10Eros-Max/tree/main/Loras
#
#   # URL 指向单个文件（/blob/<分支>/<文件路径>）→ 只下载这个文件
#   bash models_download.sh https://hf-mirror.com/owner/repo/blob/main/config.json
#
#   # 指定宿主机根目录 + 透传额外 hubdl 参数（--include/--exclude/--revision/--dry-run 等）
#   bash models_download.sh owner/repo /mnt/disk1/models --exclude '*.gguf'
#   bash models_download.sh https://hf-mirror.com/a/b/tree/main/sub --dry-run
#
# 不传 BASE_DIR 时使用脚本顶部 DEFAULT_BASE_DIR；
# 镜像地址 IMAGE 没有默认值，必须先在脚本顶部配置（或用 IMAGE=xxx 环境变量传入）。

set -euo pipefail

# ---------- 配置项（部署后请先修改这两行） ----------
IMAGE="${IMAGE:-}"                        # 必填：你的 hubdl-dl 镜像，如 registry.example.com/devops/hubdl-dl:latest
DEFAULT_BASE_DIR="${DEFAULT_BASE_DIR:-}"  # 宿主机模型根目录，如 /mnt/disk0/models（也可运行时传第 2 个参数）

# ---------- 可选调整（环境变量同名覆盖） ----------
CONTAINER_NAME="${CONTAINER_NAME:-hubdl-dl}"
RATE="${RATE:-400}"        # 限速 Mbps
X="${X:-16}"               # 每文件连接数
J="${J:-4}"                # 并行文件数
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-10}"
SKIP_PULL="${SKIP_PULL:-0}"  # =1 时跳过 docker pull

die() { echo "错误: $*" >&2; exit 1; }

# ---------- 使用前的必填校验 ----------
[[ -n "$IMAGE" ]] || die "未配置镜像地址。请编辑脚本顶部的 IMAGE 变量，或用 IMAGE=xxx bash $0 ... 传入。"

if [[ $# -lt 1 ]]; then
  cat >&2 <<EOF
Usage: bash $0 <MODEL_ID 或 网页URL> [BASE_DIR] [额外 hubdl 参数...]

  MODEL_ID   如 PhaiModelLab/Phai-A1-35B-1M（默认按 ModelScope；HUB=hf 时可当 HF repo 用）
  网页URL    支持 https://hf-mirror.com/... 、https://huggingface.co/... 、https://modelscope.cn/...
             /tree/<分支>/<子目录> → 只下该子目录；/blob/<分支>/<文件> → 只下该文件
  BASE_DIR   宿主机模型根目录，不传则用脚本顶部 DEFAULT_BASE_DIR
  额外参数   原样透传给 hubdl，如: --exclude '*.gguf'  --include '*.json'  --dry-run

示例:
  bash $0 https://hf-mirror.com/TenStrip/10Eros-Max/tree/main/Loras
  bash $0 owner/repo /mnt/disk0/models --exclude '*.gguf'
EOF
  exit 1
fi

MODEL_INPUT="$1"; shift
BASE_DIR="${1:-$DEFAULT_BASE_DIR}"
[[ $# -ge 1 ]] && shift
EXTRA=("$@")

[[ -n "$BASE_DIR" ]] || die "未配置下载根目录。请编辑脚本顶部的 DEFAULT_BASE_DIR，或运行时传第 2 个参数。"

# ---------- 解析 MODEL：repo ID 或网页 URL ----------
HUB="${HUB:-ms}"
HF_EP=""
REPO=""
SUBPATH=""   # /tree/<rev>/<subpath> 时非空
FILE_PATH="" # /blob/<rev>/<file> 时非空

if [[ "$MODEL_INPUT" =~ ^https?://([^/]+)/(.+)$ ]]; then
  url_host="${BASH_REMATCH[1]}"
  url_path="${BASH_REMATCH[2]}"

  case "$url_host" in
    hf-mirror.com|www.hf-mirror.com)
      HUB="hf"; HF_EP="https://hf-mirror.com" ;;
    huggingface.co|www.huggingface.co)
      HUB="hf"; HF_EP="https://huggingface.co" ;;
    modelscope.cn|www.modelscope.cn)
      HUB="ms"; url_path="${url_path#models/}" ;;
    *)
      die "无法识别的 URL 域名: $url_host（支持 hf-mirror.com / huggingface.co / modelscope.cn）" ;;
  esac

  # owner/repo + 可选的 /tree/<rev>[/<subpath>] 或 /blob/<rev>/<file>
  if [[ "$url_path" =~ ^([^/]+/[^/]+)/tree/[^/]+(/(.*))?/?$ ]]; then
    REPO="${BASH_REMATCH[1]}"
    SUBPATH="${BASH_REMATCH[3]}"
  elif [[ "$url_path" =~ ^([^/]+/[^/]+)/blob/[^/]+/(.+)$ ]]; then
    REPO="${BASH_REMATCH[1]}"
    FILE_PATH="${BASH_REMATCH[2]}"
  elif [[ "$url_path" =~ ^([^/]+/[^/]+)/?$ ]]; then
    REPO="${BASH_REMATCH[1]}"
  else
    die "无法从 URL 解析 repo: ${MODEL_INPUT}"
  fi
else
  REPO="$MODEL_INPUT"
fi

# ---------- 组装 hubdl 过滤参数：子目录 URL / 文件 URL 自动生成 --include ----------
INC_ARGS=()
if [[ -n "$SUBPATH" ]]; then
  SUBPATH="${SUBPATH%/}"
  INC_ARGS+=(--include "${SUBPATH}/*")
elif [[ -n "$FILE_PATH" ]]; then
  INC_ARGS+=(--include "$FILE_PATH")
fi

EXTRA_ARGS_STR=""
for a in ${INC_ARGS[@]+"${INC_ARGS[@]}"} ${EXTRA[@]+"${EXTRA[@]}"}; do
  # 用单引号包裹每项，保证 entrypoint 分词后拿到原始值（不支持含空格的路径）
  EXTRA_ARGS_STR+="'${a}' "
done
EXTRA_ARGS_STR="${EXTRA_ARGS_STR% }"

LOCAL_DIR="${BASE_DIR%/}/${REPO}"

# ---------- 汇总 ----------
echo "==> Hub:        ${HUB}"
[[ -n "$HF_EP" ]] && echo "==> HF 端点:    ${HF_EP}"
echo "==> Repo:       ${REPO}"
[[ -n "$SUBPATH" ]]   && echo "==> 子目录过滤: ${SUBPATH}/*"
[[ -n "$FILE_PATH" ]] && echo "==> 单文件过滤: ${FILE_PATH}"
((${#EXTRA[@]}))      && echo "==> 额外参数:   ${EXTRA[*]}"
echo "==> 下载目录:   ${LOCAL_DIR}"
echo "==> 镜像:       ${IMAGE}"

mkdir -p "${LOCAL_DIR}"

if [[ "$SKIP_PULL" != "1" ]]; then
  echo "==> Pulling image: ${IMAGE}"
  docker pull "${IMAGE}"
fi

# ---------- 启动下载 ----------
DOCKER_ARGS=(
  run --rm --name "${CONTAINER_NAME}"
  -v "${LOCAL_DIR}:/data"
  -e MODEL="${REPO}"
  -e LOCAL_DIR=/data
  -e HUB="${HUB}"
  -e HOST_DIR="${LOCAL_DIR}"
  -e RATE="${RATE}"
  -e X="${X}"
  -e J="${J}"
  -e SAMPLE_INTERVAL="${SAMPLE_INTERVAL}"
)
[[ -n "$HF_EP" ]] && DOCKER_ARGS+=(-e "HF_ENDPOINT=${HF_EP}")
[[ -n "$EXTRA_ARGS_STR" ]] && DOCKER_ARGS+=(-e "EXTRA_ARGS=${EXTRA_ARGS_STR}")

# 交互式终端下加 -it，触发单行刷新进度模式
[[ -t 0 && -t 1 ]] && DOCKER_ARGS+=(-it)

docker "${DOCKER_ARGS[@]}" "${IMAGE}"

echo "==> Done. Files at: ${LOCAL_DIR}"
