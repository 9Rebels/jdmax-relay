#!/usr/bin/env bash
set -Eeuo pipefail

umask 022

SERVICE_NAME="jdmax-relay"
INSTALL_DIR="${JDMAX_RELAY_INSTALL_DIR:-/opt/jdmax-relay}"
BACKUP_ROOT="${JDMAX_RELAY_BACKUP_DIR:-/opt/jdmax-relay-backups}"
PORT="${JDMAX_RELAY_PORT:-24678}"
IPV6_INTERFACE="${JDMAX_RELAY_INTERFACE:-}"
BASE_URL="${JDMAX_RELAY_BASE_URL:-}"
REPO_SLUG="${JDMAX_RELAY_REPO:-9Rebels/jdmax-relay}"
REPO_REF="${JDMAX_RELAY_REF:-main}"
AUTO_INSTALL_DOCKER="${JDMAX_RELAY_INSTALL_DOCKER:-1}"
SKIP_IPV6_CONNECTIVITY_CHECK="${JDMAX_RELAY_SKIP_IPV6_CONNECTIVITY_CHECK:-0}"
SKIP_CHECKSUM="${JDMAX_RELAY_SKIP_CHECKSUM:-0}"
CHECK_ONLY=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { printf '%b[信息]%b %s\n' "$BLUE" "$NC" "$*"; }
ok() { printf '%b[完成]%b %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%b[警告]%b %s\n' "$YELLOW" "$NC" "$*" >&2; }
die() { printf '%b[错误]%b %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
JDMAX Relay 一键安装脚本

用法：
  sudo bash install.sh [选项]

选项：
  --interface IFACE    指定 IPv6 出口网卡；默认自动检测
  --port PORT          服务端口；默认 24678
  --base-url URL       架构二进制和 SHA256SUMS 所在的基础 URL
  --repo OWNER/REPO    GitHub 仓库；默认 9Rebels/jdmax-relay
  --ref REF            GitHub 分支或标签；默认 main
  --no-docker-install  未安装 Docker 时停止，不自动安装
  --skip-connectivity  只检查本机 IPv6 地址和路由，跳过公网 IPv6 探测
  --check-only         只执行架构和 IPv6 安装前检查，不安装
  -h, --help           显示帮助

环境变量与选项对应：
  JDMAX_RELAY_INTERFACE
  JDMAX_RELAY_PORT
  JDMAX_RELAY_BASE_URL
  JDMAX_RELAY_REPO
  JDMAX_RELAY_REF
  JDMAX_RELAY_INSTALL_DOCKER=0|1
  JDMAX_RELAY_SKIP_IPV6_CONNECTIVITY_CHECK=0|1
EOF
}

