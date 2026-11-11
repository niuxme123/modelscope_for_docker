FROM swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/python:3.11-slim-bullseye

# 镜像版本号（由 build.sh 通过 --build-arg VERSION=x.y 传入；容器启动/--help 都会显示）
ARG VERSION=dev

LABEL maintainer="niuxme123" \
      description="ModelScope model downloader (hubdl + aria2) with live progress monitor" \
      version="${VERSION}"

# ---- 国内镜像源（可用 --build-arg 覆盖） ----
ARG APT_MIRROR=mirrors.aliyun.com
# bullseye 已进入 LTS，国内镜像的 bullseye-security 池子同步不全（会 404），
# 默认不启用；需要时明确传入，例如 --build-arg APT_SECURITY_MIRROR=deb.freexian.com/lts/debian
ARG APT_SECURITY_MIRROR=
ARG PIP_INDEX=https://mirrors.aliyun.com/pypi/simple/

ENV PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_INDEX_URL=${PIP_INDEX} \
    IMAGE_VERSION=${VERSION} \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# 重写 Debian 源为国内镜像，加速 apt
RUN set -eux; \
    if [ -n "${APT_MIRROR}" ]; then \
        DEB_BASE="http://${APT_MIRROR}/debian"; \
    else \
        DEB_BASE="http://deb.debian.org/debian"; \
    fi; \
    rm -f /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; \
    : > /etc/apt/sources.list; \
    echo "deb ${DEB_BASE} bullseye main" >> /etc/apt/sources.list; \
    echo "deb ${DEB_BASE} bullseye-updates main" >> /etc/apt/sources.list; \
    if [ -n "${APT_SECURITY_MIRROR}" ]; then \
        echo "deb http://${APT_SECURITY_MIRROR}/ bullseye-security main" >> /etc/apt/sources.list; \
    elif [ -z "${APT_MIRROR}" ]; then \
        echo "deb http://security.debian.org/debian-security bullseye-security main" >> /etc/apt/sources.list; \
    fi; \
    cat /etc/apt/sources.list

RUN apt-get -o Acquire::Retries=5 update && apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
        aria2 \
        ca-certificates \
        curl \
        procps \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir -U pip && \
    pip install --no-cache-dir hubdl && \
    hubdl --version

COPY download-info.py /opt/download-info.py
COPY hubdl-size.py    /opt/hubdl-size.py
COPY entrypoint.sh   /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /data
VOLUME ["/data"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
