# JDMAX Relay

JDMAX Relay 是一个 Linux 请求转发服务。目标域名存在 AAAA 记录时，服务会从服务器
实际可用的 global-unicast IPv6 子网中临时生成出口地址；目标只有 A 记录或 IPv6
连接失败时，`auto` 模式会使用 IPv4。

## 功能

- 自动识别 `amd64`、`arm`、`arm64`、`armv7`。
- 安装前检查 global-unicast IPv6、IPv6 路由和公网 IPv6 连通性。
- 自动识别出口网卡和实际可用 IPv6 子网。
- 接收 `/48`–`/127` 前缀；上游为 `/48`–`/63` 聚合范围时，自动收敛到当前网卡
  地址所在的可路由 `/64`，避免随机进入未路由的相邻子网。
- 每个请求临时绑定随机 IPv6 `/128`，请求结束后自动删除。
- 自动安装或复用 Docker，升级前自动备份旧文件和旧镜像。
- 使用 `safari_ios_18_0` TLS profile，支持 HTTP/2。
- `/health` 提供 IPv6 前缀、地址池和绑定失败次数等状态。

## 支持架构

安装脚本会根据 `uname -m` 自动选择：

| Linux 架构 | 使用文件 |
|---|---|
| `x86_64` / `amd64` | `jdmax-relay-amd64` |
| `aarch64` / `arm64` | `jdmax-relay-arm64` |
| `armv7l` | `jdmax-relay-armv7` |
| `armv5l` / `armv6l` | `jdmax-relay-arm` |

## 安装要求

1. Linux 服务器或 ARM Linux 设备。
2. 系统已经获得 `2000::/3` global-unicast IPv6 地址。
3. 存在可用的 IPv6 默认路由并能访问公网 IPv6。
4. 使用 `root` 或 `sudo` 执行安装。

安装脚本会先检查以上条件。没有可用 IPv6 时会在安装 Docker、写入文件或替换旧
容器之前停止。

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/9Rebels/jdmax-relay/main/install.sh | sudo bash
```

脚本自动完成：

1. 检测 CPU 架构；
2. 检查 Linux 是否启用 IPv6；
3. 检查 global-unicast IPv6 地址；
4. 检查 IPv6 出站路由与公网连通性；
5. 下载匹配架构的二进制并校验 SHA256；
6. 检查或安装 Docker；
7. 备份旧版本；
8. 创建带 host 网络及 `NET_ADMIN` capability 的容器；
9. 等待 `/health` 返回有效 IPv6 前缀后完成安装。

默认配置：

```text
容器名称：jdmax-relay
监听端口：24678
安装目录：/opt/jdmax-relay
IP 模式：auto
IPv6 前缀：auto
```

## 只做安装前检查

只检查架构、IPv6 地址、路由和公网 IPv6，不下载、不安装、不修改服务：

```bash
curl -fsSL https://raw.githubusercontent.com/9Rebels/jdmax-relay/main/install.sh \
  | sudo bash -s -- --check-only
```

## 指定网卡或端口

```bash
curl -fsSL https://raw.githubusercontent.com/9Rebels/jdmax-relay/main/install.sh \
  | sudo bash -s -- --interface eth0 --port 24678
```

常见网卡名包括 `eth0`、`ens18`、`enp4s0`。可以先执行：

```bash
ip -6 addr show scope global
ip -6 route
```

## 公网 IPv6 探测站异常时安装

如果已经人工确认服务器具有 global-unicast IPv6 和正常 IPv6 路由，仅公网探测站
临时不可访问，可以跳过外部探测：

```bash
curl -fsSL https://raw.githubusercontent.com/9Rebels/jdmax-relay/main/install.sh \
  | sudo bash -s -- --skip-connectivity
