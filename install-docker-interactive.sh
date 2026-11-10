#!/usr/bin/env bash
#
# Interactive Docker CE installer for Ubuntu, Debian, RHEL-family and Fedora.
#
# Default repository: USTC Docker CE mirror
# Usage:
#   sudo ./install-docker-interactive.sh
#   ./install-docker-interactive.sh --detect
#   ./install-docker-interactive.sh --dry-run
#

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="${0##*/}"
readonly DAEMON_JSON="/etc/docker/daemon.json"
readonly DOCKER_REPO_FILE="/etc/apt/sources.list.d/docker.list"
readonly DOCKER_KEYRING="/etc/apt/keyrings/docker.asc"
readonly DOCKER_YUM_REPO="/etc/yum.repos.d/docker-ce.repo"
readonly USTC_REPO_BASE="https://mirrors.ustc.edu.cn/docker-ce/linux"
readonly OFFICIAL_REPO_BASE="https://download.docker.com/linux"
readonly COMPOSE_VERSION="v2.27.1"
readonly COMPOSE_PROXY_BASE="https://ghfast.top/https://github.com/docker/compose/releases/download"
readonly COMPOSE_OFFICIAL_BASE="https://github.com/docker/compose/releases/download"
readonly COMPOSE_PLUGIN_PATH="/usr/local/lib/docker/cli-plugins/docker-compose"
readonly COMPOSE_COMMAND_PATH="/usr/local/bin/docker-compose"

ASSUME_YES=0
DRY_RUN=0
DETECT_ONLY=0
ACTION="install"
INSTALL_VERIFY=1
USER_SOURCE=""
USER_REPO_BASE=""
USER_VERSION=""
USER_DAEMON_MODE=""
USER_PIN=""
PIN_VERSION=0
INSTALL_COMPOSE=1
INSTALL_BUILDX=1

SUDO=()
COLOR=0

OS_ID=""
OS_LIKE=""
OS_VERSION=""
OS_CODENAME=""
OS_PRETTY=""
ARCH_RAW=""
ARCH=""
RPM_ARCH=""
PKG_MANAGER=""
REPO_DISTRO=""
REPO_RELEASE=""
REPO_BASE=""
REPO_SOURCE_NAME=""
SELECTED_VERSION="latest"

cleanup_files=()

on_exit() {
    local status=$?
    local file
    trap - ERR
    for file in "${cleanup_files[@]:-}"; do
        if [[ -n "$file" && -f "$file" ]]; then
            rm -f -- "$file" || true
        fi
    done
    return "$status"
}
trap on_exit EXIT
trap 'on_error "$LINENO" "$?"' ERR

on_error() {
    local line="$1"
    local status="$2"
    trap - ERR
    die "脚本在第 $line 行意外失败（退出码 $status）。"
}

if [[ -t 1 ]]; then
    COLOR=1
fi

c_reset=""
c_bold=""
c_red=""
c_yellow=""
c_cyan=""
if ((COLOR)); then
    c_reset=$'\033[0m'
    c_bold=$'\033[1m'
    c_red=$'\033[31m'
    c_yellow=$'\033[33m'
    c_cyan=$'\033[36m'
fi

info() {
    printf '%s[信息]%s %s\n' "$c_cyan" "$c_reset" "$*"
}

warn() {
    printf '%s[提示]%s %s\n' "$c_yellow" "$c_reset" "$*" >&2
}

die() {
    printf '%s[错误]%s ' "$c_red" "$c_reset" >&2
    printf '%b\n' "$*" >&2
    exit 1
}

section() {
    printf '\n%s%s%s\n' "$c_bold" "$*" "$c_reset"
}

usage() {
    cat <<EOF
用法: $SCRIPT_NAME [选项]

交互式安装 Docker CE，并根据系统版本配置对应的 Docker 软件源。

选项:
  --detect                    只检测系统、仓库类型和 Docker 状态，然后退出
  --dry-run                   完整交互并展示操作，但不修改系统
  --yes                       使用默认值，跳过最后的安装确认
  --uninstall                 交互式卸载 Docker CE 和/或 Compose
  --unlock                    解除脚本设置的 Docker 版本锁定
  --pin                       固定 Docker 相关软件包版本
  --no-pin                    不固定 Docker 版本，允许以后手动升级
  --source <ustc|official|existing>
                              软件源；默认为 ustc
  --repo-base <URL>           自定义 Docker CE 镜像根地址
  --version <latest|版本号>   跳过版本选择
  --daemon-config <default|keep|skip>
                              跳过 daemon.json 处理方式选择
  --no-compose                不安装 docker-compose v2.27.1 二进制
  --no-buildx                 不安装 docker-buildx-plugin
  --no-verify                 不运行 hello-world 验证容器
  -h, --help                  显示帮助

示例:
  sudo ./$SCRIPT_NAME
  ./$SCRIPT_NAME --detect
  ./$SCRIPT_NAME --dry-run --source ustc --version latest
  sudo ./$SCRIPT_NAME --uninstall
  sudo ./$SCRIPT_NAME --unlock

支持的软件源安装方式:
  Ubuntu / Debian / RHEL-family / Fedora
EOF
}

require_value() {
    local option="$1"
    local value="${2:-}"
    [[ -n "$value" ]] || die "$option 需要一个值"
}

