# Kimi-K3.1-Pro Docker 下载器

基于 [hubdl](https://pypi.org/project/hubdl/) + aria2 的 ModelScope 模型下载镜像。
内置与 `download-info.py` 等价的实时监控，`docker logs -f` 即可查看进度、速度和 ETA。

- 仓库：<https://github.com/niuxme123/modelscope_for_docker>
- 基础镜像：`swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/python:3.11-slim-bullseye`
- 构建架构：仅 `linux/amd64`（x64）
- 镜像命名：`hubdl-dl:<version>` + `hubdl-dl:latest`，并打 tag 到 `harbor-contest.4pd.io/wangyidong/devops/hubdl-dl:latest`
- 国内加速：apt 走 `mirrors.aliyun.com`，pip 走 `mirrors.aliyun.com/pypi/simple/`（均可用 `--build-arg` 覆盖）

---

## 1. 文件结构

```
.
├── Dockerfile
├── entrypoint.sh
├── download-info.py
├── hubdl-size.py
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
| `docker build --platform linux/amd64 -t hubdl-dl:<version> .` | 只构建 x64 |
| `docker tag ... hubdl-dl:latest` | 本地 latest |
| `docker tag ... harbor-contest.4pd.io/wangyidong/devops/hubdl-dl:latest` | 仓库 latest tag |

推送（可选）：

```bash
./build.sh 1.0 --push
```

版本号从命令行第一个参数读入，不传则默认 `1.0`；每次发版改版本号即可，`latest` 始终指向最后一次构建。

### 2.1 手动构建 / 换源

```bash
# 等价于 build.sh 的核心命令
docker build --platform linux/amd64 -t hubdl-dl:1.0 .

# 换用其他国内源（清华 pip + 清华 debian）
docker build --platform linux/amd64 \
  --build-arg APT_MIRROR=mirrors.tuna.tsinghua.edu.cn \
  --build-arg PIP_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple \
  -t hubdl-dl:1.0 .

# 完全用官方源（海外机器）
docker build --platform linux/amd64 \
  --build-arg APT_MIRROR= \
  --build-arg PIP_INDEX=https://pypi.org/simple \
  -t hubdl-dl:1.0 .
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
  -t hubdl-dl:1.0 .
```

---

## 3. 快速开始

### 3.1 后台运行（推荐）

```bash
docker run -d --name hubdl-dl \
  -v /mnt/disk0/models/Kimi-K3.1-Pro:/data \
  hubdl-dl:latest \
  moonshotai/Kimi-K3.1-Pro /data 400 16 4 1.56T
```

参数含义（按顺序，`TOTAL_SIZE` 可省略）：

| 位置 | 参数 | 含义 | 示例 |
|------|------|------|------|
| 1 | `MODEL` | ModelScope 模型 ID | `moonshotai/Kimi-K3.1-Pro` |
| 2 | `LOCAL_DIR` | **容器内**下载目录（需与 `-v` 挂载点一致） | `/data` |
| 3 | `RATE` | 限速，单位 Mbps | `400` |
| 4 | `X` | 每个文件的连接数（-x） | `16` |
| 5 | `J` | 同时下载的文件数（-j） | `4` |
| 6 | `TOTAL_SIZE` | 预计总大小 | **可省略**，默认自动按文件清单计算 |

```bash
# 不再需要传总大小
docker run -d --name hubdl-dl \
  -v /mnt/disk0/models/Kimi-K3.1-Pro:/data \
  hubdl-dl:latest \
  moonshotai/Kimi-K3.1-Pro /data 400 16 4
```

> 位置参数**均可省略**：省略的会回落到同名环境变量，再回落到默认值。
> 只传部分时按顺序从第 1 个开始对应。

可以额外告诉容器**宿主机上的真实路径**，这样 `docker logs` 里显示的是你看得懂的目录而不是容器的 `/data`：

```bash
docker run -d --name hubdl-dl \
  -v /mnt/disk0/models/Kimi-K3.1-Pro:/data \
  -e HOST_DIR=/mnt/disk0/models/Kimi-K3.1-Pro \
  hubdl-dl:latest \
  moonshotai/Kimi-K3.1-Pro /data 400 16 4
```

> 不传 `HOST_DIR` 时，entrypoint 会从 `/proc/self/mountinfo` 自动探测 bind mount 的源路径；
> 如果 `-v` 的源目录本身又是个独立挂载点（如 `/mnt/disk0`），探测结果可能只是相对路径，这时建议显式传 `HOST_DIR`。

### 3.2 查看进度

```bash
docker logs -f hubdl-dl
```

输出示例（每 `SAMPLE_INTERVAL` 秒一行，可向上回翻历史）：

```
[entrypoint] 模型:        moonshotai/Kimi-K3.1-Pro
[entrypoint] 保存目录:    /data  (容器内路径)
[entrypoint] 宿主目录:    /mnt/disk0/models/Kimi-K3.1-Pro  (HOST_DIR)
[entrypoint] 限速:        400 Mbps
[entrypoint] 每文件连接:  16
[entrypoint] 并行文件数:  4
[entrypoint] 未指定 TOTAL_SIZE，正在按文件清单自动计算...
[size] 分页: page 1: 28 (cum 28)
[size] 仓库: lightx2v/MiniMax-H3-Prompt-Rewriter-Qwen3.8-27B-Ref2VA  文件数: 28  总大小: 51.77GB
[entrypoint] 预计总大小:  51.77GB  (自动计算)
[entrypoint] 采样间隔:    5s
------------------------------------------------------------
监控目录: /mnt/disk0/models/lightx2v/MiniMax-H3-...-Ref2VA
容器内路径: /data
预计总大小: 51.77GB
采样窗口: 5s
输出模式: LOG(每次一行)
------------------------------------------------------------
已用:00:00:05 | 名义: 3.61%(1.87GB) | 真实: 3.62%(1.87GB) | 剩余:49.90GB | 窗口: 383.1MB/s | 监控均: 383.1MB/s | ETA:00:02:13
已用:00:00:10 | 名义: 7.23%(3.74GB) | 真实: 7.24%(3.75GB) | 剩余:48.02GB | 窗口: 381.5MB/s | 监控均: 382.3MB/s | ETA:00:02:09
...
[entrypoint] ✅ 下载完成。最终汇总：
已用:00:00:00 | 名义:100.00%(51.77GB) | 真实:100.00%(51.77GB) | 剩余:0.00B | 窗口:  0.0MB/s | 监控均:  0.0MB/s | ETA:00:00:00
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
| TOTAL_SIZE | `TOTAL_SIZE` | **自动计算** | 留空时按 hubdl 文件清单累加得到；只影响百分比/ETA |

### 4.2 可选环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `HOST_DIR` | 自动探测 | 宿主机对应的下载目录，仅用于日志展示 |
| `TOTAL_SIZE` | 自动计算 | 手动指定总大小（如 `1.56T`），可覆盖自动计算 |
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
  # TOTAL_SIZE 不写就自动算
  -e SAMPLE_INTERVAL=5 \
  hubdl-dl:latest
```

> 混用时位置参数优先。推荐二选一，避免混淆。

### 4.4 总大小（TOTAL_SIZE）现在是可选的

不传 `TOTAL_SIZE` 时，entrypoint 会在启动下载前调用 `hubdl-size.py`：

1. 用 hubdl 自己的 ModelScope 列清单接口（`/api/v1/models/<repo>/repo/files`，分页 500/页）拉全量文件表；
2. 累加所有 blob 的 `Size` 字段；
3. 把结果传给监控脚本作为百分比/ETA 的分母。

```
[entrypoint] 未指定 TOTAL_SIZE，正在按文件清单自动计算...
[size] 分页: page 1: 28 (cum 28)
[size] 仓库: lightx2v/MiniMax-H3-Prompt-Rewriter-Qwen3.8-27B-Ref2VA  文件数: 28  总大小: 51.77GB
[entrypoint] 预计总大小:  51.77GB  (自动计算)
```

细节：

- **会跟随 `EXTRA_ARGS` 里的过滤条件**：`--include` / `--exclude` / `--dataset` / `--revision` 都会传给计算脚本，所以只下子集时百分比也准。
- **自动计算失败不影响下载**：比如私有仓库没 token、端点不通、API 变更。此时日志会提示
  `⚠ 自动计算失败，改为只显示已下载量与速度`，监控行变成
  `已用:... | 已下载:1.87GB(名义1.87GB) | 窗口: 383.1MB/s | 监控均: 383.1MB/s`（没有百分比和 ETA）。
- **仍可手动覆盖**：第 6 个位置参数或 `-e TOTAL_SIZE=1.56T` 一旦给出，就不再自动计算。
- 计算只读 API，不会产生下载流量；大仓库（几万文件）也就几秒。

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

### 5.3 让日志显示宿主机目录（而不是 /data）

`docker logs` 只能看到容器内路径。想让监控头行显示宿主机真实目录，传 `HOST_DIR` 即可：

```bash
docker run -d --name hubdl-dl \
  -v /mnt/disk0/models/lightx2v/MiniMax-H3-Prompt-Rewriter-Qwen3.8-27B-Ref2VA:/data \
  -e HOST_DIR=/mnt/disk0/models/lightx2v/MiniMax-H3-Prompt-Rewriter-Qwen3.8-27B-Ref2VA \
  hubdl-dl:latest \
  lightx2v/MiniMax-H3-Prompt-Rewriter-Qwen3.8-27B-Ref2VA /data 400 16 4 55.6G
```

输出会变成：

```
[entrypoint] 保存目录:    /data  (容器内路径)
[entrypoint] 宿主目录:    /mnt/disk0/models/lightx2v/MiniMax-H3-...  (HOST_DIR)
...
监控目录: /mnt/disk0/models/lightx2v/MiniMax-H3-...
容器内路径: /data
```

不传 `HOST_DIR` 时会自动探测（显示为 `(自动探测)`），探测结果为空则提示 `未知，可用 -e HOST_DIR=... 指定`。

### 5.4 修改 ModelScope 端点

```bash
docker run -d --name hubdl-dl \
  -v /mnt/disk0/models/Kimi-K3.1-Pro:/data \
  -e MODELSCOPE_ENDPOINT=https://your.endpoint.example.com \
  hubdl-dl:latest \
  moonshotai/Kimi-K3.1-Pro /data 400 16 4 1.56T
```

### 5.5 调整采样间隔（更快刷新进度）

```bash
docker run -d --name hubdl-dl \
  -v /mnt/disk0/models/Kimi-K3.1-Pro:/data \
  -e SAMPLE_INTERVAL=5 \
  hubdl-dl:latest \
  moonshotai/Kimi-K3.1-Pro /data 400 16 4 1.56T
```

### 5.6 透传额外参数给 hubdl

```bash
docker run -d --name hubdl-dl \
  -v /mnt/disk0/models/Kimi-K3.1-Pro:/data \
  -e EXTRA_ARGS="--exclude '*.gguf'" \
  hubdl-dl:latest \
  moonshotai/Kimi-K3.1-Pro /data 400 16 4 1.56T
```

> `EXTRA_ARGS` 按空格分词，参数值含空格时用单/双引号包住即可（entrypoint 会自动剥掉外层引号）。

### 5.7 查看帮助

```bash
docker run --rm hubdl-dl:latest --help
```

### 5.8 前台运行（单行刷新模式）

```bash
docker run -it --rm -v /mnt/disk0/models/Kimi-K3.1-Pro:/data \
  hubdl-dl:latest moonshotai/Kimi-K3.1-Pro /data 400 16 4 1.56T
```

`-it` 时 stdout 是 TTY，监控切换到 `\r` 单行刷新，不会刷屏。

---

## 6. 换别的模型

只改模型 ID 和挂载目录即可，总大小会自动算：

```bash
docker run -d --name hubdl-dl \
  -v /mnt/disk0/models/Qwen3-235B:/data \
  hubdl-dl:latest \
  Qwen/Qwen3-235B-A22B /data 400 16 4
```

手动指定总大小也仍然支持（第 6 个参数或 `-e TOTAL_SIZE=`），只是没必要：
写小了会显示 >100%，写大了会显示不到 100%，都不影响实际下载。

---

## 7. 排错
| 现象 | 排查 |
|------|------|
| `docker logs` 没有进度行 | 容器可能已退出：`docker ps -a` 看状态；`docker logs hubdl-dl \| tail` 看末尾错误 |
| 下载一开始就退出 | `docker logs hubdl-dl` 最后 80 行是 hubdl 原始日志，会指出原因（模型 ID 错、端点不通等） |
| 速度上不去 | 加大 `X`（如 32）或 `J`（如 8），或确认没有其他程序占带宽 |
| 进度百分比不动 | 确认 `-v` 宿主机目录与 `LOCAL_DIR` 指向一致 |
| 总大小显示「未知」 | 自动计算失败（看 `[size]` 开头的报错）；可手动 `-e TOTAL_SIZE=55.6G` |
| 百分比超过 100% | 手动传的 `TOTAL_SIZE` 比实际小，去掉该参数让它自动算即可 |
| 想确认容器内文件 | `docker exec -it hubdl-dl ls -lh /data \| head` |
| 想看 hubdl 原始输出 | `docker exec -it hubdl-dl tail -f /var/log/hubdl.log` |
| 想重启下载（不续传） | `docker rm -f hubdl-dl` 后删除宿主机目标目录内文件，再 `docker run` |
| Apple Silicon 上构建慢 | 已固定 `--platform linux/amd64`，走 QEMU 模拟属正常 |

---

## 8. 已验证的行为

本仓库的镜像已在本地实测：

- `docker run --rm hubdl-dl:latest --help` → 正常打印帮助
- 非法 `RATE` → 退出码 2，提示 `错误: RATE 必须是整数`
- `EXTRA_ARGS="--dry-run"` → hubdl 只列清单，entrypoint 输出汇总并退出 0
- `EXTRA_ARGS="--include '*.json'"` → 只下小文件，进度行正常输出
- 完整小模型 `Qwen/Qwen2.5-0.5B-Instruct`（约 950MB）→ 下载完成、汇总行正常、文件落在挂载目录
- 不传 `TOTAL_SIZE` → 自动算出 `953.30MB`（11 个文件），与实际下载量一致
- `lightx2v/MiniMax-H3-Prompt-Rewriter-Qwen3.8-27B-Ref2VA` → 自动算出 `51.77GB`（28 个文件）
- `--include '*.json'` → 总大小随之变小（`9.36MB` / 6 个文件），百分比口径正确
- 仓库名写错 → 自动计算失败只告警，继续尝试下载，下载失败后打印 hubdl 日志尾部

---

## 9. 原理简述

- **hubdl + aria2**：hubdl 调用 aria2，`-x` 控制单文件分段连接数，`-j` 控制同时下载文件数，`--rate-mbps` 限制总速率。
- **监控与下载解耦**：entrypoint 启动 hubdl 时把它的 stdout/stderr 重定向到容器内 `/var/log/hubdl.log`，避免与进度行交错；同时后台跑 `download-info.py` 输出到 stdout，所以 `docker logs` 里看到的**只有干净的进度行**。下载失败时 entrypoint 会自动把日志末尾 80 行打到 `docker logs`。
- **总大小自动计算**：`hubdl-size.py` 复用 hubdl 的 ModelScope 列清单逻辑（`ModelScopeHub.fetch_file_rows`）累加文件大小，所以和 hubdl 真正要下的文件集合一致（含 revision/过滤条件）。
- **统计口径**：进度统计跳过了 hubdl 自己的缓存目录 `.hubdl`，只统计真实模型文件；“名义”是按文件逻辑大小（st_size），“真实”是按磁盘占用（st_blocks × 512，含稀疏/预分配文件）。
- **TTY 感知**：`docker run -d` 时 stdout 不是 TTY，脚本自动切到"每 N 秒一行"模式，进度不糊屏；`docker run -it` 前台跑时会切成单行刷新（`\r`）模式。
- **优雅退出**：`docker stop` 的 SIGTERM 会被 entrypoint 捕获，转发给所有子进程，hubdl/aria2 有时间收尾 `.part` 文件，重启后续传。
