#!/usr/bin/env python3
"""
M7 Intent Layer — Task Decomposition Engine v0.1
将自然语言意图分解为可执行的子任务 DAG

Architecture alignment: promts.md 意图层 (Intent Layer)
  "自然语言 → M7 语义编码 → 任务分解"
"""

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Set
import json
import re


# ─── Task Type Registry ───────────────────────────────────────────
# 每个任务类型定义了: 能力标签、依赖模板、默认 runner 亲和性

TASK_TYPES: Dict[str, dict] = {
    "ANALYZE": {
        "description": "分析输入数据/文本，提取结构化信息",
        "output": "structured_data",
        "affinity": ["deepseek", "kimi"],
    },
    "SUMM": {
        "description": "摘要/总结",
        "output": "summary_text",
        "affinity": ["deepseek", "kimi"],
    },
    "COMPOSE": {
        "description": "生成/撰写内容",
        "output": "generated_text",
        "affinity": ["deepseek", "kimi"],
    },
    "EMAIL": {
        "description": "撰写邮件",
        "output": "email_draft",
        "affinity": ["deepseek", "kimi"],
    },
    "TRANS": {
        "description": "翻译",
        "output": "translated_text",
        "affinity": ["deepseek"],
    },
    "EXPLAIN": {
        "description": "解释/阐述概念",
        "output": "explanation_text",
        "affinity": ["deepseek", "kimi"],
    },
    "GEN": {
        "description": "通用生成",
        "output": "generated_text",
        "affinity": ["deepseek", "kimi"],
    },
    "EXTRACT": {
        "description": "信息抽取",
        "output": "extracted_entities",
        "affinity": ["deepseek", "kimi"],
    },
    "CLASS": {
        "description": "分类/标注",
        "output": "classification_result",
        "affinity": ["deepseek", "kimi"],
    },
    "VALIDATE": {
        "description": "验证/校验输出",
        "output": "validation_result",
        "affinity": ["deepseek", "kimi"],
    },
    "REWRITE": {
        "description": "改写/润色",
        "output": "rewritten_text",
        "affinity": ["deepseek", "kimi"],
    },
    "SEND": {
        "description": "发送/分发 (邮件、消息等)",
        "output": "send_confirmation",
        "affinity": ["executer"],  # local executer, not LLM
    },
}


# ─── Data Structures ──────────────────────────────────────────────

@dataclass
class TaskNode:
    """DAG 中的一个子任务节点"""
    id: str
    task_type: str          # 来自 TASK_TYPES
    description: str
    params: Dict[str, str] = field(default_factory=dict)
    dependencies: List[str] = field(default_factory=list)  # 前置任务 ID 列表
    priority: int = 0       # 0=最低, 10=最高
    runner_affinity: List[str] = field(default_factory=list)
    retry_policy: str = "once"  # once | retry-N | fallback


@dataclass
class TaskDAG:
    """完整的任务分解图"""
    intent: str
    nodes: Dict[str, TaskNode] = field(default_factory=dict)
    edges: List[tuple] = field(default_factory=list)  # (from_id, to_id)

    def topological_order(self) -> List[str]:
        """返回拓扑排序后的节点 ID 列表"""
        in_degree: Dict[str, int] = {nid: 0 for nid in self.nodes}
        for _, to_id in self.edges:
            in_degree[to_id] = in_degree.get(to_id, 0) + 1

        queue = [nid for nid, deg in in_degree.items() if deg == 0]
        result = []

        while queue:
            nid = queue.pop(0)
            result.append(nid)
            for src, dst in self.edges:
                if src == nid:
                    in_degree[dst] -= 1
                    if in_degree[dst] == 0:
                        queue.append(dst)

        return result

    def to_dict(self) -> dict:
        return {
            "intent": self.intent,
            "nodes": {
                nid: {
                    "id": n.id,
                    "type": n.task_type,
                    "description": n.description,
                    "params": n.params,
                    "dependencies": n.dependencies,
                    "priority": n.priority,
                    "runner_affinity": n.runner_affinity,
                    "retry_policy": n.retry_policy,
                }
                for nid, n in self.nodes.items()
            },
            "edges": [[src, dst] for src, dst in self.edges],
            "execution_order": self.topological_order(),
        }

    def to_json(self) -> str:
        return json.dumps(self.to_dict(), indent=2, ensure_ascii=False)


# ─── Decomposition Strategies ─────────────────────────────────────