parse_args() {
    while (($#)); do
        case "$1" in
            --detect)
                DETECT_ONLY=1
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --yes)
                ASSUME_YES=1
                ;;
            --uninstall)
                ACTION="uninstall"
                ;;
            --unlock)
                ACTION="unlock"
                ;;
            --pin)
                USER_PIN=1
                ;;
            --no-pin)
                USER_PIN=0
                ;;
            --source)
                require_value "$1" "${2:-}"
                USER_SOURCE="$2"
                shift
                ;;
            --repo-base)
                require_value "$1" "${2:-}"
                USER_REPO_BASE="$2"
                shift
                ;;
            --version)
                require_value "$1" "${2:-}"
                USER_VERSION="$2"
                shift
                ;;
            --daemon-config)
                require_value "$1" "${2:-}"
                USER_DAEMON_MODE="$2"
                shift
                ;;
            --no-compose)
                INSTALL_COMPOSE=0
                ;;
            --no-buildx)
                INSTALL_BUILDX=0
                ;;
            --no-verify)
                INSTALL_VERIFY=0
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "未知参数: $1（使用 --help 查看帮助）"
                ;;
        esac
        shift
    done

    case "$USER_SOURCE" in
        ""|ustc|official|existing) ;;
        *) die "--source 只能是 ustc、official 或 existing" ;;
    esac
    case "$USER_DAEMON_MODE" in
        ""|default|keep|skip) ;;
        *) die "--daemon-config 只能是 default、keep 或 skip" ;;
    esac
    case "$USER_PIN" in
        ""|0|1) ;;
        *) die "--pin/--no-pin 参数冲突" ;;
    esac
    if [[ -n "$USER_REPO_BASE" ]]; then
        [[ "$USER_REPO_BASE" =~ ^https?://[^[:space:]]+$ ]] ||
            die "--repo-base 必须是有效的 http(s) URL"
    fi
}

read_input() {
    local prompt="$1"
    local default="${2:-}"
    local answer=""

    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " answer || die "未收到输入，已取消"
        printf '%s' "${answer:-$default}"
    else
        read -r -p "$prompt: " answer || die "未收到输入，已取消"
        printf '%s' "$answer"
    fi
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-y}"
    local suffix="[Y/n]"
    local answer=""
    local hint="y"

    if [[ "$default" == "n" ]]; then
        suffix="[y/N]"
        hint="n"
    fi

    while true; do
        printf '%s %s ' "$prompt" "$suffix" >&2
        read -r answer || die "未收到输入，已取消"
        answer="${answer:-$hint}"
        case "${answer,,}" in
            y|yes|是) return 0 ;;
            n|no|否) return 1 ;;
            *) warn "请输入 y 或 n。" ;;
        esac
    done
}

confirm_or_exit() {
    local prompt="$1"
    if ((ASSUME_YES)); then
        return 0
    fi
    ask_yes_no "$prompt" "n" || die "用户取消操作"
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

run() {
    if ((DRY_RUN)); then
        printf '%s[试运行]%s' "$c_yellow" "$c_reset" >&2
        printf ' %q' "$@" >&2
        printf '\n' >&2
        return 0
    fi
    "$@"
}

run_sudo() {
    run "${SUDO[@]}" "$@"
}

ensure_root_access() {
    if ((EUID == 0)); then
        SUDO=()
        return
    fi

    command -v sudo >/dev/null 2>&1 || die "需要 root 权限，且系统中未找到 sudo"
    SUDO=(sudo)

    if ((DRY_RUN)); then
        return
    fi

    info "正在申请 sudo 权限（后续安装将复用该授权）"
    sudo -v || die "sudo 授权失败"
}

detect_os() {
    [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release，暂不支持该系统"
    # shellcheck disable=SC1091
    . /etc/os-release

    OS_ID="${ID,,}"
    OS_LIKE="${ID_LIKE:-}"
    OS_LIKE="${OS_LIKE,,}"
    OS_VERSION="${VERSION_ID:-unknown}"
    OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    OS_CODENAME="${OS_CODENAME,,}"
    OS_PRETTY="${PRETTY_NAME:-$OS_ID $OS_VERSION}"
    ARCH_RAW="$(uname -m)"

    case "$ARCH_RAW" in
        x86_64|amd64)
            ARCH="amd64"
            RPM_ARCH="x86_64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            RPM_ARCH="aarch64"
            ;;
        armv7l|armhf)
            ARCH="armhf"
            RPM_ARCH="armv7hl"
            ;;
        ppc64le)
            ARCH="ppc64le"
            RPM_ARCH="ppc64le"
            ;;
        s390x)
            ARCH="s390x"
            RPM_ARCH="s390x"
            ;;
        *) die "不支持的 CPU 架构: $ARCH_RAW" ;;
    esac
}

detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
    elif command -v zypper >/dev/null 2>&1; then
        PKG_MANAGER="zypper"
    else
        die "未识别到 apt-get、dnf、yum 或 zypper"
    fi
}

contains_word() {
    local haystack="$1"
    local needle="$2"
    [[ " $haystack " == *" $needle "* ]]
}

detect_repo_platform() {
    local requested_distro="${DOCKER_REPO_DISTRO:-}"
    local requested_release="${DOCKER_REPO_RELEASE:-}"
    local major=""

    case "$PKG_MANAGER" in
        apt)
            if [[ -n "$requested_distro" && -n "$requested_release" ]]; then
                REPO_DISTRO="$requested_distro"
                REPO_RELEASE="$requested_release"
            elif [[ "$OS_ID" == "ubuntu" ]] ||
                 { contains_word "$OS_LIKE" "ubuntu" && [[ -n "${UBUNTU_CODENAME:-}" ]]; }; then
                REPO_DISTRO="ubuntu"
                REPO_RELEASE="${UBUNTU_CODENAME:-$OS_CODENAME}"
            elif [[ "$OS_ID" == "debian" ]] ||
                 { contains_word "$OS_LIKE" "debian" && [[ -n "$OS_CODENAME" ]]; }; then
                REPO_DISTRO="debian"
                REPO_RELEASE="$OS_CODENAME"
            else
                die "无法安全映射 $OS_PRETTY 到 Docker 的 Ubuntu/Debian 仓库。\n可显式指定，例如: DOCKER_REPO_DISTRO=ubuntu DOCKER_REPO_RELEASE=jammy sudo ./$SCRIPT_NAME"
            fi
            ;;
        dnf|yum)
            if [[ "$OS_ID" == "fedora" ]]; then
                REPO_DISTRO="fedora"
                REPO_RELEASE="${requested_release:-$OS_VERSION}"
            elif [[ "$OS_ID" == "centos" || "$OS_ID" == "rhel" ||
                    "$OS_ID" == "rocky" || "$OS_ID" == "almalinux" ||
                    "$OS_ID" == "ol" ]]; then
                # Docker publishes RHEL-compatible packages under the CentOS
                # repository, using only the major OS release.
                REPO_DISTRO="${requested_distro:-centos}"
                major="${OS_VERSION%%.*}"
                REPO_RELEASE="${requested_release:-$major}"
            else
                die "$OS_PRETTY 不是已支持的 YUM/DNF 发行版。\n可显式指定，例如: DOCKER_REPO_DISTRO=centos DOCKER_REPO_RELEASE=9 sudo ./$SCRIPT_NAME"
            fi
            ;;
        zypper)
            die "SUSE/openSUSE 不使用本脚本配置的 Docker CE 上游仓库。\n请优先使用 SUSE 发行版仓库中的 docker 包，或在其文档指定方式下安装容器运行时。"
            ;;
    esac

    [[ -n "$REPO_DISTRO" && -n "$REPO_RELEASE" ]] ||
        die "无法确定 Docker 仓库发行版或版本，请设置 DOCKER_REPO_DISTRO 和 DOCKER_REPO_RELEASE"
}

