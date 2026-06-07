#!/bin/sh
# m7.sh — MANIFOLD-7 入口脚本 v0.2
# 双模式: direct (本地引擎 + API) / vm (QCOW2 虚拟机内执行)
set -e

M7_ROOT="$(cd "$(dirname "$0")" && pwd)"
SELF_DIR="$M7_ROOT/0.self"
RUNNER_DIR="$M7_ROOT/1.runner"
USAGE_DIR="$M7_ROOT/2.usages"
ENGINE="$SELF_DIR/core/engine.py"
QCOW2="$SELF_DIR/core/m7-alpine.qcow2"

# ─── 颜色 ───
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[M7]${NC} $*"; }
warn() { echo -e "${YELLOW}[M7-WARN]${NC} $*"; }
err()  { echo -e "${RED}[M7-ERR]${NC} $*" >&2; exit 1; }
info() { echo -e "${CYAN}[M7]${NC} $*"; }

# ─── 帮助 ───
usage() {
    cat <<'HELP'
MANIFOLD-7 — Model Interoperability Protocol v0.3

Usage:
  ./m7 run <usage> as <runner> [params...]   直接模式: 本地引擎 + API 调用
  ./m7 run <usage> as <runner> --vm           VM 模式:  QCOW2 虚拟机内执行
  ./m7 decompose "<intent>"                  意图层: 自然语言 → 任务 DAG 分解
  ./m7 orchestrate status                    编排层: 查看 runner 池状态
  ./m7 orchestrate route <runner>            编排层: 路由到最佳端点
  ./m7 orchestrate check                     编排层: 运行一次健康检查
  ./m7 list                                   列出所有 usages 和 runners
  ./m7 validate <usage>                       验证 .m7 文件语法
  ./m7 init <usage-name>                      创建新 usage 模板
  ./m7 build                                  构建 QCOW2 镜像 (Alpine = 硬件抽象层)
  ./m7 compress <text>                        测试 M7 语义压缩

Examples:
  ./m7 run sendEmail as deepseek recipient=alice@example.com subject="Hi" body_points="Greeting,Body,End"
  ./m7 run sendEmail as deepseek --vm
  ./m7 decompose "Analyze the report and summarize in an email"
  ./m7 orchestrate route deepseek
  ./m7 compress "Compose a professional email. Recipient: a@b.com."

Environment:
  M7_DEEPSEEK_API_KEY    DeepSeek API 密钥
  M7_KIMI_API_KEY        Kimi API 密钥
  M7_API_KEY             通用 API 密钥 (回退)
HELP
    exit 0
}

# ─── 子命令: list ───
cmd_list() {
    echo "=== Runners ==="
    for f in "$RUNNER_DIR"/*.yaml; do
        [ -f "$f" ] && echo "  • $(basename "$f" .yaml)"
    done
    echo ""
    echo "=== Usages ==="
    for f in "$USAGE_DIR"/*.m7; do
        [ -f "$f" ] && echo "  • $(basename "$f" .m7)"
    done
    echo ""
    echo "=== QCOW2 Image ==="
    [ -f "$QCOW2" ] && echo "  • m7-alpine.qcow2 ($(du -h "$QCOW2" | cut -f1))" || echo "  (not built — run ./m7 build)"
}

# ─── 子命令: validate ───
cmd_validate() {
    local name="$1"
    [ -z "$name" ] && err "Usage: ./m7 validate <usage-name>"
    local path="$USAGE_DIR/$name.m7"
    [ ! -f "$path" ] && path="$USAGE_DIR/$name"
    [ ! -f "$path" ] && err "Usage not found: $name"

    log "Validating $path..."
    # 基础语法检查: 必须有 protocol/intent 头部和 --- 分隔符
    if grep -q '^protocol:' "$path" && grep -q '^---' "$path"; then
        local intent=$(sed -n '/^intent:/s/intent: *//p' "$path")
        log "Valid M7-0.1 protocol file. Intent: ${intent:-'(none)'}"
    else
        err "Invalid .m7 file: missing protocol header or --- separator"
    fi
}

# ─── 子命令: init ───
cmd_init() {
    local name="$1"
    [ -z "$name" ] && err "Usage: ./m7 init <usage-name>"
    local target="$USAGE_DIR/$name.m7"
    [ -f "$target" ] && err "Usage already exists: $target"

    cat > "$target" <<EOF
# M7 Usage: $name
# Created: $(date +%Y-%m-%d)

protocol: M7-0.1
intent: <describe the task>
input:
  - name: <param>
    type: string
    required: true
output:
  format: m7-compressed
  schema: <reference>
---
<prompt template or semantic graph reference>
EOF
    log "Created usage template: $target"
}

# ─── 子命令: compress (测试压缩) ───
cmd_compress() {
    local text="$*"
    [ -z "$text" ] && err "Usage: ./m7 compress <text>"
    log "Original: $text"
    log "Compressing..."
    python3 -c "
import sys
sys.path.insert(0, '$SELF_DIR/core')
from engine import compress
result = compress('$text')
print(f'  M7: {result}')
print(f'  Tokens: {len(\"$text\".split())} → {len(result.split())}')
"
}

