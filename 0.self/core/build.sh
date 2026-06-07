#!/bin/bash
# build.sh — M7 QCOW2 镜像构建脚本 v0.3
# 目标环境: GitHub Codespaces (Ubuntu 22.04/24.04) 或本地 Linux
# 产出: 0.self/core/m7-alpine.qcow2
#
# 用法:
#   sudo bash build.sh                       # 完整构建
#   ALPINE_VERSION=3.20 sudo bash build.sh   # 指定 Alpine 版本
#   IMAGE_SIZE_MB=512 sudo bash build.sh     # 指定镜像大小
set -euo pipefail

# ─── 配置 ───
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
M7_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/_build"
OUTPUT="$SCRIPT_DIR/m7-alpine.qcow2"

ALPINE_VERSION="${ALPINE_VERSION:-3.20}"
ALPINE_ARCH="${ALPINE_ARCH:-x86_64}"
ALPINE_PATCH="${ALPINE_PATCH:-3}"   # 3.20.3
ALPINE_TARBALL="/tmp/alpine-minirootfs-${ALPINE_VERSION}.${ALPINE_PATCH}-${ALPINE_ARCH}.tar.gz"
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/${ALPINE_ARCH}/alpine-minirootfs-${ALPINE_VERSION}.${ALPINE_PATCH}-${ALPINE_ARCH}.tar.gz"
ALPINE_REPO_BASE="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}"

KERNEL_PKG="linux-virt"   # virt 内核更小，更适合 QEMU
IMAGE_SIZE_MB="${IMAGE_SIZE_MB:-1024}"

# ─── 颜色 ───
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[BUILD]${NC} $*"; }
info() { echo -e "${CYAN}[BUILD]${NC} $*"; }
warn() { echo -e "${YELLOW}[BUILD-WARN]${NC} $*"; }
err()  { echo -e "${RED}[BUILD-ERR]${NC} $*" >&2; cleanup_on_error; exit 1; }

# ─── 错误清理 ───
cleanup_on_error() {
    if [ -d "$BUILD_DIR/mnt" ]; then
        sudo umount -l "$BUILD_DIR/mnt/dev/pts" 2>/dev/null || true
        sudo umount -l "$BUILD_DIR/mnt/dev"     2>/dev/null || true
        sudo umount -l "$BUILD_DIR/mnt/sys"     2>/dev/null || true
        sudo umount -l "$BUILD_DIR/mnt/proc"    2>/dev/null || true
        sudo umount -l "$BUILD_DIR/mnt"         2>/dev/null || true
    fi
    if [ -f "$BUILD_DIR/.loop_dev" ]; then
        sudo losetup -d "$(cat "$BUILD_DIR/.loop_dev")" 2>/dev/null || true
    fi
}
trap cleanup_on_error EXIT