show_detection() {
    local docker_state="未安装"

    if command -v docker >/dev/null 2>&1; then
        docker_state="$(docker version --format '{{.Client.Version}}' 2>/dev/null || echo '已安装（客户端不可用）')"
    fi

    printf '\n%s系统检测%s\n' "$c_bold" "$c_reset"
    printf '  系统:       %s\n' "$OS_PRETTY"
    printf '  ID/VERSION: %s / %s\n' "$OS_ID" "$OS_VERSION"
    printf '  代号:       %s\n' "${OS_CODENAME:-未知}"
    printf '  架构:       %s (%s)\n' "$ARCH_RAW" "$ARCH"
    printf '  包管理:     %s\n' "$PKG_MANAGER"
    if [[ -n "$REPO_DISTRO" && -n "$REPO_RELEASE" ]]; then
        printf '  Docker仓库: %s / %s\n' "$REPO_DISTRO" "$REPO_RELEASE"
    fi
    printf '  Docker:     %s\n' "$docker_state"
    if command -v systemctl >/dev/null 2>&1; then
        local systemd_state=""
        systemd_state="$(systemctl is-system-running 2>/dev/null || true)"
        printf '  systemd:    %s\n' "${systemd_state:-unknown}"
    else
        printf '  systemd:    未找到（daemon.json 的 systemd cgroup 配置需要 systemd）\n'
    fi
    printf '\n'
}

choose_repository() {
    local choice=""

    if [[ -n "$USER_REPO_BASE" ]]; then
        USER_SOURCE="custom"
    elif [[ -z "$USER_SOURCE" ]]; then
        section "Docker 软件源"
        cat <<'EOF'
  1) 中科大镜像（推荐，默认）
  2) Docker 官方源
  3) 使用系统中已经配置好的 Docker 源
EOF
        choice="$(read_input "请选择" "1")"
        case "$choice" in
            1) USER_SOURCE="ustc" ;;
            2) USER_SOURCE="official" ;;
            3) USER_SOURCE="existing" ;;
            *) die "无效选择: $choice" ;;
        esac
    fi

    case "$USER_SOURCE" in
        ustc)
            REPO_BASE="$USTC_REPO_BASE"
            REPO_SOURCE_NAME="中科大镜像"
            ;;
        official)
            REPO_BASE="$OFFICIAL_REPO_BASE"
            REPO_SOURCE_NAME="Docker 官方源"
            ;;
        existing)
            REPO_BASE=""
            REPO_SOURCE_NAME="现有软件源"
            ;;
        custom)
            REPO_BASE="${USER_REPO_BASE%/}"
            REPO_SOURCE_NAME="自定义源 ($REPO_BASE)"
            ;;
        *)
            die "未知软件源: $USER_SOURCE"
            ;;
    esac
}

repo_urls() {
    case "$PKG_MANAGER" in
        apt)
            printf '%s/%s %s\n' "$REPO_BASE" "$REPO_DISTRO" \
                "$REPO_BASE/$REPO_DISTRO/gpg"
            ;;
        dnf|yum)
            printf '%s/%s/%s/%s/stable %s/%s/gpg\n' \
                "$REPO_BASE" "$REPO_DISTRO" "$REPO_RELEASE" "$RPM_ARCH" \
                "$REPO_BASE" "$REPO_DISTRO"
            ;;
    esac
}

check_repository_access() {
    local package_url=""
    local key_url=""

    [[ "$USER_SOURCE" == "existing" ]] && return
    IFS=' ' read -r package_url key_url < <(repo_urls)

    command -v curl >/dev/null 2>&1 ||
        die "缺少 curl；请先安装 curl 和 CA 证书"

    info "检查 Docker 仓库访问: $package_url"
    if ! curl -fsIL --retry 2 --connect-timeout 8 --max-time 30 "$package_url" >/dev/null; then
        die "无法访问 Docker 仓库: $package_url\n请检查网络、防火墙或改用 --source official"
    fi
    if ! curl -fsIL --retry 2 --connect-timeout 8 --max-time 30 "$key_url" >/dev/null; then
        die "无法访问 Docker 仓库签名密钥: $key_url"
    fi
}

backup_file() {
    local file="$1"
    local backup=""

    [[ -e "$file" ]] || return 0
    backup="${file}.bak.$(date +%Y%m%d-%H%M%S)"
    info "备份 $file -> $backup"
    run_sudo cp -a -- "$file" "$backup"
}

install_prerequisites() {
    case "$PKG_MANAGER" in
        apt)
            info "安装软件源所需的基础工具"
            run_sudo env DEBIAN_FRONTEND=noninteractive apt-get update
            run_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg
            ;;
        dnf)
            info "安装软件源所需的基础工具"
            run_sudo dnf install -y ca-certificates curl
            ;;
        yum)
            info "安装软件源所需的基础工具"
            run_sudo yum install -y ca-certificates curl
            ;;
    esac
}

