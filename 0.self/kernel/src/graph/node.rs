// Graph node — the fundamental vertex in ManifoldGraph

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Unique node identifier
pub type NodeId = uuid::Uuid;

/// A node (vertex) in the ManifoldGraph.
///
/// Each node represents a semantic unit: a concept, a task, a model output,
/// or an external resource.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Node {
    /// Unique identifier
    pub id: NodeId,

    /// Semantic type: "concept", "task", "output", "resource", "agent", "intent", etc.
    pub node_type: String,

    /// Human-readable label
    pub label: String,

    /// Arbitrary key-value properties
    pub properties: HashMap<String, String>,

    /// Embedding vector (for semantic search)
    #[serde(skip)]
    pub embedding: Option<Vec<f32>>,

    /// Creation timestamp (epoch seconds)
    pub created_at: f64,

    /// Last modification timestamp
    pub updated_at: f64,
}

impl Node {
    /// Create a new node with a unique ID
    pub fn new(node_type: impl Into<String>, label: impl Into<String>) -> Self {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs_f64();

        Self {
            id: NodeId::new_v4(),
            node_type: node_type.into(),
            label: label.into(),
            properties: HashMap::new(),
            embedding: None,
            created_at: now,
            updated_at: now,
        }
    }

    /// Set a property
    pub fn with_property(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.properties.insert(key.into(), value.into());
        self
    }

    /// Set the embedding vector
    pub fn with_embedding(mut self, emb: Vec<f32>) -> Self {
        self.embedding = Some(emb);
        self
    }

    /// Touch the updated_at timestamp
    pub fn touch(&mut self) {
        self.updated_at = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs_f64();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_create_node() {
        let node = Node::new("task", "compose email");
        assert_eq!(node.node_type, "task");
        assert_eq!(node.label, "compose email");
        assert!(!node.id.is_nil());
    }

    #[test]
    fn test_node_properties() {
        let node = Node::new("intent", "sendEmail")
            .with_property("runner", "deepseek")
            .with_property("priority", "5");
        assert_eq!(node.properties.get("runner").unwrap(), "deepseek");
        assert_eq!(node.properties.get("priority").unwrap(), "5");
    }
}
