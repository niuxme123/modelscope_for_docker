# Kimi-K3.1-Pro Docker 下载器

基于 [hubdl](https://pypi.org/project/hubdl/) + aria2 的 ModelScope 模型下载镜像。
内置与 `download-info.py` 等价的实时监控，`docker logs -f` 即可查看进度、速度和 ETA。

- 仓库：<https://github.com/niuxme123/modelscope_for_docker>
- 基础镜像：`swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/python:3.11-slim-bullseye`
- 构建架构：仅 `linux/amd64`（x64）
- 镜像命名：`niuxme123/devops/hubdl-downloader:<version>` + `:latest`
- 国内加速：apt 走 `mirrors.aliyun.com`，pip 走 `mirrors.aliyun.com/pypi/simple/`（均可用 `--build-arg` 覆盖）

---

## 1. 文件结构

```
.
├── Dockerfile
├── entrypoint.sh
├── download-info.py
├── build.sh
└── README.md
```

---

## 2. 构建镜像

```bash
chmod +x build.sh
./build.sh 1.0
```

> 首次构建会拉取基础镜像并安装 aria2 / hubdl，耗时几分钟属正常。

`build.sh` 做的事：

| 步骤 | 说明 |
|------|------|
| `docker build --platform linux/amd64 -t hubdl-downloader:1.0 .` | 只构建 x64 |
| `docker tag ... hubdl-downloader:latest` | 本地 latest |
| `docker tag ... niuxme123/devops/hubdl-downloader:1.0` | 仓库版本 tag |
| `docker tag ... niuxme123/devops/hubdl-downloader:latest` | 仓库 latest tag |

推送（可选）：

```bash
./build.sh 1.0 --push
```

版本号从命令行第一个参数读入，不传则默认 `1.0`；每次发版改版本号即可，`latest` 始终指向最后一次构建。

### 2.1 手动构建 / 换源

```bash
# 等价于 build.sh 的核心命令
docker build --platform linux/amd64 -t hubdl-downloader:1.0 .

# 换用其他国内源（清华 pip + 清华 debian）
docker build --platform linux/amd64 \
  --build-arg APT_MIRROR=mirrors.tuna.tsinghua.edu.cn \
  --build-arg PIP_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple \
  -t hubdl-downloader:1.0 .

# 完全用官方源（海外机器）
docker build --platform linux/amd64 \
  --build-arg APT_MIRROR= \
  --build-arg PIP_INDEX=https://pypi.org/simple \
  -t hubdl-downloader:1.0 .
```

> 镜像内也持久化了 `PIP_INDEX_URL` 环境变量，容器里再 `pip install` 也会走国内源。
> 如果某次 hubdl 新版本装不上，可临时改成 `--build-arg PIP_INDEX=https://pypi.org/simple` 排查。

### 2.2 关于 apt 源

基础镜像 `python:3.11-slim-bullseye` 属于 Debian 11（已进入 LTS）。国内镜像站的 `bullseye-security` 池子同步不全，
直接启用会报 404（`E: Unable to fetch some archives`），所以默认**只用** `bullseye` + `bullseye-updates` 两个仓库（足够安装 aria2 / curl / procps）。

需要安全仓时可显式指定：

```bash
docker build --platform linux/amd64 \
  --build-arg APT_SECURITY_MIRROR=deb.freexian.com/lts/debian \
  -t hubdl-downloader:1.0 .
```

---

## 3. 快速开始

### 3.1 后台运行（推荐）

```bash
docker run -d --name hubdl-dl \
  -v /mnt/disk0/models/Kimi-K3.1-Pro:/data \
  hubdl-downloader:latest \
  moonshotai/Kimi-K3.1-Pro /data 400 16 4 1.56T
```

参数含义（按顺序）：

| 位置 | 参数 | 含义 | 示例 |
|------|------|------|------|
| 1 | `MODEL` | ModelScope 模型 ID | `moonshotai/Kimi-K3.1-Pro` |
| 2 | `LOCAL_DIR` | **容器内**下载目录（需与 `-v` 挂载点一致） | `/data` |
| 3 | `RATE` | 限速，单位 Mbps | `400` |
| 4 | `X` | 每个文件的连接数（-x） | `16` |
| 5 | `J` | 同时下载的文件数（-j） | `4` |
| 6 | `TOTAL_SIZE` | 预计总大小，仅用于算百分比/ETA | `1.56T` |

> 位置参数**均可省略**：省略的会回落到同名环境变量，再回落到默认值。
> 只传部分时按顺序从第 1 个开始对应。

### 3.2 查看进度

```bash
docker logs -f hubdl-dl
```

输出示例（每 `SAMPLE_INTERVAL` 秒一行，可向上回翻历史）：

```
[entrypoint] 模型:        moonshotai/Kimi-K3.1-Pro
[entrypoint] 保存目录:    /data
[entrypoint] 限速:        400 Mbps
[entrypoint] 每文件连接:  16
[entrypoint] 并行文件数:  4
[entrypoint] 预计总大小:  1.56T
[entrypoint] 采样间隔:    10s
------------------------------------------------------------
监控目录: /data
预计总大小: 1.56TB
采样窗口: 10s
输出模式: LOG(每次一行)
------------------------------------------------------------
已用:00:00:10 | 名义: 2.31%(36.02GB) | 真实: 2.31%(36.02GB) | 剩余:1.52TB | 窗口: 380.1MB/s | 监控均: 350.2MB/s | ETA:01:08:23
已用:00:00:20 | 名义: 4.62%(72.15GB) | 真实: 4.62%(72.15GB) | 剩余:1.49TB | 窗口: 395.2MB/s | 监控均: 372.3MB/s | ETA:01:05:11
...
[entrypoint] ✅ 下载完成。最终汇总：
已用:00:00:00 | 名义:100.00%(1.56TB) | 真实:100.00%(1.56TB) | 剩余:0.00B | 窗口:  0.0MB/s | 监控均:  0.0MB/s | ETA:00:00:00
```

加上 `--timestamps` 可以给每行带墙上时间戳：

```bash
docker logs -f --timestamps hubdl-dl
```

---

## 4. 完整参数说明

### 4.1 核心参数（位置参数 / 环境变量均可）

| 参数 | 环境变量 | 默认值 | 说明 |
|------|----------|--------|------|
| MODEL | `MODEL` | `moonshotai/Kimi-K3.1-Pro` | ModelScope 模型 ID |
| LOCAL_DIR | `LOCAL_DIR` | `/data` | 容器内下载目录 |
| RATE | `RATE` | `400` | 限速（Mbps），服务器带宽 500Mb 时建议 400 |
| X | `X` | `16` | 每文件连接数，速度上不去可加大 |
| J | `J` | `4` | 并行文件数 |
| TOTAL_SIZE | `TOTAL_SIZE` | `1.56T` | 只影响百分比/ETA，不影响实际下载 |

### 4.2 可选环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `SAMPLE_INTERVAL` | `10` | 监控采样间隔（秒） |
| `MODELSCOPE_ENDPOINT` | 空 | 自定义 ModelScope 端点 URL（hubdl 原生支持该变量） |
| `MODELSCOPE_API_TOKEN` | 空 | 私有/受限模型令牌（hubdl 原生支持） |
| `EXTRA_ARGS` | 空 | 透传给 hubdl 的额外参数（空格分隔） |

### 4.3 只用环境变量方式（等价写法）

```bash
docker run -d --name hubdl-dl \
  -v /mnt/disk0/models/Kimi-K3.1-Pro:/data \
  -e MODEL=moonshotai/Kimi-K3.1-Pro \
  -e LOCAL_DIR=/data \
  -e RATE=400 \
  -e X=16 \
  -e J=4 \
  -e TOTAL_SIZE=1.56T \
  -e SAMPLE_INTERVAL=5 \
  hubdl-downloader:latest
```

> 混用时位置参数优先。推荐二选一，避免混淆。

---

## 5. 常用操作

### 5.1 停止（优雅、可续传）

```bash
docker stop hubdl-dl
```

会给 entrypoint 发 SIGTERM，entrypoint 转发给 hubdl / aria2 / 监控脚本，`.part` 文件正常收尾。
**数据在宿主机挂载目录里，下次同名 `docker run` 会从断点续传。**

### 5.2 删除容器（数据不丢）

```bash
docker rm hubdl-dl
```

挂载目录里的文件保留，重新 `docker run` 即续传。

### 5.3 修改 ModelScope 端点

```bash
docker run -d --name hubdl-dl \
  -v /mnt/disk0/models/Kimi-K3.1-Pro:/data \
  -e MODELSCOPE_ENDPOINT=https://your.endpoint.example.com \
  hubdl-downloader:latest \
  moonshotai/Kimi-K3.1-Pro /data 400 16 4 1.56T
```

### 5.4 调整采样间隔（更快刷新进度）

```bash
docker run -d --name hubdl-dl \
  -v /mnt/disk0/models/Kimi-K3.1-Pro:/data \
  -e SAMPLE_INTERVAL=5 \
  hubdl-downloader:latest \
  moonshotai/Kimi-K3.1-Pro /data 400 16 4 1.56T
```

### 5.5 透传额外参数给 hubdl

```bash
docker run -d --name hubdl-dl \
  -v /mnt/disk0/models/Kimi-K3.1-Pro:/data \
  -e EXTRA_ARGS="--exclude '*.gguf'" \
  hubdl-downloader:latest \
  moonshotai/Kimi-K3.1-Pro /data 400 16 4 1.56T
```

> `EXTRA_ARGS` 按空格分词，参数值含空格时用单/双引号包住即可（entrypoint 会自动剥掉外层引号）。

### 5.6 查看帮助

```bash
docker run --rm hubdl-downloader:latest --help
```

### 5.7 前台运行（单行刷新模式）

```bash
docker run -it --rm -v /mnt/disk0/models/Kimi-K3.1-Pro:/data \
  hubdl-downloader:latest moonshotai/Kimi-K3.1-Pro /data 400 16 4 1.56T
```

`-it` 时 stdout 是 TTY，监控切换到 `\r` 单行刷新，不会刷屏。

---

## 6. 换别的模型

只需改前两个 + 第六个参数（TOTAL_SIZE），例如：

```bash
docker run -d --name hubdl-dl \
  -v /mnt/disk0/models/Qwen3-235B:/data \
  hubdl-downloader:latest \
  Qwen/Qwen3-235B-A22B /data 400 16 4 470G
```

> `TOTAL_SIZE` 只是进度分母，写小了会显示 >100%，写大了会显示不到 100%，都不影响实际下载。

---

## 7. 排错
| 现象 | 排查 |
|------|------|
| `docker logs` 没有进度行 | 容器可能已退出：`docker ps -a` 看状态；`docker logs hubdl-dl \| tail` 看末尾错误 |
| 下载一开始就退出 | `docker logs hubdl-dl` 最后 80 行是 hubdl 原始日志，会指出原因（模型 ID 错、端点不通等） |
| 速度上不去 | 加大 `X`（如 32）或 `J`（如 8），或确认没有其他程序占带宽 |
| 进度百分比不动 | 确认 `-v` 宿主机目录与 `LOCAL_DIR` 指向一致；`TOTAL_SIZE` 是否设得过大 |
| 想确认容器内文件 | `docker exec -it hubdl-dl ls -lh /data \| head` |
| 想看 hubdl 原始输出 | `docker exec -it hubdl-dl tail -f /var/log/hubdl.log` |
| 想重启下载（不续传） | `docker rm -f hubdl-dl` 后删除宿主机目标目录内文件，再 `docker run` |
| Apple Silicon 上构建慢 | 已固定 `--platform linux/amd64`，走 QEMU 模拟属正常 |

---

## 8. 已验证的行为

本仓库的镜像已在本地实测：

- `docker run --rm hubdl-downloader:latest --help` → 正常打印帮助
- 非法 `RATE` → 退出码 2，提示 `错误: RATE 必须是整数`
- `EXTRA_ARGS="--dry-run"` → hubdl 只列清单，entrypoint 输出汇总并退出 0
- `EXTRA_ARGS="--include '*.json'"` → 只下小文件，进度行正常输出
- 完整小模型 `Qwen/Qwen2.5-0.5B-Instruct`（约 950MB）→ 下载完成、汇总行正常、文件落在挂载目录

---

## 9. 原理简述

- **hubdl + aria2**：hubdl 调用 aria2，`-x` 控制单文件分段连接数，`-j` 控制同时下载文件数，`--rate-mbps` 限制总速率。
- **监控与下载解耦**：entrypoint 启动 hubdl 时把它的 stdout/stderr 重定向到容器内 `/var/log/hubdl.log`，避免与进度行交错；同时后台跑 `download-info.py` 输出到 stdout，所以 `docker logs` 里看到的**只有干净的进度行**。下载失败时 entrypoint 会自动把日志末尾 80 行打到 `docker logs`。
- **统计口径**：进度统计跳过了 hubdl 自己的缓存目录 `.hubdl`，只统计真实模型文件；“名义”是按文件逻辑大小（st_size），“真实”是按磁盘占用（st_blocks × 512，含稀疏/预分配文件）。
- **TTY 感知**：`docker run -d` 时 stdout 不是 TTY，脚本自动切到"每 N 秒一行"模式，进度不糊屏；`docker run -it` 前台跑时会切成单行刷新（`\r`）模式。
- **优雅退出**：`docker stop` 的 SIGTERM 会被 entrypoint 捕获，转发给所有子进程，hubdl/aria2 有时间收尾 `.part` 文件，重启后续传。