configure_apt_repository() {
    local key_tmp=""
    local list_tmp=""

    info "配置 APT Docker 仓库: $REPO_BASE/$REPO_DISTRO"
    run_sudo install -d -m 0755 /etc/apt/keyrings
    key_tmp="$(mktemp)"
    list_tmp="$(mktemp)"
    cleanup_files+=("$key_tmp" "$list_tmp")

    curl -fsSL --retry 2 --connect-timeout 8 --max-time 60 \
        "$REPO_BASE/$REPO_DISTRO/gpg" -o "$key_tmp"
    if command -v gpg >/dev/null 2>&1; then
        gpg --show-keys "$key_tmp" >/dev/null 2>&1 ||
            die "下载的 Docker GPG 密钥格式无效"
    fi
    run_sudo install -m 0644 "$key_tmp" "$DOCKER_KEYRING"

    printf 'deb [arch=%s signed-by=%s] %s/%s %s stable\n' \
        "$ARCH" "$DOCKER_KEYRING" "$REPO_BASE" "$REPO_DISTRO" "$REPO_RELEASE" \
        >"$list_tmp"
    backup_file "$DOCKER_REPO_FILE"
    run_sudo install -m 0644 "$list_tmp" "$DOCKER_REPO_FILE"
    run_sudo env DEBIAN_FRONTEND=noninteractive apt-get update
}

configure_rpm_repository() {
    local repo_tmp=""

    info "配置 RPM Docker 仓库: $REPO_BASE/$REPO_DISTRO/$REPO_RELEASE"
    repo_tmp="$(mktemp)"
    cleanup_files+=("$repo_tmp")
    cat >"$repo_tmp" <<EOF
[docker-ce-stable]
name=Docker CE Stable - \$basearch
baseurl=$REPO_BASE/$REPO_DISTRO/$REPO_RELEASE/\$basearch/stable
enabled=1
gpgcheck=1
gpgkey=$REPO_BASE/$REPO_DISTRO/gpg
EOF
    backup_file "$DOCKER_YUM_REPO"
    run_sudo install -m 0644 "$repo_tmp" "$DOCKER_YUM_REPO"
}

configure_repository() {
    if [[ "$USER_SOURCE" == "existing" ]]; then
        warn "按选择使用现有 Docker 软件源；脚本不会改写仓库配置。"
        return
    fi

    install_prerequisites
    check_repository_access
    case "$PKG_MANAGER" in
        apt) configure_apt_repository ;;
        dnf|yum) configure_rpm_repository ;;
    esac
}

