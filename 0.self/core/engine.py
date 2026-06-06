#!/usr/bin/env python3
"""
M7 Core Engine v0.2 — 协议解析、语义压缩、路由分发

M7 压缩协议:
  |    = 字段分隔符
  ;    = 列表项分隔符
  ::   = 键值分隔符 (仅 header)
  
压缩策略:
  1. 意图蒸馏 — 自然语言意图 → 短代码
  2. 模板变量绑定 — {{var}} → 实际值
  3. 结构化输出 — 检测输出格式，用紧凑标记表示
  4. 冗余移除 — 删除冠词、介词、礼貌用语
  5. Token 高效编码 — 紧凑分隔符，无空格浪费
"""
import sys, os, json, re

# ─── 意图码表 ───
INTENT_MAP = {
    "compose": "COMPOSE",
    "write": "COMPOSE",
    "draft": "COMPOSE",
    "email": "EMAIL",
    "summarize": "SUMM",
    "summary": "SUMM",
    "translate": "TRANS",
    "explain": "EXPLAIN",
    "analyze": "ANALYZE",
    "generate": "GEN",
    "extract": "EXTRACT",
    "classify": "CLASS",
    "review": "REVIEW",
    "rewrite": "REWRITE",
    "answer": "ANSWER",
    "describe": "DESC",
}

# ─── 分隔符与格式 ───
FIELD_SEP = "|"
LIST_SEP = ";"

# ─── 协议解析 ───
def parse_m7(filepath):
    """解析 .m7 协议文件, 返回 (header, prompt_template)"""
    header = {}
    template_lines = []
    in_body = False
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
            else:
                if ":" in line:
                    key, val = line.split(":", 1)
                    header[key.strip()] = val.strip()
    return header, "\n".join(template_lines).strip()

def load_runner(name, runner_dirs=None):
    """加载 runner 配置, 搜索多个目录"""
    if runner_dirs is None:
        runner_dirs = [
            os.path.join(os.path.dirname(__file__), "..", "runners"),
            "/opt/m7/runners",
        ]
    for d in runner_dirs:
        path = os.path.join(d, f"{name}.yaml")
        if os.path.exists(path):
            import yaml
            with open(path) as f:
                return yaml.safe_load(f)
    return None

# ─── 模板渲染 ───
def render_template(template, params):
    """替换 {{placeholder}} 为实际值"""
    for k, v in params.items():
        template = template.replace(f"{{{{{k}}}}}", str(v))
    return template

# ─── M7 语义压缩 v0.2 ───
def compress(prompt, intent_hint=None):
    """
    M7 v0.2 语义压缩引擎
    
    输入: 自然语言 prompt (已绑定变量)
    输出: M7 压缩格式的紧凑表示
    
    压缩率目标: 30-60% token 减少
    """
    prompt = prompt.strip()
    
    # Step 1: 清理 — 移除礼貌用语、冗余修饰
    cleaned = _clean_prompt(prompt)
    
    # Step 2: 意图提取 — 匹配意图码表
    raw_intent = intent_hint or ""
    intent = _map_intent(raw_intent) if raw_intent else _extract_intent(cleaned)
    
    # Step 3: 结构检测 — 识别输出格式要求
    structure = _detect_structure(cleaned)
    
    # Step 4: 实体提取 — 提取 To/Subject/Body 等字段
    entities = _extract_entities(cleaned)
    
    # Step 5: 关键点列表提取
    points = _extract_points(cleaned)
    
    # Step 6: 组装 M7 格式
    parts = ["M7"]
    
    if intent:
        parts.append(f"INTENT:{intent}")
    
    for key, val in entities.items():
        parts.append(f"{key}:{val}")
    
    if points:
        parts.append(f"PTS:{LIST_SEP.join(points)}")
    
    if structure.get("format"):
        parts.append(f"FMT:{structure['format']}")
    
    if structure.get("output"):
        parts.append(f"OUT:{structure['output']}")
    
    return FIELD_SEP.join(parts)


def _clean_prompt(prompt):
    """清理冗余语言"""
    # 移除礼貌前缀
    removals = [
        r'(?i)please\s+',
        r'(?i)kindly\s+',
        r'(?i)i would like you to\s+',
        r'(?i)you are (a|an)\s+',
        r'(?i)your task is to\s+',
    ]
    for pat in removals:
        prompt = re.sub(pat, '', prompt)
    
    # 移除冗余副词
    prompt = re.sub(r'\b(very|really|quite|just|simply)\s+', '', prompt)
    
    # 规范化空白
    prompt = re.sub(r'\s+', ' ', prompt).strip()
    return prompt


