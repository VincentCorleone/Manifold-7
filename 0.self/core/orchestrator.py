#!/usr/bin/env python3
"""
M7 Orchestration Layer — 多模型路由、健康检查、负载均衡、故障转移 v0.1

Architecture alignment: promts.md 编排层 (Orchestration Layer)
  "模型路由 · 负载均衡 · 联邦学习"
"""

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Callable
import time
import json
import threading
import os


# ─── Data Structures ──────────────────────────────────────────────

@dataclass
class RunnerEndpoint:
    """单个模型端点"""
    name: str
    endpoint: str
    model: str
    api_key: str = ""
    weight: int = 1              # 负载权重
    max_concurrency: int = 5
    timeout_ms: int = 30000
    # 运行时状态
    healthy: bool = True
    last_check: float = 0.0
    latency_ms: float = 0.0      # 最近一次延迟
    error_count: int = 0
    total_requests: int = 0

    def to_dict(self) -> dict:
        return {
            "name": self.name,
            "endpoint": self.endpoint,
            "model": self.model,
            "weight": self.weight,
            "healthy": self.healthy,
            "latency_ms": self.latency_ms,
            "error_count": self.error_count,
            "total_requests": self.total_requests,
        }


@dataclass
class RunnerPool:
    """模型端点池，按名称索引"""
    runners: Dict[str, List[RunnerEndpoint]] = field(default_factory=dict)

    def add(self, name: str, endpoint: str, model: str,
            api_key: str = "", weight: int = 1):
        """添加一个 runner 端点"""
        ep = RunnerEndpoint(
            name=name,
            endpoint=endpoint,
            model=model,
            api_key=api_key,
            weight=weight,
        )
        if name not in self.runners:
            self.runners[name] = []
        self.runners[name].append(ep)
        return ep

    def load_from_yaml(self, runner_dir: str):
        """从 YAML 配置目录加载所有 runner"""
        import yaml
        for fname in sorted(os.listdir(runner_dir)):
            if not fname.endswith(".yaml"):
                continue
            name = fname[:-5]
            path = os.path.join(runner_dir, fname)
            with open(path) as f:
                cfg = yaml.safe_load(f)
            if not isinstance(cfg, dict):
                # Skip empty or malformed YAML files
                continue
            self.add(
                name=name,
                endpoint=cfg.get("endpoint", ""),
                model=cfg.get("model", name),
                api_key=cfg.get("api_key", ""),
                weight=cfg.get("weight", 1),
            )

    def get_healthy(self, name: Optional[str] = None) -> List[RunnerEndpoint]:
        """获取所有健康的端点"""
        if name:
            eps = self.runners.get(name, [])
        else:
            eps = []
            for name_list in self.runners.values():
                eps.extend(name_list)
        return [ep for ep in eps if ep.healthy]

    def to_dict(self) -> dict:
        return {
            name: [ep.to_dict() for ep in eps]
            for name, eps in self.runners.items()
        }


# ─── Health Check ─────────────────────────────────────────────────

class HealthChecker:
    """周期性健康检查"""

    def __init__(self, pool: RunnerPool, interval_sec: float = 30.0):
        self.pool = pool
        self.interval_sec = interval_sec
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None

    def check_one(self, ep: RunnerEndpoint) -> bool:
        """检查单个端点 — 发送轻量探测请求"""
        try:
            import urllib.request
            start = time.monotonic()
            # 尝试访问端点的 base URL
            base = ep.endpoint.rsplit("/v1/", 1)[0]
            if "/chat/completions" in ep.endpoint:
                base = ep.endpoint.rsplit("/chat/completions", 1)[0]
            req = urllib.request.Request(base, method="HEAD")
            req.add_header("Authorization", f"Bearer {ep.api_key}")
            urllib.request.urlopen(req, timeout=5)
            elapsed = (time.monotonic() - start) * 1000
            ep.latency_ms = elapsed
            ep.healthy = True
            ep.error_count = 0
            return True
        except Exception:
            ep.healthy = False
            ep.error_count += 1
            return False

    def check_all(self):
        """检查池中所有端点"""
        for eps in self.pool.runners.values():
            for ep in eps:
                self.check_one(ep)
                ep.last_check = time.time()

    def start(self):
        """启动后台健康检查线程"""
        def _loop():
            while not self._stop.is_set():
                self.check_all()
                self._stop.wait(self.interval_sec)
        self._thread = threading.Thread(target=_loop, daemon=True)
        self._thread.start()

    def stop(self):
        """停止健康检查"""
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=5)


# ─── Load Balancing Strategies ────────────────────────────────────

