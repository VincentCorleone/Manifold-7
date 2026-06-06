#!/bin/bash
# build.sh — M7 QCOW2 镜像构建脚本 (无分区版本)
# 产出: 0.self/core/m7-alpine.qcow2
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
M7_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/_build"
OUTPUT="$SCRIPT_DIR/m7-alpine.qcow2"
ALPINE_TARBALL="/tmp/alpine-minirootfs.tar.gz"
KERNEL_PKG="linux-lts"
IMAGE_SIZE_MB=1024

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[BUILD]${NC} $*"; }
warn() { echo -e "${YELLOW}[BUILD-WARN]${NC} $*"; }
err()  { echo -e "${RED}[BUILD-ERR]${NC} $*" >&2; exit 1; }

# ─── 辅助: 申请一个可用 loop 设备 ───
acquire_loop() {
    local img="$1"
    # 尝试 losetup -f 自动分配; 如果失败则手动创建设备节点
    local dev
    dev=$(sudo losetup -f 2>/dev/null) || true
    if [ -z "$dev" ]; then
        for i in $(seq 8 31); do
            if [ ! -e "/dev/loop${i}" ]; then
                sudo mknod "/dev/loop${i}" b 7 "${i}" 2>/dev/null || true
            fi
            if ! sudo losetup "/dev/loop${i}" 2>/dev/null | grep -q .; then
                dev="/dev/loop${i}"
                break
            fi
        done
    fi
    [ -n "$dev" ] || err "No free loop device available"
    sudo losetup --show "$dev" "$img"
}

# ─── 依赖检查 ───
check_deps() {
    log "Checking dependencies..."
    for cmd in qemu-img mkfs.ext4 losetup mount umount extlinux; do
        command -v "$cmd" >/dev/null 2>&1 || err "Missing: $cmd"
    done
    [ -f "$ALPINE_TARBALL" ] || err "Alpine minirootfs not found: $ALPINE_TARBALL"
    log "All dependencies satisfied."
}

# ─── Phase 1: 创建磁盘镜像 ───
create_image() {
    log "Phase 1: Creating disk image (${IMAGE_SIZE_MB}MB)..."
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    qemu-img create -f raw m7.raw "${IMAGE_SIZE_MB}M"

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

    log "Configuring Alpine repository..."
    sudo mkdir -p mnt/etc/apk/keys
    sudo cp /etc/resolv.conf mnt/etc/resolv.conf

    log "Installing kernel ($KERNEL_PKG)..."

    # 准备 chroot
    sudo mount -t proc none mnt/proc
    sudo mount -t sysfs none mnt/sys
    sudo mount --bind /dev mnt/dev
    sudo mount --bind /dev/pts mnt/dev/pts 2>/dev/null || true

    sudo chroot mnt /bin/sh -c "
        apk update && apk add ${KERNEL_PKG}
    " || err "Kernel installation failed"

    log "Installing M7 dependencies..."
    sudo chroot mnt /bin/sh -c "
        apk add curl jq lighttpd python3 py3-yaml || true
    " || warn "Some optional packages may not have installed"

    # Alpine Linux IS the Hardware Abstraction Layer.
    # 内核通过 /dev, /sys, /proc 暴露硬件; 无需额外的 Python HAL。
    # 以下为可选硬件加速包 (GPU/NPU/TPU — 按需启用):
    #   apk add mesa-dri-gallium vulkan-loader  # GPU 驱动
    #   apk add linux-firmware                  # 固件
    #   apk add pciutils usbutils               # 设备探测

    # 清理 chroot 挂载
    log "Cleaning up chroot mounts..."
    sudo umount -l mnt/dev/pts 2>/dev/null || true
    sudo umount -l mnt/dev 2>/dev/null || true
    sudo umount -l mnt/sys 2>/dev/null || true
    sudo umount -l mnt/proc 2>/dev/null || true

    log "Alpine base system installed."
}