find_apt_conflicts() {
    local package=""
    local found=()
    local candidates=(docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc)

    for package in "${candidates[@]}"; do
        if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "install ok installed"; then
            found+=("$package")
        fi
    done
    if ((${#found[@]})); then
        printf '%s\n' "${found[@]}"
    fi
    return 0
}

handle_conflicting_packages() {
    local -a conflicts=()

    [[ "$PKG_MANAGER" == "apt" ]] || return 0
    mapfile -t conflicts < <(find_apt_conflicts)
    ((${#conflicts[@]})) || return 0

    warn "检测到可能与 Docker CE 冲突的包: ${conflicts[*]}"
    warn "仅移除包本身，不添加 purge，因此不会主动删除镜像或容器数据目录。"
    if ((ASSUME_YES)); then
        die "存在冲突包时不会自动移除。请先手动确认，再重新运行脚本。"
    fi
    ask_yes_no "是否移除这些冲突包后继续？" "n" ||
        die "已取消：请先手动处理冲突包"
    run_sudo env DEBIAN_FRONTEND=noninteractive apt-get remove -y "${conflicts[@]}"
}

list_apt_versions() {
    apt-cache madison docker-ce 2>/dev/null |
        awk '{print $3}' |
        awk 'NF && !seen[$0]++' |
        head -n 30
}

list_dnf_versions() {
    local manager="$1"
    "$manager" --quiet list --showduplicates --available docker-ce 2>/dev/null |
        awk '
            $1 ~ /^docker-ce\.(x86_64|aarch64|armv7hl|ppc64le|s390x|noarch)$/ {
                version = $2
                sub(/^[0-9]+:/, "", version)
                if (version ~ /^[0-9][A-Za-z0-9.+_~:-]*$/) print version
            }
        ' |
        awk 'NF && !seen[$0]++' |
        head -n 30
}

choose_version_from_list() {
    local versions=()
    local i=0
    local choice=""

    if [[ -n "$USER_VERSION" ]]; then
        SELECTED_VERSION="$USER_VERSION"
        return
    fi

    case "$PKG_MANAGER" in
        apt)
            mapfile -t versions < <(list_apt_versions)
            ;;
        dnf|yum)
            mapfile -t versions < <(list_dnf_versions "$PKG_MANAGER")
            ;;
    esac

    section "Docker CE 版本"
    echo "  0) 仓库最新版本（不锁定版本号）"
    for ((i = 0; i < ${#versions[@]}; i++)); do
        printf '  %d) %s\n' "$((i + 1))" "${versions[$i]}"
    done

    if ((${#versions[@]} == 0)); then
        warn "当前源没有查询到可安装版本；可输入手动版本号，例如 27.5.1。"
    fi

    choice="$(read_input "请选择版本（编号/latest/手动版本）" "0")"
    case "$choice" in
        0|latest|LATEST)
            SELECTED_VERSION="latest"
            ;;
        ''|*[!0-9]*)
            SELECTED_VERSION="$choice"
            ;;
        *)
            if ((choice >= 1 && choice <= ${#versions[@]})); then
                SELECTED_VERSION="${versions[$((choice - 1))]}"
            else
                die "版本编号超出范围: $choice"
            fi
            ;;
    esac

    if [[ "$SELECTED_VERSION" != "latest" &&
          ! "$SELECTED_VERSION" =~ ^[A-Za-z0-9.+:~_-]+$ ]]; then
        die "无效的 Docker 版本号: $SELECTED_VERSION"
    fi
}

show_installed_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        return
    fi

    warn "检测到系统已安装 Docker:"
    docker version 2>/dev/null || true
    if ((!ASSUME_YES)); then
        ask_yes_no "继续可能升级或降级现有 Docker，是否继续？" "n" ||
            die "用户取消"
    fi
}

choose_components() {
    section "安装组件"
    if ((ASSUME_YES)); then
        return
    fi
    if ((INSTALL_COMPOSE)) &&
       ! ask_yes_no "安装 Docker Compose $COMPOSE_VERSION 二进制？" "y"; then
        INSTALL_COMPOSE=0
    fi
    if ((INSTALL_BUILDX)) && ! ask_yes_no "安装 docker buildx 插件？" "y"; then
        INSTALL_BUILDX=0
    fi
}

choose_version_pin() {
    if [[ -n "$USER_PIN" ]]; then
        PIN_VERSION="$USER_PIN"
        return
    fi

    if [[ "$SELECTED_VERSION" == "latest" ]]; then
        if ((ASSUME_YES)); then
            PIN_VERSION=0
        elif ask_yes_no "安装后将当前 Docker 版本加入版本锁定？" "n"; then
            PIN_VERSION=1
        fi
    elif ((ASSUME_YES)); then
        PIN_VERSION=1
    elif ask_yes_no "锁定已选择的 Docker 版本，防止 apt/dnf upgrade 自动升级？" "y"; then
        PIN_VERSION=1
    fi
}

package_is_installed() {
    local package="$1"
    local status=""
    case "$PKG_MANAGER" in
        apt)
            status="$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)"
            [[ "$status" == *" ok installed" ]]
            ;;
        dnf|yum)
            rpm -q "$package" >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

installed_docker_package_names() {
    local package=""
    local candidates=(
        docker-ce
        docker-ce-cli
        containerd.io
        docker-ce-rootless-extras
        docker-buildx-plugin
    )

    for package in "${candidates[@]}"; do
        package_is_installed "$package" && printf '%s\n' "$package"
    done
    return 0
}

apply_version_lock() {
    local -a packages=()

    ((PIN_VERSION)) || return 0
    mapfile -t packages < <(installed_docker_package_names)
    ((${#packages[@]})) || die "未找到可锁定的 Docker 软件包"

    local package_list=""
    package_list="$(printf '%s ' "${packages[@]}")"
    info "锁定 Docker 软件包版本: ${package_list% }"
    case "$PKG_MANAGER" in
        apt)
            run_sudo apt-mark hold "${packages[@]}"
            ;;
        dnf)
            if ! dnf versionlock list >/dev/null 2>&1; then
                info "安装 DNF versionlock 插件"
                run_sudo dnf install -y python3-dnf-plugin-versionlock
            fi
            run_sudo dnf versionlock add "${packages[@]}"
            ;;
        yum)
            if ! yum versionlock list >/dev/null 2>&1; then
                info "安装 YUM versionlock 插件"
                run_sudo yum install -y yum-plugin-versionlock
            fi
            run_sudo yum versionlock add "${packages[@]}"
            ;;
    esac
}

unlock_docker_versions() {
    local -a packages=()
    local package_list=""

    mapfile -t packages < <(installed_docker_package_names)
    ((${#packages[@]})) || return 0

    case "$PKG_MANAGER" in
        apt)
            if command -v apt-mark >/dev/null 2>&1; then
                package_list="$(printf '%s ' "${packages[@]}")"
                info "解除 APT 版本锁定: ${package_list% }"
                run_sudo apt-mark unhold "${packages[@]}"
            fi
            ;;
        dnf|yum)
            if "$PKG_MANAGER" versionlock list >/dev/null 2>&1; then
                package_list="$(printf '%s ' "${packages[@]}")"
                info "解除 versionlock: ${package_list% }"
                run_sudo "$PKG_MANAGER" versionlock delete "${packages[@]}"
            else
                warn "未安装 versionlock 插件，没有可解除的锁定"
            fi
            ;;
    esac
}

compose_binary_arch() {
    case "$ARCH_RAW" in
        x86_64|amd64) printf 'x86_64' ;;
        aarch64|arm64) printf 'aarch64' ;;
        armv7l|armhf) printf 'armv7' ;;
        ppc64le) printf 'ppc64le' ;;
        s390x) printf 's390x' ;;
        *) die "Docker Compose $COMPOSE_VERSION 不支持当前架构: $ARCH_RAW" ;;
    esac
}

compose_binary_sha256() {
    case "$ARCH_RAW" in
        x86_64|amd64) printf '%s' 'ddc876fe2a89d5b7ea455146b0975bfe52904eecba9b192193377d6f99d69ad9' ;;
        aarch64|arm64) printf '%s' '16e93b9c2fc147d29ca1acbb8ceab6a50a0e26af777f43dc7a753cb883142617' ;;
        armv7l|armhf) printf '%s' '9dcfa9523dc912370417b7ccc3d81900bbb98dd9addbff0d218398bbe9078bbd' ;;
        ppc64le) printf '%s' 'f351bfdbb6bb9d18b33672ccba6dd31c53a3bd1b81f9e9052fc6d9125e7d5719' ;;
        s390x) printf '%s' '6f4b6bb51987b2f61b91cfe4017a8d162e86b82ba3ae074b99b06a1ebe4387ed' ;;
        *) die "没有该架构的 Compose 校验值: $ARCH_RAW" ;;
    esac
}

installed_compose_version() {
    local version=""
    version="$("$COMPOSE_PLUGIN_PATH" version --short 2>/dev/null || true)"
    printf '%s' "${version#v}"
}

remove_compose_packages() {
    local removed=0

    if package_is_installed docker-compose-plugin; then
        warn "检测到包管理器安装的 docker-compose-plugin，将改用固定版本二进制。"
        if ((!ASSUME_YES)) &&
           ! ask_yes_no "是否移除 docker-compose-plugin 包（保留 Docker 引擎）？" "y"; then
            die "需要先移除冲突的 Compose 插件包"
        fi
        case "$PKG_MANAGER" in
            apt)
                run_sudo env DEBIAN_FRONTEND=noninteractive \
                    apt-get remove -y docker-compose-plugin
                ;;
            dnf|yum)
                run_sudo "$PKG_MANAGER" remove -y docker-compose-plugin
                ;;
        esac
        removed=1
    fi

    if ((!removed)) && package_is_installed docker-compose; then
        warn "检测到包管理器安装的旧版 docker-compose；/usr/local/bin 中的固定版本会优先使用。"
    fi
}