class LoadBalancer:
    """
    负载均衡器 — 支持多种策略

    Strategies:
      - round_robin: 轮询
      - least_latency: 最低延迟优先
      - weighted: 加权随机
      - priority: 优先级顺序 (第一个健康)
    """

    STRATEGIES = ("round_robin", "least_latency", "weighted", "priority")

    def __init__(self, pool: RunnerPool, strategy: str = "round_robin"):
        if strategy not in self.STRATEGIES:
            raise ValueError(f"Unknown strategy: {strategy}. Use: {self.STRATEGIES}")
        self.pool = pool
        self.strategy = strategy
        self._rr_counters: Dict[str, int] = {}

    def select(self, runner_name: str) -> Optional[RunnerEndpoint]:
        """为给定 runner 名称选择一个健康端点"""
        healthy = self.pool.get_healthy(runner_name)
        if not healthy:
            return None
        if len(healthy) == 1:
            return healthy[0]
        return self._apply_strategy(healthy, runner_name)

    def _apply_strategy(self, candidates: List[RunnerEndpoint],
                        runner_name: str) -> RunnerEndpoint:
        if self.strategy == "round_robin":
            return self._round_robin(candidates, runner_name)
        elif self.strategy == "least_latency":
            return min(candidates, key=lambda ep: ep.latency_ms)
        elif self.strategy == "weighted":
            import random
            total = sum(ep.weight for ep in candidates)
            r = random.uniform(0, total)
            acc = 0
            for ep in candidates:
                acc += ep.weight
                if r <= acc:
                    return ep
            return candidates[-1]
        elif self.strategy == "priority":
            return candidates[0]
        return candidates[0]

    def _round_robin(self, candidates: List[RunnerEndpoint],
                     runner_name: str) -> RunnerEndpoint:
        key = runner_name
        idx = self._rr_counters.get(key, 0) % len(candidates)
        self._rr_counters[key] = idx + 1
        return candidates[idx]

    def get_latency_stats(self, runner_name: str) -> dict:
        """获取指定 runner 的延迟统计"""
        eps = self.pool.runners.get(runner_name, [])
        latencies = [ep.latency_ms for ep in eps if ep.latency_ms > 0]
        if not latencies:
            return {"count": 0}
        return {
            "count": len(latencies),
            "min_ms": min(latencies),
            "max_ms": max(latencies),
            "avg_ms": sum(latencies) / len(latencies),
        }


# ─── Orchestrator — 编排主入口 ────────────────────────────────────

class Orchestrator:
    """
    M7 编排层主入口

    融合了:
      - RunnerPool (端点管理)
      - HealthChecker (健康检查)
      - LoadBalancer (负载均衡)
      - Fallback (故障转移)
    """

    def __init__(self, runner_dir: str = None,
                 strategy: str = "round_robin",
                 health_interval: float = 30.0):
        self.pool = RunnerPool()
        self.balancer = LoadBalancer(self.pool, strategy=strategy)
        self.checker = HealthChecker(self.pool, interval_sec=health_interval)
        self.fallback_chain: List[str] = []  # 故障转移顺序

        if runner_dir and os.path.isdir(runner_dir):
            self.pool.load_from_yaml(runner_dir)

    def set_fallback_chain(self, chain: List[str]):
        """设置故障转移链: 主 runner 不可用时依次尝试备选"""
        self.fallback_chain = chain

    def resolve_runner(self, primary: str) -> Optional[RunnerEndpoint]:
        """
        解析 runner 端点，带故障转移

        尝试顺序:
          1. primary runner (通过负载均衡选择)
          2. fallback_chain 中的 runner (依次尝试)
        """
        candidates = [primary] + [
            r for r in self.fallback_chain if r != primary
        ]

        for runner_name in candidates:
            ep = self.balancer.select(runner_name)
            if ep:
                return ep

        return None

    def route(self, primary_runner: str) -> dict:
        """
        路由决策 — 返回选中的端点信息

        返回格式:
          {
            "selected": {...},
            "strategy": "...",
            "fallback_used": false,
            "available_runners": [...]
          }
        """
        fallback_used = False
        ep = self.balancer.select(primary_runner)

        if not ep and self.fallback_chain:
            for fb in self.fallback_chain:
                ep = self.balancer.select(fb)
                if ep:
                    fallback_used = True
                    break

        if not ep:
            return {"error": "No healthy runner available"}

        return {
            "selected": ep.to_dict(),
            "strategy": self.balancer.strategy,
            "fallback_used": fallback_used,
            "available_runners": [
                name for name, eps in self.pool.runners.items()
                if any(e.healthy for e in eps)
            ],
        }

    def status(self) -> dict:
        """获取编排层完整状态"""
        return {
            "pool": self.pool.to_dict(),
            "strategy": self.balancer.strategy,
            "fallback_chain": self.fallback_chain,
            "latency_stats": {
                name: self.balancer.get_latency_stats(name)
                for name in self.pool.runners
            },
        }

    def start_health_checks(self):
        """启动后台健康检查"""
        self.checker.start()

    def stop_health_checks(self):
        """停止后台健康检查"""
        self.checker.stop()


# ─── CLI ──────────────────────────────────────────────────────────

if __name__ == "__main__":
    import sys

    orch = Orchestrator(
        runner_dir=os.path.join(os.path.dirname(__file__), "..", "..", "1.runner"),
    )

    if len(sys.argv) < 2:
        print("Usage: orchestrator.py <command> [args]")
        print()
        print("Commands:")
        print("  route <runner>      路由到最佳端点")
        print("  status              查看编排层完整状态")
        print("  check               运行一次健康检查")
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "route":
        runner = sys.argv[2] if len(sys.argv) > 2 else "deepseek"
        orch.set_fallback_chain(["kimi", "deepseek"])
        result = orch.route(runner)
        print(json.dumps(result, indent=2, ensure_ascii=False))

    elif cmd == "status":
        print(json.dumps(orch.status(), indent=2, ensure_ascii=False))

    elif cmd == "check":
        orch.checker.check_all()
        print(json.dumps(orch.status(), indent=2, ensure_ascii=False))
