// Inference task scheduler — priority queue with concurrency control

use serde::{Deserialize, Serialize};
use std::collections::BinaryHeap;
use std::cmp::Ordering;
use std::sync::Arc;
use parking_lot::Mutex;

/// Task priority: higher = more urgent
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum TaskPriority {
    Low = 0,
    Normal = 5,
    High = 8,
    Critical = 10,
}

/// Task execution status
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum TaskStatus {
    Queued,
    Running,
    Completed,
    Failed(String),
    Cancelled,
}

/// A single inference task to be scheduled
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InferenceTask {
    /// Unique task ID
    pub id: uuid::Uuid,

    /// What model/intent to execute
    pub task_type: String,

    /// The prompt or compressed M7 payload
    pub payload: String,

    /// Target runner name (e.g., "deepseek", "kimi")
    pub runner: String,

    /// Priority
    pub priority: TaskPriority,

    /// Current status
    pub status: TaskStatus,

    /// Max retry attempts
    pub max_retries: u32,
    pub retry_count: u32,

    /// Dependencies: task IDs that must complete before this one
    pub dependencies: Vec<uuid::Uuid>,

    /// Task metadata
    pub metadata: std::collections::HashMap<String, String>,

    /// Timestamps
    pub created_at: f64,
    pub started_at: Option<f64>,
    pub completed_at: Option<f64>,
}

impl InferenceTask {
    pub fn new(task_type: impl Into<String>, payload: impl Into<String>, runner: impl Into<String>) -> Self {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs_f64();

        Self {
            id: uuid::Uuid::new_v4(),
            task_type: task_type.into(),
            payload: payload.into(),
            runner: runner.into(),
            priority: TaskPriority::Normal,
            status: TaskStatus::Queued,
            max_retries: 3,
            retry_count: 0,
            dependencies: Vec::new(),
            metadata: std::collections::HashMap::new(),
            created_at: now,
            started_at: None,
            completed_at: None,
        }
    }

    pub fn with_priority(mut self, priority: TaskPriority) -> Self {
        self.priority = priority;
        self
    }

    pub fn with_dependency(mut self, dep: uuid::Uuid) -> Self {
        self.dependencies.push(dep);
        self
    }
}

/// Ordering for priority queue: higher priority + older timestamp first
impl Ord for InferenceTask {
    fn cmp(&self, other: &Self) -> Ordering {
        self.priority
            .cmp(&other.priority)
            .then_with(|| other.created_at.partial_cmp(&self.created_at).unwrap_or(Ordering::Equal))
    }
}

impl PartialOrd for InferenceTask {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl PartialEq for InferenceTask {
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id
    }
}

impl Eq for InferenceTask {}

/// Thread-safe inference scheduler
///
/// Accepts tasks, schedules them by priority, respects dependencies,
/// and enforces max-concurrency limits.
pub struct InferenceScheduler {
    /// Priority queue of pending tasks
    queue: Arc<Mutex<BinaryHeap<InferenceTask>>>,

    /// Currently running tasks
    running: Arc<Mutex<Vec<InferenceTask>>>,

    /// Completed tasks (for dependency resolution)
    completed_ids: Arc<Mutex<Vec<uuid::Uuid>>>,

    /// Max concurrent tasks
    max_concurrent: usize,
}

impl InferenceScheduler {
    /// Create a new scheduler
    pub fn new(max_concurrent: usize) -> Self {
        Self {
            queue: Arc::new(Mutex::new(BinaryHeap::new())),
            running: Arc::new(Mutex::new(Vec::new())),
            completed_ids: Arc::new(Mutex::new(Vec::new())),
            max_concurrent,
        }
    }

    /// Submit a task to the queue
    pub fn submit(&self, task: InferenceTask) -> uuid::Uuid {
        let id = task.id;
        self.queue.lock().push(task);
        id
    }