```

该选项仍会检查本机 IPv6 地址和 IPv6 出站路由。

## 离线或手动安装

下载以下文件并放在同一目录：

```text
install.sh
SHA256SUMS
jdmax-relay-amd64
jdmax-relay-arm
jdmax-relay-arm64
jdmax-relay-armv7
```

然后执行：

```bash
chmod +x install.sh
sudo bash install.sh
```

脚本优先使用同目录中与当前机器架构匹配的二进制，并通过 `SHA256SUMS` 校验。

## 验证安装

服务器本机执行：

```bash
curl http://127.0.0.1:24678/health
```

正常状态应包含：

```json
{
  "ok": true,
  "ipv6Available": true,
  "defaultMode": "auto",
  "ipv6Pool": {
    "enabled": true,
    "auto": true,
    "detectedPrefix": "IPV6_PREFIX/64",
    "bindFailures": 0
  }
}
```

局域网其他设备访问：

```text
http://SERVER_IP:24678/health
```

建议仅向可信局域网或指定客户端开放 `24678` 端口。

## JDMAX 接入方法

在 JDMAX 公共配置中填写 Relay 地址：

```javascript
RS_RELAY_URL: 'http://SERVER_IP:24678',
```

青龙、白虎或其他 Linux 环境也可以设置：

```bash
export RS_RELAY_URL="http://SERVER_IP:24678"
```

配置后重启对应脚本或运行环境。请求成功时可看到类似日志：

```text
🌐 JDMAX Relay 出口 IP: IPV6_ADDRESS → api.m.jd.com (ipv6)
```

不配置或清空 `RS_RELAY_URL` 时，JDMAX 保持原请求方式。

## 直接调用接口

请求地址：

```text
POST http://SERVER_IP:24678/v1/request
Content-Type: application/json
```

示例：

```bash
curl -sS http://SERVER_IP:24678/v1/request \
  -H 'Content-Type: application/json' \
  --data-binary '{
    "url":"https://api64.ipify.org?format=json",
    "method":"GET",
    "headers":{"Accept":["application/json"]},
    "timeoutMs":30000
  }'
```

响应中的关键字段：

```json
{
  "ipFamily": "ipv6",
  "sourceAddr": "[IPV6_ADDRESS]:PORT",
  "remoteAddr": "[REMOTE_IPV6]:443",
  "protocol": "HTTP/2.0",
  "profile": "safari_ios_18_0"
}
```

业务请求体需要使用 `bodyBase64` 传入。

## 常用管理命令

查看状态：

```bash
docker ps --filter name=jdmax-relay
curl http://127.0.0.1:24678/health
```

查看日志：

```bash
docker logs -f jdmax-relay
```

重启：

```bash
docker restart jdmax-relay
```

查看配置：

```bash
cat /opt/jdmax-relay/.env
```

## 更新

重新执行一键安装命令即可。安装脚本会先备份当前文件及 `jdmax-relay:local` 镜像，
再下载、校验和部署新版本：

```bash
curl -fsSL https://raw.githubusercontent.com/9Rebels/jdmax-relay/main/install.sh | sudo bash
```

备份默认保存在：

```text
/opt/jdmax-relay-backups/
```

## 卸载

```bash
docker rm -f jdmax-relay
docker image rm jdmax-relay:local
sudo rm -rf /opt/jdmax-relay
```

如不再需要备份，可自行删除 `/opt/jdmax-relay-backups/`。

## 常见问题

### 安装提示没有 global-unicast IPv6

执行：

```bash
ip -6 addr show scope global
```

必须存在以 `2` 或 `3` 开头、属于 `2000::/3` 的公网 IPv6。`fe80::/10` 链路本地
地址和 `fc00::/7` ULA 地址不符合安装条件。

### `/60` 或 `/62` 为什么最后显示 `/64`

`/60`、`/62` 通常是上游聚合委派范围，当前网卡实际可路由的是其中一个具体
`/64`。Relay 会根据网卡真实地址自动收敛到该 `/64`，防止生成落入未路由兄弟
子网的地址。

### 请求仍显示 IPv4

依次检查：

1. 目标域名是否存在 AAAA 记录；
2. `/health` 中 `ipv6Available` 是否为 `true`；
3. `ipv6Pool.detectedPrefix` 是否为实际可路由前缀；
4. `bindFailures` 是否为 `0`；
5. 客户端是否显式传入了 IPv4 模式；
6. 服务器 IPv6 链路是否超时。

`auto` 模式在目标只有 A 记录或 IPv6 连接失败时会使用 IPv4，这是正常行为。

### 出现 `exec format error`

机器架构与二进制不匹配。使用一键安装脚本会自动选择正确架构；手动部署时先执行：

```bash
uname -m
```

### `bindFailures` 持续增加

容器必须使用 host 网络并具备 `NET_ADMIN` capability。一键安装脚本会自动配置这
两项。
