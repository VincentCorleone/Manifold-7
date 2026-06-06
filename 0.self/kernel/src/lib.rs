// MANIFOLD-7 Kernel — ManifoldGraph v0.1
//
// Architecture alignment: promts.md 内核层 (Manifold Kernel)
//   "推理调度器 · 向量内存管理 · 图存储引擎"
//
// This crate provides:
//   - graph: Directed property graph with semantic edges
//   - scheduler: Priority-based inference task queue
//   - memory: Vector memory management with similarity search

pub mod graph;
pub mod scheduler;
pub mod memory;

/// Kernel version
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Re-exports for convenience
pub use graph::{Graph, Node, Edge, NodeId, EdgeId};
pub use scheduler::{InferenceScheduler, InferenceTask, TaskPriority, TaskStatus};
pub use memory::{VectorMemory, VectorEntry, DistanceMetric};