install_compose_binary() {
    local compose_arch=""
    local checksum=""
    local actual=""
    local url=""
    local tmp=""

    ((INSTALL_COMPOSE)) || return 0
    compose_arch="$(compose_binary_arch)"
    checksum="$(compose_binary_sha256)"

    if [[ -x "$COMPOSE_PLUGIN_PATH" ]] &&
       [[ "$(installed_compose_version)" == "${COMPOSE_VERSION#v}" ]]; then
        info "Docker Compose $COMPOSE_VERSION 已安装"
    else
        tmp="$(mktemp)"
        cleanup_files+=("$tmp")

        if ((DRY_RUN)); then
            printf '%s[试运行]%s curl 下载 %s/%s/docker-compose-linux-%s\n' \
                "$c_yellow" "$c_reset" "$COMPOSE_PROXY_BASE" "$COMPOSE_VERSION" "$compose_arch" >&2
            printf '%s[试运行]%s 校验 SHA-256、安装到 %s，并创建 %s 链接\n' \
                "$c_yellow" "$c_reset" "$COMPOSE_PLUGIN_PATH" "$COMPOSE_COMMAND_PATH" >&2
            return
        fi

        remove_compose_packages
        for url in \
            "$COMPOSE_PROXY_BASE/$COMPOSE_VERSION/docker-compose-linux-$compose_arch" \
            "$COMPOSE_OFFICIAL_BASE/$COMPOSE_VERSION/docker-compose-linux-$compose_arch"; do
            info "下载 Docker Compose: $url"
            if curl -fL --retry 2 --connect-timeout 10 --max-time 300 \
                --silent --show-error -o "$tmp" "$url"; then
                break
            fi
            warn "下载失败，尝试下一个地址"
        done

        actual="$(sha256sum "$tmp" | awk '{print $1}')"
        [[ "$actual" == "$checksum" ]] ||
            die "Docker Compose SHA-256 校验失败。期望 $checksum，实际 $actual"

        backup_file "$COMPOSE_PLUGIN_PATH"
        backup_file "$COMPOSE_COMMAND_PATH"
        run_sudo install -D -m 0755 "$tmp" "$COMPOSE_PLUGIN_PATH"
        run_sudo ln -sfn "$COMPOSE_PLUGIN_PATH" "$COMPOSE_COMMAND_PATH"
    fi

    if ((DRY_RUN)); then
        return
    fi
    if [[ ! -e "$COMPOSE_COMMAND_PATH" ||
          "$(readlink "$COMPOSE_COMMAND_PATH" 2>/dev/null || true)" != "$COMPOSE_PLUGIN_PATH" ]]; then
        run_sudo ln -sfn "$COMPOSE_PLUGIN_PATH" "$COMPOSE_COMMAND_PATH"
    fi
    [[ "$(installed_compose_version)" == "${COMPOSE_VERSION#v}" ]] ||
        die "Docker Compose 安装后版本不是 $COMPOSE_VERSION"
    info "Docker Compose $COMPOSE_VERSION 安装完成"
}

install_docker_packages() {
    local packages=()
    local version="$SELECTED_VERSION"

    case "$PKG_MANAGER" in
        apt)
            if [[ "$version" == "latest" ]]; then
                packages=(docker-ce docker-ce-cli containerd.io)
            else
                packages=("docker-ce=$version" "docker-ce-cli=$version" containerd.io)
            fi
            ((INSTALL_BUILDX)) && packages+=(docker-buildx-plugin)

            info "通过 APT 安装 Docker CE"
            run_sudo env DEBIAN_FRONTEND=noninteractive \
                apt-get install -y --no-install-recommends --allow-downgrades "${packages[@]}"
            ;;
        dnf|yum)
            if [[ "$version" == "latest" ]]; then
                packages=(docker-ce docker-ce-cli containerd.io)
            else
                packages=("docker-ce-$version" "docker-ce-cli-$version" containerd.io)
            fi
            ((INSTALL_BUILDX)) && packages+=(docker-buildx-plugin)

            info "通过 $PKG_MANAGER 安装 Docker CE"
            if [[ "$PKG_MANAGER" == "dnf" ]]; then
                run_sudo dnf install -y --setopt=install_weak_deps=False "${packages[@]}"
            else
                run_sudo yum install -y "${packages[@]}"
            fi
            ;;
    esac
}

json_escape() {
    local value="$1"
    case "$value" in
        *$'\n'*|*$'\r'*|*$'\t'*) die "JSON 输入不能包含换行或制表符" ;;
    esac
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
}

json_string_array() {
    local input="$1"
    local -a items=()
    local item=""
    local escaped=""
    local first=1

    IFS=',' read -r -a items <<<"$input"
    printf '['
    for item in "${items[@]}"; do
        item="$(trim "$item")"
        [[ -n "$item" ]] || continue
        ((first)) || printf ', '
        escaped="$(json_escape "$item")"
        printf '"%s"' "$escaped"
        first=0
    done
    printf ']'
}