# ─── 子命令: build ───
cmd_build() {
    local build_script="$SELF_DIR/core/build.sh"
    [ ! -f "$build_script" ] && err "Build script not found: $build_script"
    log "Building QCOW2 image..."
    sudo bash "$build_script"
}

# ─── 核心: run (direct 模式) ───
cmd_run_direct() {
    local usage_name="$1"
    local runner_name="$2"
    shift 2

    # 收集参数
    local params=""
    for a in "$@"; do
        case "$a" in
            *=*) params="$params $a" ;;
        esac
    done

    log "Mode: direct (本地引擎)"
    log "Usage:  $usage_name"
    log "Runner: $runner_name"

    # Phase 1+2: 引擎解析 + 压缩
    log "Phase 1-2: M7 engine (parsing + compression)..."
    local engine_output
    engine_output=$(python3 "$ENGINE" "$usage_name" "$runner_name" $params 2>&1) || {
        err "Engine failed:\n$engine_output"
    }

    # 检查 engine 是否返回错误
    if echo "$engine_output" | grep -q '"error"'; then
        err "$engine_output"
    fi

    # 提取字段
    local intent model endpoint prompt original compressed ratio
    intent=$(echo "$engine_output"     | python3 -c "import sys,json; print(json.load(sys.stdin).get('intent',''))")
    model=$(echo "$engine_output"      | python3 -c "import sys,json; print(json.load(sys.stdin).get('model',''))")
    endpoint=$(echo "$engine_output"   | python3 -c "import sys,json; print(json.load(sys.stdin).get('endpoint',''))")
    prompt=$(echo "$engine_output"     | python3 -c "import sys,json; print(json.load(sys.stdin).get('prompt',''))")
    original=$(echo "$engine_output"   | python3 -c "import sys,json; print(json.load(sys.stdin).get('original_tokens',''))")
    compressed=$(echo "$engine_output" | python3 -c "import sys,json; print(json.load(sys.stdin).get('compressed_tokens',''))")
    ratio=$(echo "$engine_output"      | python3 -c "import sys,json; print(json.load(sys.stdin).get('compression_ratio',''))")

    info "Intent:    $intent"
    info "Model:     $model"
    info "Compress:  $original → $compressed tokens ($ratio)"

    # Phase 3: 获取 API Key
    local runner_upper
    runner_upper=$(echo "$runner_name" | tr 'a-z' 'A-Z')
    local api_key_var="M7_${runner_upper}_API_KEY"
    eval "local api_key=\${$api_key_var:-\${M7_API_KEY:-}}"

    if [ -z "$api_key" ]; then
        err "No API key set. Export $api_key_var or M7_API_KEY"
    fi

    # Phase 4: 执行 API 调用
    log "Phase 3-4: API call → $model"

    local request_body
    request_body=$(python3 -c "
import json
print(json.dumps({
    'model': '$model',
    'messages': [
        {'role': 'system', 'content': 'You are an M7 protocol executor. Parse the structured input and generate the requested output. $intent'},
        {'role': 'user', 'content': '''$prompt'''}
    ],
    'stream': False
}))
")

    log "Sending request..."
    curl -s -X POST "$endpoint" \
        -H "Authorization: Bearer $api_key" \
        -H "Content-Type: application/json" \
        -d "$request_body" | python3 -m json.tool 2>/dev/null || \
        curl -s -X POST "$endpoint" \
            -H "Authorization: Bearer $api_key" \
            -H "Content-Type: application/json" \
            -d "$request_body"

    echo ""
    log "Done."
}