    /// Check if a task's dependencies are all satisfied
    pub fn dependencies_met(&self, task: &InferenceTask) -> bool {
        let completed = self.completed_ids.lock();
        task.dependencies.iter().all(|dep| completed.contains(dep))
    }

    /// Dequeue the next runnable task (respects concurrency limit and dependencies)
    pub fn dequeue(&self) -> Option<InferenceTask> {
        let running_count = self.running.lock().len();
        if running_count >= self.max_concurrent {
            return None;
        }

        let mut queue = self.queue.lock();
        // Find the highest-priority task with satisfied dependencies
        let mut runnables: Vec<InferenceTask> = Vec::new();
        let mut remaining: Vec<InferenceTask> = Vec::new();

        while let Some(task) = queue.pop() {
            if self.dependencies_met(&task) {
                runnables.push(task);
                break; // take the highest-priority one
            } else {
                remaining.push(task);
            }
        }

        // Put back non-runnable tasks
        for task in remaining {
            queue.push(task);
        }

        if let Some(task) = runnables.into_iter().next() {
            self.running.lock().push(task.clone());
            Some(task)
        } else {
            None
        }
    }

    /// Mark a task as completed
    pub fn complete(&self, task_id: uuid::Uuid, success: bool, error: Option<String>) {
        // Remove from running
        self.running.lock().retain(|t| t.id != task_id);

        // Add to completed
        if success {
            self.completed_ids.lock().push(task_id);
        }

        // Update task status in queue if it's still there
        let mut queue = self.queue.lock();
        let mut updated_queue = BinaryHeap::new();
        while let Some(mut task) = queue.pop() {
            if task.id == task_id {
                task.status = if success {
                    TaskStatus::Completed
                } else {
                    TaskStatus::Failed(error.clone().unwrap_or_default())
                };
            }
            updated_queue.push(task);
        }
        *queue = updated_queue;
    }

    /// Get scheduler status
    pub fn status(&self) -> SchedulerStatus {
        SchedulerStatus {
            queued: self.queue.lock().len(),
            running: self.running.lock().len(),
            completed: self.completed_ids.lock().len(),
            max_concurrent: self.max_concurrent,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SchedulerStatus {
    pub queued: usize,
    pub running: usize,
    pub completed: usize,
    pub max_concurrent: usize,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_task_ordering() {
        let t1 = InferenceTask::new("EMAIL", "payload1", "deepseek")
            .with_priority(TaskPriority::Low);
        let t2 = InferenceTask::new("EMAIL", "payload2", "deepseek")
            .with_priority(TaskPriority::Critical);

        assert!(t2 > t1);
    }

    #[test]
    fn test_scheduler_submit_dequeue() {
        let sched = InferenceScheduler::new(4);
        let task = InferenceTask::new("EMAIL", "test payload", "deepseek");
        let id = sched.submit(task);
        let dequeued = sched.dequeue().unwrap();
        assert_eq!(dequeued.id, id);
        sched.complete(id, true, None);
        assert_eq!(sched.status().completed, 1);
    }

    #[test]
    fn test_dependency_ordering() {
        let sched = InferenceScheduler::new(4);
        let t1 = InferenceTask::new("ANALYZE", "p1", "deepseek");
        let t1_id = sched.submit(t1);

        // t2 depends on t1 — shouldn't dequeue until t1 completes
        let t2 = InferenceTask::new("COMPOSE", "p2", "deepseek")
            .with_dependency(t1_id);
        sched.submit(t2);

        // Dequeue should get t1 (no deps), not t2
        let dq = sched.dequeue().unwrap();
        assert_eq!(dq.id, t1_id);

        // t2 still blocked
        assert!(sched.dequeue().is_none());

        // Complete t1
        sched.complete(t1_id, true, None);

        // Now t2 should be runnable
        let dq2 = sched.dequeue().unwrap();
        assert_eq!(dq2.task_type, "COMPOSE");
    }
}