validate_mirror_list() {
    local input="$1"
    local -a items=()
    local item=""

    IFS=',' read -r -a items <<<"$input"
    for item in "${items[@]}"; do
        item="$(trim "$item")"
        [[ -n "$item" ]] || continue
        [[ "$item" =~ ^https?://[^[:space:]]+$ ]] ||
            die "镜像加速器必须是有效的 http(s) URL: $item"
    done
}

validate_insecure_list() {
    local input="$1"
    local -a items=()
    local item=""

    IFS=',' read -r -a items <<<"$input"
    for item in "${items[@]}"; do
        item="$(trim "$item")"
        [[ -n "$item" ]] || continue
        [[ "$item" =~ ^(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9._-]+)(:[0-9]+)?$ ]] ||
            die "非安全镜像仓库格式应为 registry.example.com[:port]: $item"
    done
}

validate_json_file() {
    local file="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 -m json.tool "$file" >/dev/null
    elif command -v jq >/dev/null 2>&1; then
        jq empty "$file"
    else
        warn "未找到 python3 或 jq，跳过 daemon.json 的 JSON 语法检查"
    fi
}

write_daemon_config() {
    local mode="$1"
    local data_root=""
    local mirrors=""
    local insecure_registries=""
    local tmp=""

    case "$mode" in
        skip)
            info "保留现有 daemon.json（如果存在）"
            return
            ;;
        keep)
            if [[ -f "$DAEMON_JSON" ]]; then
                info "保留现有 daemon.json"
            else
                warn "daemon.json 不存在，将创建默认配置"
                mode="default"
            fi
            [[ "$mode" == "keep" ]] && return
            ;;
    esac

    if ((ASSUME_YES)); then
        data_root="/var/lib/docker"
        mirrors="https://docker.mirrors.ustc.edu.cn,https://docker.m.daocloud.io"
        insecure_registries="example.com:5000"
    else
        data_root="$(read_input "Docker 数据目录" "/var/lib/docker")"
        mirrors="$(read_input "镜像加速器（逗号分隔，留空表示不使用）" \
            "https://docker.mirrors.ustc.edu.cn,https://docker.m.daocloud.io")"
        insecure_registries="$(read_input "非安全镜像仓库（逗号分隔，留空表示不使用）" \
            "example.com:5000")"
    fi

    if [[ -z "$data_root" || "$data_root" != /* ]]; then
        die "Docker 数据目录必须是绝对路径: $data_root"
    fi
    validate_mirror_list "$mirrors"
    validate_insecure_list "$insecure_registries"
    if [[ -n "$data_root" ]] && ! command -v python3 >/dev/null 2>&1; then
        case "$data_root" in
            *\"*|*\\*) die "数据目录包含需要 JSON 转义的字符，请安装 python3 后重试" ;;
        esac
    fi

    tmp="$(mktemp)"
    cleanup_files+=("$tmp")
    {
        printf '{\n'
        printf '  "data-root": "%s",\n' "$(json_escape "$data_root")"
        printf '  "features": {\n'
        printf '    "containerd-snapshotter": false\n'
        printf '  },\n'
        printf '  "registry-mirrors": %s,\n' "$(json_string_array "$mirrors")"
        printf '  "insecure-registries": %s,\n' "$(json_string_array "$insecure_registries")"
        printf '  "live-restore": true,\n'
        printf '  "exec-opts": ["native.cgroupdriver=systemd"],\n'
        printf '  "log-driver": "json-file",\n'
        printf '  "log-opts": {\n'
        printf '    "max-size": "100m",\n'
        printf '    "max-file": "10"\n'
        printf '  }\n'
        printf '}\n'
    } >"$tmp"

    validate_json_file "$tmp" || die "生成的 daemon.json 不是有效 JSON"
    backup_file "$DAEMON_JSON"
    run_sudo install -d -m 0755 /etc/docker
    run_sudo install -m 0644 "$tmp" "$DAEMON_JSON"
    info "已写入 $DAEMON_JSON"
}

choose_daemon_config() {
    local mode="$USER_DAEMON_MODE"
    local choice=""

    section "Docker daemon 配置"
    if [[ -f "$DAEMON_JSON" ]]; then
        warn "检测到现有配置: $DAEMON_JSON"
        if [[ -z "$mode" ]]; then
            cat <<'EOF'
  1) 备份现有文件并替换为默认配置
  2) 保留现有配置
  3) 跳过配置处理
EOF
            choice="$(read_input "请选择" "2")"
            case "$choice" in
                1) mode="default" ;;
                2) mode="keep" ;;
                3) mode="skip" ;;
                *) die "无效选择: $choice" ;;
            esac
        fi
    else
        mode="${mode:-default}"
        if [[ "$mode" == "keep" ]]; then
            mode="default"
        fi
    fi

    write_daemon_config "$mode"
}

configure_systemd_and_user() {
    local current_user="${SUDO_USER:-${USER:-}}"
    local add_group=0
    local enable_service=1

    if ! command -v systemctl >/dev/null 2>&1; then
        warn "未找到 systemctl，跳过服务启用和启动"
        return
    fi

    section "系统服务与用户权限"
    if ((!ASSUME_YES)); then
        if ! ask_yes_no "设置 Docker 开机启动并立即启动？" "y"; then
            enable_service=0
        fi
        if [[ -n "$current_user" && "$current_user" != "root" ]] &&
           ask_yes_no "将用户 $current_user 加入 docker 组（需重新登录生效）？" "y"; then
            add_group=1
        fi
    else
        add_group=1
    fi

    if ((enable_service)); then
        run_sudo systemctl daemon-reload
        run_sudo systemctl enable docker
        # Package installation can auto-start Docker before daemon.json is
        # written, so restart is required to apply the new configuration.
        run_sudo systemctl restart docker
    fi

    if ((add_group)); then
        if getent group docker >/dev/null 2>&1; then
            if [[ -n "$current_user" && "$current_user" != "root" ]]; then
                run_sudo usermod -aG docker "$current_user" || warn "加入 docker 组失败，可稍后手动执行"
                warn "docker 组权限等同于 root，请仅在可信环境中使用。重新登录后生效。"
            fi
        else
            warn "docker 组尚不存在；安装完成后可手动重新运行此步骤"
        fi
    fi
}

verify_installation() {
    [[ "$PKG_MANAGER" == "apt" || "$PKG_MANAGER" == "dnf" || "$PKG_MANAGER" == "yum" ]] || return

    section "安装结果验证"
    if ((DRY_RUN)); then
        info "试运行模式：跳过实际版本和容器验证"
        return
    fi

    run_sudo docker --version
    if ! run_sudo docker info >/dev/null 2>&1; then
        warn "Docker 服务当前未运行，跳过服务端和插件验证。"
        return
    fi
    run_sudo docker version
    if ((INSTALL_BUILDX)); then
        run_sudo docker buildx version
    fi
    if ((INSTALL_COMPOSE)); then
        run_sudo docker compose version
    fi

    if ((INSTALL_VERIFY)); then
        if ask_yes_no "运行 hello-world 容器验证 Docker 是否能正常工作？" "y"; then
            run_sudo docker run --rm hello-world
        fi
    fi
}

remove_compose_binary() {
    local removed_any=0

    if [[ -e "$COMPOSE_COMMAND_PATH" || -L "$COMPOSE_COMMAND_PATH" ]]; then
        run_sudo rm -f -- "$COMPOSE_COMMAND_PATH"
        removed_any=1
    fi
    if [[ -e "$COMPOSE_PLUGIN_PATH" || -L "$COMPOSE_PLUGIN_PATH" ]]; then
        run_sudo rm -f -- "$COMPOSE_PLUGIN_PATH"
        removed_any=1
    fi

    if ((removed_any)); then
        info "已移除 Docker Compose 二进制及其命令链接"
    else
        info "未发现脚本安装的 Docker Compose 二进制"
    fi
}

uninstall_docker_engine() {
    local -a candidates=(
        docker-ce
        docker-ce-cli
        containerd.io
        docker-ce-rootless-extras
        docker-buildx-plugin
        docker-compose-plugin
    )
    local -a packages=()
    local package=""
    local package_list=""

    for package in "${candidates[@]}"; do
        package_is_installed "$package" && packages+=("$package")
    done
    ((${#packages[@]})) || warn "未发现 Docker CE 软件包"

    if command -v systemctl >/dev/null 2>&1 &&
       systemctl list-unit-files docker.service >/dev/null 2>&1; then
        run_sudo systemctl disable --now docker ||
            warn "停止 docker.service 失败，继续卸载软件包"
    fi

    if ((${#packages[@]})); then
        unlock_docker_versions
        package_list="$(printf '%s ' "${packages[@]}")"
        info "卸载 Docker 软件包: ${package_list% }"
        case "$PKG_MANAGER" in
            apt)
                run_sudo env DEBIAN_FRONTEND=noninteractive \
                    apt-get remove -y "${packages[@]}"
                ;;
            dnf|yum)
                run_sudo "$PKG_MANAGER" remove -y "${packages[@]}"
                ;;
        esac
    fi

    if ((ASSUME_YES)) ||
       ask_yes_no "是否移除脚本配置的 Docker 软件源和 GPG 密钥？" "y"; then
        case "$PKG_MANAGER" in
            apt)
                run_sudo rm -f -- "$DOCKER_REPO_FILE" "$DOCKER_KEYRING"
                ;;
            dnf|yum)
                run_sudo rm -f -- "$DOCKER_YUM_REPO"
                ;;
        esac
        info "已移除 Docker 软件源配置"
    fi

    if [[ -f "$DAEMON_JSON" ]] &&
       ! ((ASSUME_YES)) &&
       ask_yes_no "是否备份并移除 $DAEMON_JSON？" "n"; then
        backup_file "$DAEMON_JSON"
        run_sudo rm -f -- "$DAEMON_JSON"
        info "已移除 daemon.json"
    fi

    info "Docker 镜像、容器和卷数据仍保留在原 data-root 目录中。"
}

run_uninstall() {
    local choice=""
    local remove_engine=0
    local remove_compose=0

    section "Docker 卸载"
    cat <<'EOF'
  1) 卸载 Docker 引擎、Docker Compose 和脚本配置的软件源
  2) 仅卸载 Docker Compose 二进制
  3) 仅卸载 Docker 引擎和脚本配置的软件源
EOF
    if ((ASSUME_YES)); then
        choice="1"
    else
        choice="$(read_input "请选择卸载范围" "1")"
    fi

    case "$choice" in
        1)
            remove_engine=1
            remove_compose=1
            ;;
        2)
            remove_compose=1
            ;;
        3)
            remove_engine=1
            ;;
        *)
            die "无效选择: $choice"
            ;;
    esac

    confirm_or_exit "确认执行所选卸载操作？"
    ((remove_compose)) && remove_compose_binary
    ((remove_engine)) && uninstall_docker_engine

    section "卸载完成"
    info "Docker 数据目录默认未被删除；Docker 组和组内用户也未被修改。"
}

show_plan() {
    local version_text="$SELECTED_VERSION"
    local docker_status="未安装"

    command -v docker >/dev/null 2>&1 && docker_status="已安装（将根据版本选择处理）"
    [[ "$version_text" == "latest" ]] && version_text="仓库最新版本"

    section "安装计划"
    printf '  系统:       %s\n' "$OS_PRETTY"
    printf '  架构:       %s\n' "$ARCH"
    printf '  软件源:     %s\n' "$REPO_SOURCE_NAME"
    if [[ -n "$REPO_BASE" ]]; then
        printf '  仓库路径:   %s/%s\n' "$REPO_BASE" "$REPO_DISTRO"
    fi
    printf '  Docker:     %s，目标版本 %s\n' "$docker_status" "$version_text"
    printf '  Compose:    %s\n' "$( ((INSTALL_COMPOSE)) && echo "安装 $COMPOSE_VERSION 二进制" || echo '不安装' )"
    printf '  Buildx:     %s\n' "$( ((INSTALL_BUILDX)) && echo '安装' || echo '不安装' )"
    printf '  版本锁定:   %s\n' "$( ((PIN_VERSION)) && echo '启用（阻止 apt/dnf 自动升级）' || echo '未启用' )"
    printf '  daemon.json:%s\n' " $DAEMON_JSON（文件存在时先备份）"
    ((DRY_RUN)) && printf '  模式:       试运行，不修改系统\n'
    printf '\n'
}

main() {
    parse_args "$@"
    detect_os
    detect_package_manager

    if [[ "$ACTION" == "unlock" ]]; then
        ensure_root_access
        section "解除 Docker 版本锁定"
        unlock_docker_versions
        info "版本锁定已解除，后续 apt/dnf upgrade 可以升级 Docker。"
        exit 0
    fi

    if [[ "$ACTION" == "uninstall" ]]; then
        ensure_root_access
        show_detection
        run_uninstall
        exit 0
    fi

    detect_repo_platform

    if ((DETECT_ONLY)); then
        show_detection
        exit 0
    fi

    show_detection
    ensure_root_access
    choose_repository

    if [[ -n "$USER_VERSION" ]]; then
        SELECTED_VERSION="$USER_VERSION"
    fi

    # Refreshing source metadata is a system change, so ask before doing it.
    if [[ "$USER_SOURCE" != "existing" ]]; then
        confirm_or_exit "将先配置「$REPO_SOURCE_NAME」并刷新软件包索引，是否继续？"
        configure_repository
    else
        warn "将直接查询并安装系统现有 Docker 源中的版本。"
    fi

    choose_version_from_list
    handle_conflicting_packages
    show_installed_docker
    choose_components
    choose_version_pin
    show_plan
    confirm_or_exit "确认开始安装并修改系统？"

    install_docker_packages
    install_compose_binary
    apply_version_lock
    choose_daemon_config
    configure_systemd_and_user
    verify_installation

    section "完成"
    if ((DRY_RUN)); then
        info "试运行结束，未修改系统。"
    else
        info "Docker CE 安装流程已完成。"
        docker version 2>/dev/null || true
        info "要立即刷新 docker 组权限，可运行: newgrp docker（或重新登录）。"
    fi
}

main "$@"