# ─── 核心: run (VM 模式) ───
cmd_run_vm() {
    local usage_name="$1"
    local runner_name="$2"
    shift 2
    # 移除 --vm flag
    set -- $(echo "$@" | sed 's/--vm//')

    [ ! -f "$QCOW2" ] && err "QCOW2 not found. Run: ./m7 build"

    log "Mode: vm (QCOW2 虚拟机)"
    log "Usage:  $usage_name"
    log "Runner: $runner_name"

    if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
        err "qemu-system-x86_64 not installed. Install: sudo apt-get install qemu-system-x86"
    fi

    # 读取 API Key (用于通过 HTTP header 传给 VM 内 CGI)
    local runner_upper api_key
    runner_upper=$(echo "$runner_name" | tr 'a-z' 'A-Z')
    eval "api_key=\${M7_${runner_upper}_API_KEY:-\${M7_API_KEY:-}}"
    if [ -z "$api_key" ]; then
        warn "No API key set (\$M7_${runner_upper}_API_KEY); VM will run in dry-run mode"
    fi

    # 检测 KVM 加速
    local accel_args=""
    if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        accel_args="-enable-kvm -cpu host"
        log "KVM acceleration enabled"
    else
        accel_args="-cpu max"
        warn "KVM not available; falling back to TCG (will be slow)"
    fi

    # 选择空闲端口 (避免与已占用 8080 冲突)
    local host_port="${M7_VM_PORT:-8080}"

    # 启动 QEMU
    log "Booting M7 VM (port ${host_port})..."
    qemu-system-x86_64 \
        $accel_args \
        -m 512 \
        -nographic \
        -no-reboot \
        -drive file="$QCOW2",format=qcow2,if=virtio \
        -netdev user,id=m7net,hostfwd=tcp::${host_port}-:8080 \
        -device virtio-net-pci,netdev=m7net \
        -serial null \
        -monitor none \
        >/tmp/m7-vm.log 2>&1 &
    QEMU_PID=$!

    # 注册 trap：意外退出时杀掉 QEMU
    trap 'kill '"$QEMU_PID"' 2>/dev/null; wait '"$QEMU_PID"' 2>/dev/null' EXIT INT TERM

    # 等待 VM 就绪
    log "Waiting for VM (timeout 120s)..."
    local ready=false
    for i in $(seq 1 120); do
        if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            err "QEMU died unexpectedly. Last log:\n$(tail -20 /tmp/m7-vm.log)"
        fi
        if curl -s -o /dev/null -w '%{http_code}' "http://localhost:${host_port}/" 2>/dev/null | grep -q '^2'; then
            log "VM ready (${i}s)"
            ready=true
            break
        fi
        sleep 1
    done
    $ready || err "VM did not become ready within 120s. Log:\n$(tail -30 /tmp/m7-vm.log)"

    # 组装查询参数
    log "Sending M7 command to VM..."
    local params=""
    for a in "$@"; do
        case "$a" in
            *=*)
                # 简单 URL 编码 (空格 → %20，& → %26)
                local k="${a%%=*}"
                local v="${a#*=}"
                v=$(echo "$v" | sed 's/%/%25/g; s/&/%26/g; s/ /%20/g; s/+/%2B/g; s/#/%23/g')
                params="$params&${k}=${v}"
                ;;
        esac
    done

    local vm_url="http://localhost:${host_port}/cgi-bin/m7?usage=${usage_name}&runner=${runner_name}${params}"
    info "URL: $vm_url"

    # 通过 X-M7-Api-Key header 把 API Key 透传给 CGI
    local response
    if [ -n "$api_key" ]; then
        response=$(curl -s -H "X-M7-Api-Key: ${api_key}" "$vm_url")
    else
        response=$(curl -s "$vm_url")
    fi

    echo "$response" | python3 -m json.tool 2>/dev/null \
        || echo "$response" | py -m json.tool 2>/dev/null \
        || echo "$response"

    echo ""
    log "Shutting down VM..."
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
    trap - EXIT INT TERM
    log "Done."
}

# ─── 子命令: decompose ───
cmd_decompose() {
    local intent="$*"
    [ -z "$intent" ] && err "Usage: ./m7 decompose '<intent>'"
    log "Intent: $intent"
    python3 "$SELF_DIR/core/decomposer.py" "$intent"
}

# ─── 子命令: orchestrate ───
cmd_orchestrate() {
    local sub="$1"
    shift
    case "$sub" in
        status)  python3 "$SELF_DIR/core/orchestrator.py" status ;;
        route)   python3 "$SELF_DIR/core/orchestrator.py" route "${1:-deepseek}" ;;
        check)   python3 "$SELF_DIR/core/orchestrator.py" check ;;
        *)       err "Usage: ./m7 orchestrate {status|route <runner>|check}" ;;
    esac
}

# ─── 入口 ───
main() {
    [ $# -eq 0 ] && usage

    local cmd="$1"
    shift

    case "$cmd" in
        run)
            local usage_name="$1"
            [ -z "$usage_name" ] && err "Usage: ./m7 run <usage> as <runner>"
            shift

            if [ "$1" != "as" ]; then
                err "Expected 'as' keyword. Usage: ./m7 run <usage> as <runner>"
            fi
            shift
            local runner_name="$1"
            [ -z "$runner_name" ] && err "Missing runner name"
            shift

            # 检测 --vm flag
            local is_vm=false
            for a in "$@"; do
                [ "$a" = "--vm" ] && is_vm=true
            done

            if $is_vm; then
                cmd_run_vm "$usage_name" "$runner_name" "$@"
            else
                cmd_run_direct "$usage_name" "$runner_name" "$@"
            fi
            ;;
        decompose)     cmd_decompose "$@" ;;
        orchestrate)   cmd_orchestrate "$@" ;;
        list)          cmd_list ;;
        validate)      cmd_validate "$@" ;;
        init)          cmd_init "$@" ;;
        build)         cmd_build ;;
        compress)      cmd_compress "$@" ;;
        help|--help|-h) usage ;;
        *)             err "Unknown command: $cmd. Try ./m7 help" ;;
    esac
}

main "$@"