# ─── Phase 3: 配置引导 ───
setup_boot() {
    log "Phase 3: Setting up extlinux bootloader..."
    cd "$BUILD_DIR"

    sudo mkdir -p mnt/boot/extlinux

    # extlinux --install
    sudo extlinux --install mnt/boot/extlinux 2>/dev/null || {
        warn "extlinux --install failed, trying with MBR..."
        sudo cp /usr/lib/syslinux/mbr/mbr.bin mnt/boot/
        LOOP_DEV=$(cat .loop_dev)
        sudo dd if=/usr/lib/syslinux/mbr/mbr.bin of="$LOOP_DEV" bs=440 count=1 conv=notrunc
        sudo extlinux --install mnt/boot/extlinux
    }

    log "Writing extlinux.conf..."
    sudo tee mnt/boot/extlinux/extlinux.conf > /dev/null <<'EXTEOF'
DEFAULT m7
TIMEOUT 30
PROMPT 1

LABEL m7
  MENU LABEL MANIFOLD-7
  LINUX /boot/vmlinuz-lts
  INITRD /boot/initramfs-lts
  APPEND root=LABEL=M7_ROOT console=ttyS0 console=tty0 quiet modules=ext4
EXTEOF

    log "Bootloader configured."
}

# ─── Phase 4: 注入 M7 运行时 ───
inject_m7() {
    log "Phase 4: Injecting M7 runtime..."
    cd "$BUILD_DIR"

    sudo mkdir -p mnt/opt/m7/{core,executer,usages}

    # M7 核心引擎 (Python) — v0.2 语义压缩
    sudo tee mnt/opt/m7/core/engine.py > /dev/null <<'PYEOF'
#!/usr/bin/env python3
"""M7 Core Engine v0.2 — 协议解析、语义压缩、路由分发"""
import sys, os, json, yaml, re

# ─── M7 压缩协议 ───
FIELD_SEP = "|"
LIST_SEP = ";"

INTENT_MAP = {
    "compose": "COMPOSE", "write": "COMPOSE", "draft": "COMPOSE",
    "email": "EMAIL", "summarize": "SUMM", "summary": "SUMM",
    "translate": "TRANS", "explain": "EXPLAIN", "analyze": "ANALYZE",
    "generate": "GEN", "extract": "EXTRACT", "classify": "CLASS",
    "review": "REVIEW", "rewrite": "REWRITE", "answer": "ANSWER",
    "describe": "DESC",
}

def parse_m7(filepath):
    header, template_lines, in_body = {}, [], False
    with open(filepath) as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("#") or not line.strip():
                continue
            if line.startswith("---"):
                in_body = True
                continue
            if in_body:
                template_lines.append(line)
            elif ":" in line:
                key, val = line.split(":", 1)
                header[key.strip()] = val.strip()
    return header, "\n".join(template_lines).strip()

def load_runner(name):
    path = os.path.join("/opt/m7", "runners", f"{name}.yaml")
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return yaml.safe_load(f)

def render_template(template, params):
    for k, v in params.items():
        template = template.replace(f"{{{{{k}}}}}", str(v))
    return template

# ─── M7 v0.2 语义压缩 ───
def _map_intent(raw):
    lowered = raw.lower()
    for keyword, code in sorted(INTENT_MAP.items(), key=lambda x: -len(x[0])):
        if keyword in lowered:
            return code
    return "GEN"

def _detect_structure(text):
    lowered = text.lower()
    fmt = None
    if "professional" in lowered: fmt = "prof"
    elif "casual" in lowered or "friendly" in lowered: fmt = "casual"
    elif "formal" in lowered: fmt = "formal"
    elif "concise" in lowered or "brief" in lowered: fmt = "brief"
    out_fields = [f for f in ["to","subject","body","from"] if re.search(rf'\b{f}\b', lowered)]
    return fmt, out_fields

def _extract_entities(text):
    entities = {}
    for pat, key in [
        (r'(?i)recipient:\s*([^|]+?)(?:\.\s|$)', 'TO'),
        (r'(?i)subject:\s*([^|]+?)(?:\.\s|$)', 'SUBJ'),
    ]:
        m = re.search(pat, text)
        if m and key not in entities:
            entities[key] = m.group(1).strip().rstrip(',')
    return entities

def _extract_points(text):
    m = re.search(r'(?i)(?:key\s+)?points?\s*(?:to\s*cover)?:\s*(.+?)(?:\.\s*output|\.\s*$|$)', text)
    if not m:
        return []
    items = re.split(r'\s*[,;]\s*|\s+and\s+', m.group(1).strip())
    return [p.strip().rstrip('.') for p in items if p.strip()]

def compress(prompt, intent_hint=None):
    prompt = prompt.strip()
    # Step 1: 清理冗余
    for pat in [r'(?i)please\s+', r'(?i)kindly\s+', r'(?i)i would like you to\s+',
                r'(?i)you are (a|an)\s+', r'(?i)your task is to\s+']:
        prompt = re.sub(pat, '', prompt)
    prompt = re.sub(r'\b(very|really|quite|just|simply)\s+', '', prompt)
    prompt = re.sub(r'\s+', ' ', prompt).strip()

    # Step 2: 意图映射
    intent = _map_intent(intent_hint) if intent_hint else "GEN"
    for keyword in ["compose","email","summarize","translate","explain","analyze","extract"]:
        if keyword in prompt.lower():
            intent = _map_intent(keyword)
            break

    # Step 3: 结构检测
    fmt, out_fields = _detect_structure(prompt)

    # Step 4: 实体提取
    entities = _extract_entities(prompt)

    # Step 5: 关键点
    points = _extract_points(prompt)

    # Step 6: 组装 M7 格式
    parts = ["M7", f"INTENT:{intent}"]
    for key, val in entities.items():
        parts.append(f"{key}:{val}")
    if points:
        parts.append(f"PTS:{LIST_SEP.join(points)}")
    if fmt:
        parts.append(f"FMT:{fmt}")
    if out_fields:
        parts.append(f"OUT:{','.join(out_fields)}")

    return FIELD_SEP.join(parts)

if __name__ == "__main__":
    usage = sys.argv[1]
    runner = sys.argv[2]
    params = {}
    for a in sys.argv[3:]:
        if "=" in a:
            k, v = a.split("=", 1)
            params[k] = v

    header, template = parse_m7(f"/opt/m7/usages/{usage}.m7")
    rendered = render_template(template, params)
    compressed = compress(rendered, intent_hint=header.get("intent"))

    cfg = load_runner(runner)
    if not cfg:
        print(json.dumps({"error": f"Runner not found: {runner}"}))
        sys.exit(1)

    result = {
        "intent": header.get("intent", ""),
        "model": cfg.get("model", ""),
        "endpoint": cfg.get("endpoint", ""),
        "prompt": compressed,
        "original_tokens": len(rendered.split()),
        "compressed_tokens": len(compressed.split()),
        "compression_ratio": round(1 - len(compressed.split()) / max(len(rendered.split()), 1), 2),
    }
    print(json.dumps(result, indent=2, ensure_ascii=False))
PYEOF
    sudo chmod +x mnt/opt/m7/core/engine.py

    # M7 Executer
    sudo tee mnt/opt/m7/executer/runner.sh > /dev/null <<'SHEOF'
#!/bin/sh
# M7 Executer — 发送 API 请求
set -e

ENGINE_OUTPUT="$1"
[ -z "$ENGINE_OUTPUT" ] && { echo "Usage: runner.sh <engine_json_output>"; exit 1; }

INTENT=$(echo "$ENGINE_OUTPUT" | jq -r '.intent')
MODEL=$(echo "$ENGINE_OUTPUT" | jq -r '.model')
ENDPOINT=$(echo "$ENGINE_OUTPUT" | jq -r '.endpoint')
PROMPT=$(echo "$ENGINE_OUTPUT" | jq -r '.prompt')
API_KEY="${M7_API_KEY:-}"

echo ">>> M7 Executer <<<"
echo "Intent: $INTENT"
echo "Model: $MODEL"
echo "Prompt length: $(echo "$PROMPT" | wc -c) bytes"

REQUEST=$(jq -n \
    --arg model "$MODEL" \
    --arg system "You are an M7 protocol executor. Intent: $INTENT" \
    --arg user "$PROMPT" \
    '{model: $model, messages: [{role: "system", content: $system}, {role: "user", content: $user}], stream: false}')

curl -s -X POST "$ENDPOINT" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$REQUEST"
SHEOF
    sudo chmod +x mnt/opt/m7/executer/runner.sh

    # M7 CLI
    sudo tee mnt/opt/m7/m7.sh > /dev/null <<'SHEOF'
#!/bin/sh
set -e
M7_HOME="/opt/m7"
case "${1:-}" in
    run)
        USAGE="$2"; RUNNER="$4"; shift 4
        ENGINE_OUTPUT=$(python3 "$M7_HOME/core/engine.py" "$USAGE" "$RUNNER" "$@")
        "$M7_HOME/executer/runner.sh" "$ENGINE_OUTPUT"
        ;;
    list)
        echo "=== Runners ==="
        ls "$M7_HOME/runners"/*.yaml 2>/dev/null | xargs -I{} basename {} .yaml
        echo "=== Usages ==="
        ls "$M7_HOME/usages"/*.m7 2>/dev/null | xargs -I{} basename {} .m7
        ;;
    *)
        echo "MANIFOLD-7 Runtime"
        echo "Usage: m7 run <usage> as <runner>"
        ;;
esac
SHEOF
    sudo chmod +x mnt/opt/m7/m7.sh
    sudo ln -sf /opt/m7/m7.sh mnt/usr/local/bin/m7 2>/dev/null || true

    # 复制 runner 配置和 usages
    log "Copying runner configs..."
    sudo mkdir -p mnt/opt/m7/runners
    if [ -d "$M7_ROOT/1.runner" ]; then
        sudo cp "$M7_ROOT"/1.runner/*.yaml mnt/opt/m7/runners/ 2>/dev/null || true
    fi

    log "Copying usage files..."
    if [ -d "$M7_ROOT/2.usages" ]; then
        sudo mkdir -p mnt/opt/m7/usages
        sudo cp "$M7_ROOT"/2.usages/*.m7 mnt/opt/m7/usages/ 2>/dev/null || true
    fi

    # OpenRC 服务
    log "Configuring M7 init service..."
    sudo tee mnt/etc/init.d/m7 > /dev/null <<'INITEOF'
#!/sbin/openrc-run

name="M7 Engine"
description="MANIFOLD-7 Core"
command="/usr/sbin/lighttpd"
command_args="-f /etc/lighttpd/lighttpd.conf"
pidfile="/run/lighttpd.pid"

depend() {
    need net
    after firewall
}
INITEOF
    sudo chmod +x mnt/etc/init.d/m7
    sudo ln -sf /etc/init.d/m7 mnt/etc/runlevels/default/m7 2>/dev/null || true

    sudo tee mnt/etc/lighttpd/lighttpd.conf > /dev/null <<'LIGHTEOF'
server.document-root = "/opt/m7/www"
server.port = 8080
server.username = "lighttpd"
server.groupname = "lighttpd"
index-file.names = ("index.html")
mimetype.assign = (
    ".html" => "text/html",
    ".css" => "text/css",
    ".js" => "application/javascript",
    ".json" => "application/json"
)
LIGHTEOF
    sudo mkdir -p mnt/opt/m7/www

    log "M7 runtime injected."
}

# ─── Phase 5: 最终化 ───
finalize() {
    log "Phase 5: Finalizing..."

    # 网络 DHCP
    sudo tee -a mnt/etc/network/interfaces > /dev/null <<'NETEOF'

auto eth0
iface eth0 inet dhcp
NETEOF

    # 串口登录
    sudo sed -i 's/^#ttyS0/ttyS0/' mnt/etc/inittab 2>/dev/null || true
    grep -q 'ttyS0' mnt/etc/inittab 2>/dev/null || \
        echo 'ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100' | sudo tee -a mnt/etc/inittab > /dev/null

    echo 'm7-alpine' | sudo tee mnt/etc/hostname > /dev/null

    # 卸载
    cd "$BUILD_DIR"
    sudo umount mnt
    LOOP_DEV=$(cat .loop_dev)
    sudo losetup -d "$LOOP_DEV"

    # QCOW2
    log "Converting to QCOW2..."
    qemu-img convert -f raw -O qcow2 -c m7.raw "$OUTPUT"

    log "QCOW2 image: $OUTPUT"
    qemu-img info "$OUTPUT"
    log "Image size: $(du -h "$OUTPUT" | cut -f1)"

    rm -rf "$BUILD_DIR"
}

# ─── 主流程 ───
main() {
    echo ""
    echo "╔══════════════════════════════════════╗"
    echo "║   MANIFOLD-7  QCOW2  Image Builder  ║"
    echo "╚══════════════════════════════════════╝"
    echo ""

    check_deps
    create_image
    install_alpine
    setup_boot
    inject_m7
    finalize

    echo ""
    echo "✔  Build successful: $OUTPUT"
    echo "   Run with: qemu-system-x86_64 -m 512 -drive file=$OUTPUT,if=virtio"
}

main