while (($#)); do
    case "$1" in
        --interface)
            (($# >= 2)) || die "--interface 缺少参数"
            IPV6_INTERFACE="$2"
            shift 2
            ;;
        --port)
            (($# >= 2)) || die "--port 缺少参数"
            PORT="$2"
            shift 2
            ;;
        --base-url)
            (($# >= 2)) || die "--base-url 缺少参数"
            BASE_URL="${2%/}"
            shift 2
            ;;
        --repo)
            (($# >= 2)) || die "--repo 缺少参数"
            REPO_SLUG="$2"
            shift 2
            ;;
        --ref)
            (($# >= 2)) || die "--ref 缺少参数"
            REPO_REF="$2"
            shift 2
            ;;
        --no-docker-install)
            AUTO_INSTALL_DOCKER=0
            shift
            ;;
        --skip-connectivity)
            SKIP_IPV6_CONNECTIVITY_CHECK=1
            shift
            ;;
        --check-only)
            CHECK_ONLY=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "未知参数：$1"
            ;;
    esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请使用 root 执行：sudo bash install.sh"
[[ "$(uname -s)" == "Linux" ]] || die "此安装脚本只支持 Linux"
[[ "$PORT" =~ ^[0-9]+$ ]] && ((PORT >= 1 && PORT <= 65535)) || die "端口必须为 1-65535"
command -v ip >/dev/null 2>&1 || die "缺少 ip 命令，请先安装 iproute2 后重新执行"
if [[ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] && \
   [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" == "1" ]]; then
    die "Linux 内核已禁用 IPv6（net.ipv6.conf.all.disable_ipv6=1）"
fi

case "$(uname -m)" in
    x86_64|amd64)
        ARCH="amd64"
        ;;
    aarch64|arm64)
        ARCH="arm64"
        ;;
    armv7l|armv7*)
        ARCH="armv7"
        ;;
    armv5l|armv6l|arm*)
        ARCH="arm"
        ;;
    *)
        die "暂未提供 $(uname -m) 架构的二进制"
        ;;
esac

BINARY_NAME="jdmax-relay-${ARCH}"
SCRIPT_SOURCE="${BASH_SOURCE[0]-}"
if [[ -n "$SCRIPT_SOURCE" && -f "$SCRIPT_SOURCE" ]]; then
    SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" 2>/dev/null && pwd -P || pwd -P)"
else
    # When invoked as `curl ... | bash`, there is no script file to inspect.
    SCRIPT_DIR="$PWD"
fi
TMP_DIR="$(mktemp -d)"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/${STAMP}"
ROLLBACK_IMAGE="jdmax-relay:rollback-${STAMP}"
HAD_OLD_IMAGE=0

cleanup() {
    rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

if [[ -z "$IPV6_INTERFACE" && -f "${INSTALL_DIR}/.env" ]]; then
    IPV6_INTERFACE="$(awk -F= '$1 == "JDMAX_RELAY_IPV6_INTERFACE" {print $2; exit}' "${INSTALL_DIR}/.env" | tr -d '\r' || true)"
fi

find_global_ipv6() {
    local output
    if [[ -n "$IPV6_INTERFACE" ]]; then
        output="$(ip -o -6 addr show dev "$IPV6_INTERFACE" scope global up 2>/dev/null || true)"
    else
        output="$(ip -o -6 addr show scope global up 2>/dev/null || true)"
    fi

    awk '
        {
            address = tolower($4)
            if (address ~ /^[23][0-9a-f]*:/) {
                split(address, cidr, "/")
                prefix = cidr[2] + 0
                if (prefix >= 48 && prefix <= 127) {
                    print $2, $4
                    found = 1
                    exit
                }
                if (fallback == "") {
                    fallback = $2 " " $4
                }
            }
        }
        END {
            if (!found && fallback != "") {
                print fallback
            }
        }
    ' <<<"$output"
}

printf '%b%s%b\n' "$GREEN" "JDMAX Relay 多架构一键安装" "$NC"
printf '%s\n' "================================"
info "系统架构：$(uname -m) -> ${ARCH}"

info "安装前检查 global-unicast IPv6..."
IPV6_LINE="$(find_global_ipv6)"
[[ -n "$IPV6_LINE" ]] || die "没有发现 2000::/3 global-unicast IPv6 地址，安装已停止"

DETECTED_INTERFACE="${IPV6_LINE%% *}"
DETECTED_INTERFACE="${DETECTED_INTERFACE%%@*}"
DETECTED_CIDR="${IPV6_LINE#* }"
IPV6_INTERFACE="${IPV6_INTERFACE:-$DETECTED_INTERFACE}"
IPV6_INTERFACE="${IPV6_INTERFACE%%@*}"

ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1 || \
    die "发现 IPv6 地址 ${DETECTED_CIDR}，但没有可用 IPv6 出站路由"

ok "IPv6 地址：${DETECTED_CIDR}（网卡 ${IPV6_INTERFACE}）"

download_to() {
    local url="$1"
    local output="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --connect-timeout 10 --max-time 180 "$url" -o "$output"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$output" "$url"
    else
        die "缺少 curl/wget，不能下载 ${url}"
    fi
}

probe_public_ipv6() {
    local url result
    for url in "https://api6.ipify.org" "https://ipv6.icanhazip.com"; do
        if command -v curl >/dev/null 2>&1; then
            result="$(curl --noproxy '*' -6 -fsS --connect-timeout 5 --max-time 12 "$url" 2>/dev/null || true)"
        elif command -v wget >/dev/null 2>&1; then
            result="$(wget -q -O - --timeout=12 "$url" 2>/dev/null || true)"
        else
            result=""
        fi
        result="$(tr -d '[:space:]' <<<"$result")"
        if [[ "$result" == *:* ]]; then
            printf '%s' "$result"
            return 0
        fi
    done
    return 1
}

if [[ "$SKIP_IPV6_CONNECTIVITY_CHECK" == "1" ]]; then
    warn "已跳过公网 IPv6 连通性探测"
else
    info "检查公网 IPv6 连通性..."
    PUBLIC_IPV6="$(probe_public_ipv6 || true)"
    [[ -n "$PUBLIC_IPV6" ]] || die "本机有 IPv6 地址，但公网 IPv6 探测失败；修复路由/DNS后重试，或使用 --skip-connectivity 仅跳过公网探测"
    ok "公网 IPv6 出口：${PUBLIC_IPV6}"
fi

if [[ "$CHECK_ONLY" == "1" ]]; then
    ok "安装前检查通过，可使用 ${BINARY_NAME}"
    exit 0
fi

verify_checksum() {
    local binary="$1"
    local sums="$2"
    local expected actual
    expected="$(awk -v name="$BINARY_NAME" '$2 == name {print tolower($1); exit}' "$sums")"
    [[ -n "$expected" ]] || die "SHA256SUMS 中没有 ${BINARY_NAME}"

    if command -v sha256sum >/dev/null 2>&1; then
        actual="$(sha256sum "$binary" | awk '{print tolower($1)}')"
    elif command -v shasum >/dev/null 2>&1; then
        actual="$(shasum -a 256 "$binary" | awk '{print tolower($1)}')"
    elif command -v openssl >/dev/null 2>&1; then
        actual="$(openssl dgst -sha256 "$binary" | awk '{print tolower($NF)}')"
    else
        die "缺少 sha256sum/shasum/openssl，不能校验二进制"
    fi

    [[ "$actual" == "$expected" ]] || die "${BINARY_NAME} 的 SHA256 校验失败"
    ok "SHA256 校验通过：${actual}"
}

SOURCE_BINARY="${SCRIPT_DIR}/${BINARY_NAME}"
SOURCE_SUMS="${SCRIPT_DIR}/SHA256SUMS"
STAGED_BINARY="${TMP_DIR}/jdmax-relay"

if [[ -f "$SOURCE_BINARY" ]]; then
    info "使用安装脚本同目录的 ${BINARY_NAME}"
    cp -- "$SOURCE_BINARY" "$STAGED_BINARY"
    if [[ "$SKIP_CHECKSUM" != "1" ]]; then
        [[ -f "$SOURCE_SUMS" ]] || die "本地安装缺少 SHA256SUMS"
        verify_checksum "$STAGED_BINARY" "$SOURCE_SUMS"
    fi
else
    if [[ -z "$BASE_URL" ]]; then
        BASE_URL="https://raw.githubusercontent.com/${REPO_SLUG}/${REPO_REF}"
    fi
    BASE_URL="${BASE_URL%/}"
    info "下载 ${BASE_URL}/${BINARY_NAME}"
    download_to "${BASE_URL}/${BINARY_NAME}" "$STAGED_BINARY"
    if [[ "$SKIP_CHECKSUM" != "1" ]]; then
        download_to "${BASE_URL}/SHA256SUMS" "${TMP_DIR}/SHA256SUMS"
        verify_checksum "$STAGED_BINARY" "${TMP_DIR}/SHA256SUMS"
    fi
fi
chmod 0755 "$STAGED_BINARY"

ensure_docker() {
    if command -v docker >/dev/null 2>&1; then
        return 0
    fi
    [[ "$AUTO_INSTALL_DOCKER" == "1" ]] || die "Docker 未安装；安装 Docker 后重试，或取消 --no-docker-install"

    info "未发现 Docker，开始执行 Docker 官方安装脚本..."
    download_to "https://get.docker.com" "${TMP_DIR}/get-docker.sh"
    sh "${TMP_DIR}/get-docker.sh"
    command -v docker >/dev/null 2>&1 || die "Docker 自动安装没有成功"
}

ensure_docker
if ! docker info >/dev/null 2>&1; then
    info "启动 Docker 服务..."
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker
    elif command -v service >/dev/null 2>&1; then
        service docker start
    fi
fi
docker info >/dev/null 2>&1 || die "Docker daemon 未运行"
ok "Docker 可用"

mkdir -p -- "$INSTALL_DIR/dist" "$BACKUP_ROOT"
if [[ -e "${INSTALL_DIR}/dist/jdmax-relay" || -e "${INSTALL_DIR}/.env" || -e "${INSTALL_DIR}/Dockerfile" ]]; then
    mkdir -p -- "$BACKUP_DIR"
    cp -a -- "${INSTALL_DIR}/." "$BACKUP_DIR/"
    ok "旧文件已备份到 ${BACKUP_DIR}"
fi

if docker image inspect jdmax-relay:local >/dev/null 2>&1; then
    docker image tag jdmax-relay:local "$ROLLBACK_IMAGE"
    HAD_OLD_IMAGE=1
    ok "旧镜像已保留为 ${ROLLBACK_IMAGE}"
fi

cp -- "$STAGED_BINARY" "${INSTALL_DIR}/dist/jdmax-relay"
chmod 0755 "${INSTALL_DIR}/dist/jdmax-relay"

set_env_value() {
    local key="$1"
    local value="$2"
    local file="$3"
    local temp="${file}.tmp"
    if [[ -f "$file" ]]; then
        awk -F= -v key="$key" '{sub(/\r$/, "")} $1 != key {print}' "$file" >"$temp"
    else
        : >"$temp"
    fi
    printf '%s=%s\n' "$key" "$value" >>"$temp"
    mv -- "$temp" "$file"
}

ENV_FILE="${INSTALL_DIR}/.env"
set_env_value JDMAX_RELAY_ADDR "0.0.0.0:${PORT}" "$ENV_FILE"
set_env_value JDMAX_RELAY_IPV6_INTERFACE "$IPV6_INTERFACE" "$ENV_FILE"

if ! grep -q '^JDMAX_RELAY_IP_MODE=' "$ENV_FILE"; then
    set_env_value JDMAX_RELAY_IP_MODE auto "$ENV_FILE"
fi
if ! grep -q '^JDMAX_RELAY_PROFILE=' "$ENV_FILE"; then
    set_env_value JDMAX_RELAY_PROFILE safari_ios_18_0 "$ENV_FILE"
fi
if ! grep -q '^JDMAX_RELAY_IPV6_PREFIX=' "$ENV_FILE"; then
    set_env_value JDMAX_RELAY_IPV6_PREFIX auto "$ENV_FILE"
fi
if ! grep -q '^JDMAX_RELAY_IPV6_WARM_TARGET=' "$ENV_FILE"; then
    set_env_value JDMAX_RELAY_IPV6_WARM_TARGET 256 "$ENV_FILE"
fi
if ! grep -q '^JDMAX_RELAY_IPV6_REFILL_WORKERS=' "$ENV_FILE"; then
    set_env_value JDMAX_RELAY_IPV6_REFILL_WORKERS 16 "$ENV_FILE"
fi
if ! grep -q '^JDMAX_RELAY_IPV6_RECENT_LIMIT=' "$ENV_FILE"; then
    set_env_value JDMAX_RELAY_IPV6_RECENT_LIMIT 200000 "$ENV_FILE"
fi
if ! grep -q '^JDMAX_RELAY_IPV6_COOLDOWN_SECONDS=' "$ENV_FILE"; then
    set_env_value JDMAX_RELAY_IPV6_COOLDOWN_SECONDS 86400 "$ENV_FILE"
fi
if ! grep -q '^JDMAX_RELAY_IPV6_LIFETIME_SECONDS=' "$ENV_FILE"; then
    set_env_value JDMAX_RELAY_IPV6_LIFETIME_SECONDS 900 "$ENV_FILE"
fi
chmod 0600 "$ENV_FILE"

cat >"${INSTALL_DIR}/Dockerfile" <<'EOF'
FROM alpine:3.22
RUN apk add --no-cache ca-certificates
COPY dist/jdmax-relay /usr/local/bin/jdmax-relay
RUN chmod 0755 /usr/local/bin/jdmax-relay
EXPOSE 24678
ENTRYPOINT ["/usr/local/bin/jdmax-relay"]
EOF

cat >"${INSTALL_DIR}/run.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
docker rm -f ${SERVICE_NAME} >/dev/null 2>&1 || true
exec docker run -d \\
  --name ${SERVICE_NAME} \\
  --restart unless-stopped \\
  --network host \\
  --cap-drop ALL \\
  --cap-add NET_ADMIN \\
  --security-opt no-new-privileges:true \\
  --env-file "${INSTALL_DIR}/.env" \\
  --health-cmd 'wget -q -O - http://127.0.0.1:${PORT}/health >/dev/null || exit 1' \\
  --health-interval 30s \\
  --health-timeout 5s \\
  --health-retries 3 \\
  jdmax-relay:local
EOF
chmod 0755 "${INSTALL_DIR}/run.sh"

info "构建本机 ${ARCH} 运行镜像..."
docker build --pull -t jdmax-relay:local "$INSTALL_DIR"

rollback() {
    warn "新版本启动验证失败"
    docker logs --tail=100 "$SERVICE_NAME" >&2 2>/dev/null || true
    docker rm -f "$SERVICE_NAME" >/dev/null 2>&1 || true

    if [[ "$HAD_OLD_IMAGE" == "1" ]]; then
        warn "自动恢复旧镜像 ${ROLLBACK_IMAGE}"
        if [[ -d "$BACKUP_DIR" ]]; then
            cp -a -- "${BACKUP_DIR}/." "$INSTALL_DIR/"
        fi
        docker image tag "$ROLLBACK_IMAGE" jdmax-relay:local
        "${INSTALL_DIR}/run.sh" >/dev/null
    fi
    die "部署失败；备份目录：${BACKUP_DIR}"
}

info "启动 ${SERVICE_NAME} 容器..."
if ! "${INSTALL_DIR}/run.sh" >/dev/null; then
    rollback
fi

health_request() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/health"
    else
        wget -q -O - --timeout=5 "http://127.0.0.1:${PORT}/health"
    fi
}

HEALTH=""
for ((attempt = 1; attempt <= 30; attempt++)); do
    CANDIDATE_HEALTH="$(health_request 2>/dev/null || true)"
    if [[ -n "$CANDIDATE_HEALTH" ]] && \
       grep -q '"ipv6Available":true' <<<"$CANDIDATE_HEALTH" && \
       grep -q '"enabled":true' <<<"$CANDIDATE_HEALTH" && \
       grep -Eq '"detectedPrefix":"[^"]+"' <<<"$CANDIDATE_HEALTH"; then
        HEALTH="$CANDIDATE_HEALTH"
        break
    fi
    sleep 1
done
[[ -n "$HEALTH" ]] || rollback

ok "安装成功"
printf '\n服务地址：  http://HOST:%s\n' "$PORT"
printf '健康检查：  http://HOST:%s/health\n' "$PORT"
printf '安装目录：  %s\n' "$INSTALL_DIR"
printf 'IPv6 网卡： %s\n' "$IPV6_INTERFACE"
printf '架构文件：  %s\n' "$BINARY_NAME"
printf '健康状态：  %s\n\n' "$HEALTH"
printf '常用命令：\n'
printf '  docker logs -f %s\n' "$SERVICE_NAME"
printf '  docker restart %s\n' "$SERVICE_NAME"
printf '  curl http://127.0.0.1:%s/health\n' "$PORT"
