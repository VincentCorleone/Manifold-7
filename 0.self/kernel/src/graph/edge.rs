// Graph edge — typed, directed relationships between nodes

use serde::{Deserialize, Serialize};

/// Unique edge identifier
pub type EdgeId = uuid::Uuid;

/// Semantic edge type
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum EdgeType {
    /// A depends on B (e.g., task depends on input data)
    DependsOn,
    /// A produces B (e.g., task produces output)
    Produces,
    /// A is-a B (taxonomic)
    IsA,
    /// A references B
    References,
    /// A is next in sequence after B
    Next,
    /// A is an alternative to B (fallback)
    Alternative,
    /// Custom semantic type
    Custom(String),
}

impl EdgeType {
    pub fn as_str(&self) -> &str {
        match self {
            EdgeType::DependsOn => "depends_on",
            EdgeType::Produces => "produces",
            EdgeType::IsA => "is_a",
            EdgeType::References => "references",
            EdgeType::Next => "next",
            EdgeType::Alternative => "alternative",
            EdgeType::Custom(s) => s.as_str(),
        }
    }
}

impl From<&str> for EdgeType {
    fn from(s: &str) -> Self {
        match s {
            "depends_on" => EdgeType::DependsOn,
            "produces" => EdgeType::Produces,
            "is_a" => EdgeType::IsA,
            "references" => EdgeType::References,
            "next" => EdgeType::Next,
            "alternative" => EdgeType::Alternative,
            other => EdgeType::Custom(other.to_string()),
        }
    }
}

/// An edge (directed relationship) in the ManifoldGraph
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Edge {
    /// Unique identifier
    pub id: EdgeId,

    /// Source node
    pub from: super::NodeId,

    /// Target node
    pub to: super::NodeId,

    /// Semantic relationship type
    pub edge_type: EdgeType,

    /// Optional weight (for weighted graph algorithms)
    pub weight: f64,

    /// Arbitrary properties
    pub properties: std::collections::HashMap<String, String>,

    /// Creation timestamp
    pub created_at: f64,
}

impl Edge {
    /// Create a new edge
    pub fn new(
        from: super::NodeId,
        to: super::NodeId,
        edge_type: EdgeType,
    ) -> Self {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs_f64();

        Self {
            id: EdgeId::new_v4(),
            from,
            to,
            edge_type,
            weight: 1.0,
            properties: std::collections::HashMap::new(),
            created_at: now,
        }
    }

    /// Set weight
    pub fn with_weight(mut self, weight: f64) -> Self {
        self.weight = weight;
        self
    }

    /// Set a property
    pub fn with_property(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.properties.insert(key.into(), value.into());
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::graph::Node;

    #[test]
    fn test_edge_creation() {
        let a = Node::new("task", "compose").id;
        let b = Node::new("task", "send").id;
        let edge = Edge::new(a, b, EdgeType::DependsOn);
        assert_eq!(edge.from, a);
        assert_eq!(edge.to, b);
        assert_eq!(edge.edge_type, EdgeType::DependsOn);
        assert_eq!(edge.weight, 1.0);
    }

    #[test]
    fn test_edge_type_from_str() {
        assert_eq!(EdgeType::from("depends_on"), EdgeType::DependsOn);
        assert_eq!(EdgeType::from("produces"), EdgeType::Produces);
        assert_eq!(EdgeType::from("custom_rel"), EdgeType::Custom("custom_rel".into()));
    }
}