# 常见意图 → 子任务模板
DECOMPOSITION_TEMPLATES: Dict[str, List[dict]] = {
    # "写邮件并发送"
    "email_compose_send": [
        {"id": "compose", "type": "EMAIL", "desc": "撰写邮件正文"},
        {"id": "send", "type": "SEND", "desc": "发送邮件",
         "deps": ["compose"]},
    ],
    # "分析+摘要+邮件"
    "analyze_summarize_email": [
        {"id": "analyze", "type": "ANALYZE", "desc": "分析输入数据"},
        {"id": "summarize", "type": "SUMM", "desc": "生成摘要",
         "deps": ["analyze"]},
        {"id": "compose", "type": "EMAIL", "desc": "撰写邮件",
         "deps": ["summarize"]},
        {"id": "send", "type": "SEND", "desc": "发送邮件",
         "deps": ["compose"]},
    ],
    # "翻译+润色"
    "translate_rewrite": [
        {"id": "translate", "type": "TRANS", "desc": "翻译原文"},
        {"id": "rewrite", "type": "REWRITE", "desc": "润色译文",
         "deps": ["translate"]},
    ],
    # "分类+提取"
    "classify_extract": [
        {"id": "classify", "type": "CLASS", "desc": "分类输入"},
        {"id": "extract", "type": "EXTRACT", "desc": "提取关键信息",
         "deps": ["classify"]},
    ],
    # "生成+验证"
    "generate_validate": [
        {"id": "generate", "type": "GEN", "desc": "生成内容"},
        {"id": "validate", "type": "VALIDATE", "desc": "验证内容质量",
         "deps": ["generate"]},
    ],
}


def _match_template(intent: str) -> Optional[str]:
    """根据意图文本匹配最佳分解模板"""
    lowered = intent.lower()

    # 优先级匹配 (从具体到通用)
    if ("analyze" in lowered or "分析" in lowered) and \
       ("summar" in lowered or "摘要" in lowered) and \
       ("email" in lowered or "邮件" in lowered):
        return "analyze_summarize_email"

    if ("email" in lowered or "邮件" in lowered) and \
       ("send" in lowered or "发送" in lowered or "compose" in lowered or "撰写" in lowered):
        return "email_compose_send"

    if ("translate" in lowered or "翻译" in lowered) and \
       ("rewrite" in lowered or "润色" in lowered or "polish" in lowered):
        return "translate_rewrite"

    if ("classif" in lowered or "分类" in lowered) and \
       ("extract" in lowered or "提取" in lowered):
        return "classify_extract"

    if ("generat" in lowered or "生成" in lowered) and \
       ("validat" in lowered or "验证" in lowered or "check" in lowered):
        return "generate_validate"

    # 单步意图直接走模板
    if "email" in lowered or "邮件" in lowered:
        return "email_compose_send"

    return None


def decompose(intent: str, params: Optional[Dict[str, str]] = None) -> TaskDAG:
    """
    将自然语言意图分解为 TaskDAG

    Args:
        intent: 自然语言意图描述
        params: 额外参数 (会传播到各子任务)

    Returns:
        TaskDAG: 任务分解图
    """
    params = params or {}
    dag = TaskDAG(intent=intent)

    template_name = _match_template(intent)

    if template_name and template_name in DECOMPOSITION_TEMPLATES:
        template = DECOMPOSITION_TEMPLATES[template_name]
    else:
        # 无匹配模板 → 单节点 DAG (通用生成)
        template = [
            {"id": "gen", "type": "GEN", "desc": intent},
        ]

    # 构建节点
    for tpl in template:
        task_type = tpl["type"]
        type_info = TASK_TYPES.get(task_type, TASK_TYPES["GEN"])

        node = TaskNode(
            id=tpl["id"],
            task_type=task_type,
            description=tpl["desc"],
            params={**params},
            dependencies=tpl.get("deps", []),
            runner_affinity=list(type_info.get("affinity", [])),
        )
        dag.nodes[node.id] = node

    # 构建边
    for node in dag.nodes.values():
        for dep_id in node.dependencies:
            dag.edges.append((dep_id, node.id))

    # 验证无环
    _validate_dag(dag)

    return dag


def _validate_dag(dag: TaskDAG):
    """验证 DAG 无环，所有依赖引用有效"""
    node_ids = set(dag.nodes.keys())

    for node in dag.nodes.values():
        for dep_id in node.dependencies:
            if dep_id not in node_ids:
                raise ValueError(
                    f"Task '{node.id}' depends on unknown task '{dep_id}'"
                )

    # DFS 环检测
    WHITE, GRAY, BLACK = 0, 1, 2
    color = {nid: WHITE for nid in dag.nodes}

    def dfs(nid):
        color[nid] = GRAY
        node = dag.nodes[nid]
        for dep_id in node.dependencies:
            if color[dep_id] == GRAY:
                raise ValueError(f"Cycle detected: {nid} ↔ {dep_id}")
            if color[dep_id] == WHITE:
                dfs(dep_id)
        color[nid] = BLACK

    for nid in dag.nodes:
        if color[nid] == WHITE:
            dfs(nid)


# ─── CLI ──────────────────────────────────────────────────────────

if __name__ == "__main__":
    import sys

    if len(sys.argv) < 2:
        print("Usage: decomposer.py '<intent>' [param=val ...]")
        print()
        print("Available templates:")
        for name in DECOMPOSITION_TEMPLATES:
            nodes = [n["type"] for n in DECOMPOSITION_TEMPLATES[name]]
            print(f"  {name}: {' → '.join(nodes)}")
        sys.exit(1)

    intent = sys.argv[1]
    params = {}
    for a in sys.argv[2:]:
        if "=" in a:
            k, v = a.split("=", 1)
            params[k] = v

    dag = decompose(intent, params)
    print(dag.to_json())