def _map_intent(raw):
    """将原始意图描述映射到 M7 短代码"""
    lowered = raw.lower()
    # 优先精确匹配
    for keyword, code in sorted(INTENT_MAP.items(), key=lambda x: -len(x[0])):
        if keyword in lowered:
            return code
    return _extract_intent(raw)

def _extract_intent(text):
    """从文本中提取意图代码"""
    lowered = text.lower()
    scores = {}
    for keyword, code in INTENT_MAP.items():
        if keyword in lowered:
            scores[code] = scores.get(code, 0) + 1
    
    if not scores:
        return "GEN"  # generic
    
    # 返回最高频的意图码
    return max(scores, key=scores.get)


def _detect_structure(text):
    """检测输出结构"""
    structure = {"format": None, "output": None}
    lowered = text.lower()
    
    # 格式检测
    if "professional" in lowered:
        structure["format"] = "prof"
    elif "casual" in lowered or "friendly" in lowered:
        structure["format"] = "casual"
    elif "formal" in lowered:
        structure["format"] = "formal"
    elif "concise" in lowered or "brief" in lowered:
        structure["format"] = "brief"
    
    # 输出字段检测
    out_fields = []
    for field in ["to", "subject", "body", "from", "cc", "bcc", "date", "title"]:
        if re.search(rf'\b{field}\b', lowered):
            out_fields.append(field if field != "subject" else "subj")
    if out_fields:
        structure["output"] = ",".join(out_fields)
    
    return structure


def _extract_entities(text):
    """提取命名实体 — To, Subject 等"""
    entities = {}
    patterns = [
        (r'(?i)recipient:\s*([^|]+?)(?:\.\s|$)', 'TO'),
        (r'(?i)to:\s*([^|]+?)(?:\.\s|$)', 'TO'),
        (r'(?i)subject:\s*([^|]+?)(?:\.\s|$)', 'SUBJ'),
        (r'(?i)from:\s*([^|]+?)(?:\.\s|$)', 'FROM'),
    ]
    
    for pat, key in patterns:
        m = re.search(pat, text)
        if m and key not in entities:
            entities[key] = m.group(1).strip().rstrip(',')
    
    return entities


def _extract_points(text):
    """提取关键点列表"""
    points = []
    
    # 匹配 "key points: a, b, c" 或 "points to cover: a, b, c"
    m = re.search(r'(?i)(?:key\s+)?points?\s*(?:to\s*cover)?:\s*(.+?)(?:\.\s*output|\.\s*$|$)', text)
    if m:
        raw = m.group(1).strip()
        # 分割 (逗号 or 分号 or "and")
        items = re.split(r'\s*[,;]\s*|\s+and\s+', raw)
        points = [p.strip().rstrip('.') for p in items if p.strip()]
    
    return points


# ─── CLI ───
if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: engine.py <usage> <runner> [param=val ...]")
        sys.exit(1)

    usage_name = sys.argv[1]
    runner_name = sys.argv[2]
    params = {}
    for a in sys.argv[3:]:
        if "=" in a:
            k, v = a.split("=", 1)
            params[k] = v

    # 定位 usage 文件
    script_dir = os.path.dirname(os.path.abspath(__file__))
    m7_root = os.path.dirname(os.path.dirname(script_dir))  # engine → core → 0.self → root
    usage_search = [
        f"/opt/m7/usages/{usage_name}.m7",
        os.path.join(m7_root, "2.usages", f"{usage_name}.m7"),
        f"2.usages/{usage_name}.m7",
        f"{usage_name}",
        f"{usage_name}.m7",
    ]
    usage_file = None
    for p in usage_search:
        if os.path.exists(p):
            usage_file = p
            break
    
    if not usage_file:
        print(json.dumps({"error": f"Usage not found: {usage_name}"}))
        sys.exit(1)

    header, template = parse_m7(usage_file)
    rendered = render_template(template, params)
    compressed = compress(rendered, intent_hint=header.get("intent"))

    # 定位 runner — 搜索多个目录
    runner_dirs = [
        "/opt/m7/runners",
        os.path.join(m7_root, "1.runner"),
    ]
    cfg = load_runner(runner_name, runner_dirs=runner_dirs)
    if not cfg:
        print(json.dumps({"error": f"Runner not found: {runner_name}"}))
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
