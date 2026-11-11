#!/bin/bash
set -e

NAME=hubdl-dl
VERSION="${1:-1.0}"
REGISTRY=harbor-contest.4pd.io/wangyidong/devops
# 只构建 x64（amd64）架构
PLATFORM=linux/amd64

echo "==> 构建 ${NAME}:${VERSION}  (platform=${PLATFORM})"
docker build --platform "${PLATFORM}" -t "${NAME}:${VERSION}" .

docker tag "${NAME}:${VERSION}" "${REGISTRY}/${NAME}:latest"

echo "==> 构建完成，镜像列表："
docker images | grep -E "REPOSITORY|${NAME}" || true

# 需要推送到镜像仓库时： ./build.sh ${VERSION} --push
if [[ "${2:-}" == "--push" ]]; then
    echo "==> 推送 ${REGISTRY}/${NAME} :latest"
    docker push "${REGISTRY}/${NAME}:latest"
    echo "==> 推送完成"
fi