# ─── 依赖检查 + 自动安装 (Ubuntu) ───
ensure_deps() {
    log "Checking host dependencies..."
    local missing=()
    for cmd in qemu-img mkfs.ext4 losetup mount umount extlinux wget; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if [ ${#missing[@]} -ne 0 ]; then
        warn "Missing: ${missing[*]}"
        if command -v apt-get >/dev/null 2>&1; then
            log "Installing missing packages via apt-get..."
            sudo apt-get update -qq
            sudo apt-get install -y -qq \
                qemu-utils qemu-system-x86 \
                e2fsprogs util-linux \
                extlinux syslinux syslinux-common \
                wget ca-certificates \
                || err "apt-get install failed"
        else
            err "apt-get not available; install manually: ${missing[*]}"
        fi
    fi
    log "All host dependencies satisfied."
}

# ─── 下载 Alpine minirootfs ───
fetch_alpine() {
    if [ -f "$ALPINE_TARBALL" ] && [ -s "$ALPINE_TARBALL" ]; then
        log "Alpine minirootfs already present: $ALPINE_TARBALL"
        return
    fi
    log "Downloading Alpine ${ALPINE_VERSION}.${ALPINE_PATCH} minirootfs..."
    info "URL: $ALPINE_URL"
    wget -q --show-progress -O "$ALPINE_TARBALL.tmp" "$ALPINE_URL" \
        || err "Failed to download Alpine minirootfs from $ALPINE_URL"
    mv "$ALPINE_TARBALL.tmp" "$ALPINE_TARBALL"
    log "Alpine minirootfs ready ($(du -h "$ALPINE_TARBALL" | cut -f1))"
}

# ─── 申请 loop 设备 ───
acquire_loop() {
    local img="$1"
    local dev
    dev=$(sudo losetup -f 2>/dev/null) || true
    if [ -z "$dev" ]; then
        for i in $(seq 8 31); do
            [ -e "/dev/loop${i}" ] || sudo mknod "/dev/loop${i}" b 7 "${i}" 2>/dev/null || true
            if ! sudo losetup "/dev/loop${i}" 2>/dev/null | grep -q .; then
                dev="/dev/loop${i}"; break
            fi
        done
    fi
    [ -n "$dev" ] || err "No free loop device available"
    sudo losetup --show "$dev" "$img"
}

# ─── Phase 1: 创建磁盘镜像 ───
create_image() {
    log "Phase 1: Creating disk image (${IMAGE_SIZE_MB}MB)..."
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    qemu-img create -f raw m7.raw "${IMAGE_SIZE_MB}M" >/dev/null

    log "Formatting ext4 (no partition)..."
    sudo mkfs.ext4 -q -L M7_ROOT m7.raw

    log "Attaching loop device..."
    LOOP_DEV=$(acquire_loop m7.raw)
    log "Loop device: $LOOP_DEV"
    echo "$LOOP_DEV" > "$BUILD_DIR/.loop_dev"

    mkdir -p mnt
    sudo mount "$LOOP_DEV" mnt
}

# ─── Phase 2: 安装 Alpine Linux ───
install_alpine() {
    log "Phase 2: Extracting Alpine minirootfs..."
    cd "$BUILD_DIR"
    sudo tar xzf "$ALPINE_TARBALL" -C mnt

    log "Configuring Alpine /etc/apk/repositories..."
    sudo mkdir -p mnt/etc/apk
    sudo tee mnt/etc/apk/repositories > /dev/null <<EOF
${ALPINE_REPO_BASE}/main
${ALPINE_REPO_BASE}/community
EOF

    log "Configuring DNS for chroot..."
    sudo cp /etc/resolv.conf mnt/etc/resolv.conf

    log "Preparing chroot mounts..."
    sudo mount -t proc  none mnt/proc
    sudo mount -t sysfs none mnt/sys
    sudo mount --bind /dev      mnt/dev
    sudo mount --bind /dev/pts  mnt/dev/pts 2>/dev/null || true

    log "Installing kernel + base packages inside chroot..."
    sudo chroot mnt /bin/sh -c "
        set -e
        apk update
        apk add ${KERNEL_PKG} alpine-base openrc busybox-extras
        apk add curl jq lighttpd lighttpd-mod_auth python3 py3-yaml
        apk add bash
    " || err "apk install failed inside chroot"

    # 清理 chroot 挂载（注意顺序）
    log "Unmounting chroot bind mounts..."
    sudo umount -l mnt/dev/pts 2>/dev/null || true
    sudo umount -l mnt/dev     2>/dev/null || true
    sudo umount -l mnt/sys     2>/dev/null || true
    sudo umount -l mnt/proc    2>/dev/null || true

    log "Alpine base + M7 dependencies installed."
}

# ─── Phase 3: 配置引导 ───
setup_boot() {
    log "Phase 3: Setting up extlinux bootloader..."
    cd "$BUILD_DIR"

    sudo mkdir -p mnt/boot/extlinux

    # extlinux 模块
    sudo extlinux --install mnt/boot/extlinux

    # 写入 MBR (多路径回退)
    local MBR_BIN=""
    for p in \
        /usr/lib/syslinux/mbr/mbr.bin \
        /usr/lib/syslinux/modules/bios/mbr.bin \
        /usr/lib/EXTLINUX/mbr.bin \
        /usr/share/syslinux/mbr.bin; do
        [ -f "$p" ] && { MBR_BIN="$p"; break; }
    done
    if [ -n "$MBR_BIN" ]; then
        local LOOP_DEV
        LOOP_DEV=$(cat .loop_dev)
        sudo dd if="$MBR_BIN" of="$LOOP_DEV" bs=440 count=1 conv=notrunc 2>/dev/null || true
        log "MBR written from $MBR_BIN"
    else
        warn "No MBR binary found; image may not boot from BIOS"
    fi

    log "Writing extlinux.conf..."
    sudo tee mnt/boot/extlinux/extlinux.conf > /dev/null <<'EXTEOF'
DEFAULT m7
TIMEOUT 10
PROMPT 0

LABEL m7
  MENU LABEL MANIFOLD-7
  LINUX /boot/vmlinuz-virt
  INITRD /boot/initramfs-virt
  APPEND root=LABEL=M7_ROOT rw console=ttyS0,115200 console=tty0 modules=ext4 quiet
EXTEOF

    log "Bootloader configured."
}

# ─── Phase 4: 注入 M7 运行时 ───
inject_m7() {
    log "Phase 4: Injecting M7 runtime..."
    cd "$BUILD_DIR"

    sudo mkdir -p mnt/opt/m7/{core,executer,usages,runners,www/cgi-bin}

    # ─── 复制宿主机的 engine.py (单一来源) ───
    log "Copying engine.py from host..."
    sudo cp "$M7_ROOT/0.self/core/engine.py" mnt/opt/m7/core/engine.py
    sudo chmod +x mnt/opt/m7/core/engine.py

    # 在 VM 中, runner 配置位于 /opt/m7/runners/ — engine.py 已支持该路径

    # ─── 复制 runner 配置 ───
    log "Copying runner configs..."
    if [ -d "$M7_ROOT/1.runner" ]; then
        sudo cp "$M7_ROOT"/1.runner/*.yaml mnt/opt/m7/runners/ 2>/dev/null || true
    fi

    # ─── 复制 usage 文件 ───
    log "Copying usage files..."
    if [ -d "$M7_ROOT/2.usages" ]; then
        sudo cp "$M7_ROOT"/2.usages/*.m7 mnt/opt/m7/usages/ 2>/dev/null || true
    fi

    # ─── CGI 入口: /cgi-bin/m7 ───
    log "Writing CGI handler..."
    sudo tee mnt/opt/m7/www/cgi-bin/m7 > /dev/null <<'CGIEOF'
#!/bin/sh
# M7 CGI handler — 解析 QUERY_STRING, 调用 engine.py, 然后真实调用外部模型 API
# 输入:  GET /cgi-bin/m7?usage=sendEmail&runner=deepseek&recipient=a@b.com&...
# 输出:  application/json
#
# API Key 通过 HTTP Header 传入: X-M7-Api-Key: sk-xxx
# 或从 /etc/m7/api_key 文件读取
set -e

printf 'Content-Type: application/json\r\n\r\n'

# ─── 解析 QUERY_STRING (POSIX 兼容 urldecode) ───
urldecode() {
    # 用 awk 处理百分号编码 (busybox awk 兼容)
    printf '%s' "$1" | awk 'BEGIN{
        for(i=0;i<256;i++) hex[sprintf("%02X",i)]=sprintf("%c",i);
        for(i=0;i<256;i++) hex[sprintf("%02x",i)]=sprintf("%c",i);
    }{
        gsub(/\+/," ");
        while(match($0,/%[0-9A-Fa-f][0-9A-Fa-f]/)){
            c=hex[substr($0,RSTART+1,2)];
            $0=substr($0,1,RSTART-1) c substr($0,RSTART+3);
        }
        printf "%s",$0;
    }'
}

QS="${QUERY_STRING:-}"
USAGE=""; RUNNER=""; PARAMS=""

OLD_IFS="$IFS"
IFS='&'
for pair in $QS; do
    key="${pair%%=*}"
    val="${pair#*=}"
    val=$(urldecode "$val")
    case "$key" in
        usage)  USAGE="$val" ;;
        runner) RUNNER="$val" ;;
        *)      PARAMS="$PARAMS $key=$val" ;;
    esac
done
IFS="$OLD_IFS"

if [ -z "$USAGE" ] || [ -z "$RUNNER" ]; then
    printf '{"error":"missing usage or runner","query":"%s"}\n' "$QS"
    exit 0
fi

# ─── 调用 engine.py ───
ENGINE_OUTPUT=$(python3 /opt/m7/core/engine.py "$USAGE" "$RUNNER" $PARAMS 2>&1) || {
    printf '{"error":"engine failed","detail":%s}\n' "$(printf '%s' "$ENGINE_OUTPUT" | jq -R -s .)"
    exit 0
}

# 如 engine 返回 error, 直接透传
if echo "$ENGINE_OUTPUT" | grep -q '"error"'; then
    echo "$ENGINE_OUTPUT"
    exit 0
fi

INTENT=$(echo "$ENGINE_OUTPUT"   | jq -r '.intent')
MODEL=$(echo "$ENGINE_OUTPUT"    | jq -r '.model')
ENDPOINT=$(echo "$ENGINE_OUTPUT" | jq -r '.endpoint')
PROMPT=$(echo "$ENGINE_OUTPUT"   | jq -r '.prompt')

# ─── 获取 API Key (优先级: HTTP header > /etc/m7/api_key > 环境变量) ───
API_KEY="${HTTP_X_M7_API_KEY:-}"
[ -z "$API_KEY" ] && [ -r /etc/m7/api_key ] && API_KEY=$(cat /etc/m7/api_key)
[ -z "$API_KEY" ] && API_KEY="${M7_API_KEY:-}"

if [ -z "$API_KEY" ]; then
    # 没有 key, 返回 M7 编译后的 prompt (供本地调试)
    printf '{"mode":"dry-run","reason":"no api key","engine":%s}\n' "$ENGINE_OUTPUT"
    exit 0
fi

# ─── 调用外部大模型 API ───
REQUEST=$(jq -n \
    --arg model "$MODEL" \
    --arg system "You are an M7 protocol executor. Intent: $INTENT" \
    --arg user "$PROMPT" \
    '{model: $model, messages: [{role:"system",content:$system},{role:"user",content:$user}], stream: false}')

API_RESPONSE=$(curl -s -X POST "$ENDPOINT" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$REQUEST" 2>&1) || API_RESPONSE='{"error":"curl failed"}'

# 组装最终响应
jq -n \
    --argjson engine "$ENGINE_OUTPUT" \
    --argjson api "$(echo "$API_RESPONSE" | jq -c . 2>/dev/null || echo '{"raw":"'"$API_RESPONSE"'"}')" \
    '{engine: $engine, response: $api}'
CGIEOF
    sudo chmod +x mnt/opt/m7/www/cgi-bin/m7

    # ─── 健康检查端点 ───
    sudo tee mnt/opt/m7/www/index.html > /dev/null <<'HTMLEOF'
<!DOCTYPE html>
<html><head><title>M7 VM</title></head>
<body>
<h1>MANIFOLD-7 VM</h1>
<p>Status: <b>online</b></p>
<p>Try: <code>/cgi-bin/m7?usage=sendEmail&runner=deepseek</code></p>
</body></html>
HTMLEOF

    # ─── lighttpd 配置 (启用 CGI) ───
    log "Configuring lighttpd with mod_cgi..."
    sudo mkdir -p mnt/etc/lighttpd
    sudo tee mnt/etc/lighttpd/lighttpd.conf > /dev/null <<'LIGHTEOF'
server.modules = (
    "mod_access",
    "mod_alias",
    "mod_cgi",
    "mod_accesslog",
)

server.document-root = "/opt/m7/www"
server.port          = 8080
server.bind          = "0.0.0.0"
server.username      = "lighttpd"
server.groupname     = "lighttpd"
server.errorlog      = "/var/log/lighttpd/error.log"
accesslog.filename   = "/var/log/lighttpd/access.log"

index-file.names = ("index.html")

mimetype.assign = (
    ".html" => "text/html",
    ".css"  => "text/css",
    ".js"   => "application/javascript",
    ".json" => "application/json"
)

# CGI: /cgi-bin/* 由 shell 直接执行 (脚本本身带 shebang)
alias.url += ( "/cgi-bin/" => "/opt/m7/www/cgi-bin/" )
$HTTP["url"] =~ "^/cgi-bin/" {
    cgi.assign = ( "" => "" )
}
LIGHTEOF
    sudo mkdir -p mnt/var/log/lighttpd
    sudo chmod 755 mnt/opt/m7/www/cgi-bin
    sudo chmod 755 mnt/opt/m7/www/cgi-bin/m7

    log "M7 runtime + CGI injected."
}

# ─── Phase 5: 系统初始化 (网络/服务/串口) ───
finalize() {
    log "Phase 5: Finalizing init / network / services..."
    cd "$BUILD_DIR"

    # 网络: DHCP
    sudo tee mnt/etc/network/interfaces > /dev/null <<'NETEOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
NETEOF

    # 主机名
    echo 'm7-alpine' | sudo tee mnt/etc/hostname > /dev/null

    # /etc/hosts
    sudo tee mnt/etc/hosts > /dev/null <<'HOSTSEOF'
127.0.0.1   localhost m7-alpine
::1         localhost
HOSTSEOF

    # 串口 console
    if ! grep -q 'ttyS0' mnt/etc/inittab 2>/dev/null; then
        echo 'ttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100' | sudo tee -a mnt/etc/inittab > /dev/null
    fi

    # fstab
    sudo tee mnt/etc/fstab > /dev/null <<'FSTABEOF'
LABEL=M7_ROOT  /         ext4    rw,relatime  0  1
proc           /proc     proc    defaults     0  0
sysfs          /sys      sysfs   defaults     0  0
devtmpfs       /dev      devtmpfs defaults    0  0
tmpfs          /tmp      tmpfs   defaults     0  0
FSTABEOF

    # ─── OpenRC 启动项: 把 networking / lighttpd 加入 default runlevel ───
    # 需要在 chroot 内执行
    sudo mount -t proc  none mnt/proc
    sudo mount -t sysfs none mnt/sys
    sudo mount --bind /dev mnt/dev

    log "Enabling OpenRC services..."
    sudo chroot mnt /bin/sh -c "
        set -e
        # 必备 boot 服务
        rc-update add devfs    sysinit 2>/dev/null || true
        rc-update add dmesg    sysinit 2>/dev/null || true
        rc-update add mdev     sysinit 2>/dev/null || true
        rc-update add hwclock  boot    2>/dev/null || true
        rc-update add modules  boot    2>/dev/null || true
        rc-update add sysctl   boot    2>/dev/null || true
        rc-update add hostname boot    2>/dev/null || true
        rc-update add bootmisc boot    2>/dev/null || true
        rc-update add syslog   boot    2>/dev/null || true
        rc-update add mount-ro shutdown 2>/dev/null || true
        rc-update add killprocs shutdown 2>/dev/null || true
        rc-update add savecache shutdown 2>/dev/null || true

        # 网络
        rc-update add networking default

        # M7 主服务
        rc-update add lighttpd  default

        # 自动登录 root (方便调试 — 生产请删除)
        sed -i 's|^root:.*|root::0:0:root:/root:/bin/sh|' /etc/passwd 2>/dev/null || true
    " || warn "Some OpenRC services failed to enable"

    sudo umount -l mnt/dev  2>/dev/null || true
    sudo umount -l mnt/sys  2>/dev/null || true
    sudo umount -l mnt/proc 2>/dev/null || true

    # ─── 清理并卸载 ───
    log "Unmounting root filesystem..."
    sudo umount mnt
    LOOP_DEV=$(cat .loop_dev)
    sudo losetup -d "$LOOP_DEV"
    rm -f .loop_dev

    # ─── 转换为 QCOW2 ───
    log "Converting raw → qcow2 (compressed)..."
    qemu-img convert -f raw -O qcow2 -c m7.raw "$OUTPUT"

    log "QCOW2 image: $OUTPUT"
    qemu-img info "$OUTPUT" | sed 's/^/  /'
    log "Image size: $(du -h "$OUTPUT" | cut -f1)"

    # 清空 trap，构建成功不再触发 cleanup
    trap - EXIT

    rm -rf "$BUILD_DIR"
}

# ─── 主流程 ───
main() {
    echo ""
    echo "╔═══════════════════════════════════════════╗"
    echo "║   MANIFOLD-7  QCOW2  Image Builder  v0.3 ║"
    echo "╚═══════════════════════════════════════════╝"
    echo ""

    if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
        warn "This script needs sudo for losetup/mount/chroot. You may be prompted."
    fi

    ensure_deps
    fetch_alpine
    create_image
    install_alpine
    setup_boot
    inject_m7
    finalize

    echo ""
    echo "✔  Build successful: $OUTPUT"
    echo ""
    echo "   Quick test:"
    echo "     export M7_DEEPSEEK_API_KEY=sk-xxx"
    echo "     $M7_ROOT/m7.sh run sendEmail as deepseek --vm \\"
    echo "         recipient=alice@example.com subject=Hi body_points=Hello,World"
    echo ""
}

main "$@"
