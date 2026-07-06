# Cloudflare DDNS 一键安装脚本

基于 [favonia/cloudflare-ddns](https://github.com/favonia/cloudflare-ddns) 镜像的 Docker 一键部署脚本，适用于全新的 Debian / Ubuntu VPS。

只需一条命令，即可完成 Docker 安装、DDNS 容器配置与启动，全程无需手动干预，也无需在仓库中保存任何 API Token 等敏感信息。

## 使用方式

```bash
curl -fsSL https://raw.githubusercontent.com/kkkm0/ddns/main/ddns.sh | bash -s -- "你的Token" "你的域名" [ipv6]
```

例如：

```bash
# 默认：只管理 IPv4（推荐，适用于绝大多数只有 IPv4 的 VPS）
curl -fsSL https://raw.githubusercontent.com/kkkm0/ddns/main/ddns.sh | bash -s -- "cf_xxxxxxxxxxxxxxxxxxx" "ddns.example.com"

# 同时管理 IPv4 和 IPv6
curl -fsSL https://raw.githubusercontent.com/kkkm0/ddns/main/ddns.sh | bash -s -- "cf_xxxxxxxxxxxxxxxxxxx" "ddns.example.com" ipv6
```

参数说明：

| 参数序号 | 含义 | 是否必填 | 示例 |
| --- | --- | --- | --- |
| 1 | Cloudflare API Token | 必填 | `cf_xxxxxxxxxxxxxxxxxxx` |
| 2 | 需要更新的完整域名 | 必填 | `ddns.example.com` |
| 3 | 是否启用 IPv6 管理，传入 `ipv6` 表示启用 | 可选 | `ipv6` |

> ⚠️ 脚本需要以 **root** 身份运行（或通过 `sudo bash ddns.sh ...` 方式手动执行）。

### 关于 IPv6

绝大多数 VPS 只有 IPv4 地址。`favonia/cloudflare-ddns` 镜像默认会同时尝试探测 IPv4 和 IPv6，在纯 IPv4 环境下会持续输出类似下面的无意义日志：

```text
Failed to send HTTP(S) request to https://api.cloudflare.com/cdn-cgi/trace
No valid IPv6 addresses were detected
```

因此本脚本**默认关闭 IPv6 探测**（自动在 `.env` 中写入 `IP6_PROVIDER=none`），只专注管理 IPv4 记录，避免上述日志噪音。

如果你的 VPS 确实拥有 IPv6 地址，并且希望同时维护 IPv6 DNS 记录，只需在命令末尾追加 `ipv6` 参数即可启用。

## 功能特性

- ✅ 自动检测并安装最新版 Docker（若尚未安装）
- ✅ 自动启动 Docker 并设置开机自启
- ✅ 自动检测 Docker Compose Plugin（`docker compose`）
- ✅ 自动生成 `.env` 与 `docker-compose.yml` 配置文件
- ✅ 使用 `docker compose` 管理容器（而非裸 `docker run`）
- ✅ 自动拉取最新镜像并重建容器，开机自动运行
- ✅ 幂等设计：可重复执行，重复执行会覆盖旧配置并更新容器
- ✅ API Token 仅通过命令行参数传入，不写入 GitHub 仓库
- ✅ 清晰的彩色分级日志（`INFO` / `SUCCESS` / `WARNING` / `ERROR`）
- ✅ 遵循 ShellCheck 最佳实践，代码结构清晰、注释完整

## 支持系统

- Debian 11+
- Debian 12+
- Ubuntu 20.04+
- Ubuntu 22.04+
- Ubuntu 24.04+

## 安装目录与文件结构

脚本会将所有文件安装到统一目录：

```
/opt/cloudflare-ddns
├── .env
└── docker-compose.yml
```

`.env` 内容示例（由脚本自动生成，仅存在于目标服务器本地，不会上传到 GitHub）：

```env
CLOUDFLARE_API_TOKEN=<你的Token>
DOMAINS=<你的域名>
IP6_PROVIDER=none
```

> 说明：`IP6_PROVIDER=none` 仅在**未传入 `ipv6` 参数**时才会写入（默认关闭 IPv6 探测）。若执行时追加了 `ipv6` 参数，则不会写入该行，`favonia/cloudflare-ddns` 会同时管理 IPv4 与 IPv6。

`docker-compose.yml` 内容示例：

```yaml
services:
  cloudflare-ddns:
    image: favonia/cloudflare-ddns:1
    container_name: cloudflare-ddns
    network_mode: host
    restart: unless-stopped
    env_file:
      - .env
```

## 常用命令

安装完成后，可以进入安装目录执行以下常用命令：

```bash
cd /opt/cloudflare-ddns

# 查看实时日志
docker compose logs -f

# 重启容器
docker compose restart

# 停止并移除容器
docker compose down
```

## 更新配置 / Token

如果需要更换域名或 API Token，只需重新执行同一条安装命令，传入新的参数即可。脚本会自动覆盖旧的 `.env` 配置，并重建容器，无需手动清理。

```bash
curl -fsSL https://raw.githubusercontent.com/kkkm0/ddns/main/ddns.sh | bash -s -- "新的Token" "新的域名"
```

## 安全说明

- API Token **不会**被写入 GitHub 仓库的任何文件中，仅通过命令行参数在执行期间传入目标服务器。
- 生成的 `.env` 文件权限被设置为 `600`（仅 root 可读写），降低本地泄露风险。
- 建议为 DDNS 场景创建仅具备 **Zone.DNS 编辑权限** 的最小化 Cloudflare API Token，而非使用 Global API Key。

## License

MIT
