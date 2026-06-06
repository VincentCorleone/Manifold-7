// Graph store — the core graph data structure

use std::collections::{HashMap, HashSet, VecDeque};
use serde::{Deserialize, Serialize};

use super::{Node, NodeId, Edge, EdgeId, EdgeType};

/// ManifoldGraph — directed property graph with semantic edges
///
/// This is the core data structure of the M7 Kernel layer.
/// All intent decompositions, task dependencies, and knowledge
/// representations are stored as graphs.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Graph {
    /// All nodes indexed by ID
    nodes: HashMap<NodeId, Node>,

    /// All edges indexed by ID
    edges: HashMap<EdgeId, Edge>,

    /// Adjacency list: node → outgoing edge IDs
    outgoing: HashMap<NodeId, Vec<EdgeId>>,

    /// Reverse adjacency: node → incoming edge IDs
    incoming: HashMap<NodeId, Vec<EdgeId>>,

    /// Graph metadata
    pub name: String,
    pub version: String,
}

impl Graph {
    /// Create a new empty graph
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            nodes: HashMap::new(),
            edges: HashMap::new(),
            outgoing: HashMap::new(),
            incoming: HashMap::new(),
            name: name.into(),
            version: crate::VERSION.to_string(),
        }
    }

    /// Number of nodes in the graph
    pub fn node_count(&self) -> usize {
        self.nodes.len()
    }

    /// Number of edges in the graph
    pub fn edge_count(&self) -> usize {
        self.edges.len()
    }

    // ─── Node Operations ───────────────────────────────────────

    /// Add a node to the graph
    pub fn add_node(&mut self, node: Node) -> NodeId {
        let id = node.id;
        self.nodes.insert(id, node);
        self.outgoing.entry(id).or_default();
        self.incoming.entry(id).or_default();
        id
    }

    /// Get a node by ID
    pub fn get_node(&self, id: &NodeId) -> Option<&Node> {
        self.nodes.get(id)
    }

    /// Remove a node and all its edges
    pub fn remove_node(&mut self, id: &NodeId) -> Option<Node> {
        // Remove all edges connected to this node
        if let Some(out_edges) = self.outgoing.remove(id) {
            for eid in &out_edges {
                if let Some(edge) = self.edges.remove(eid) {
                    if let Some(in_list) = self.incoming.get_mut(&edge.to) {
                        in_list.retain(|e| e != eid);
                    }
                }
            }
        }
        if let Some(in_edges) = self.incoming.remove(id) {
            for eid in &in_edges {
                if let Some(edge) = self.edges.remove(eid) {
                    if let Some(out_list) = self.outgoing.get_mut(&edge.from) {
                        out_list.retain(|e| e != eid);
                    }
                }
            }
        }
        self.nodes.remove(id)
    }

    /// Get all nodes of a specific type
    pub fn nodes_by_type(&self, node_type: &str) -> Vec<&Node> {
        self.nodes
            .values()
            .filter(|n| n.node_type == node_type)
            .collect()
    }

    // ─── Edge Operations ───────────────────────────────────────

    /// Add an edge to the graph
    pub fn add_edge(&mut self, edge: Edge) -> EdgeId {
        let id = edge.id;
        self.outgoing.entry(edge.from).or_default().push(id);
        self.incoming.entry(edge.to).or_default().push(id);
        self.edges.insert(id, edge);
        id
    }

    /// Get an edge by ID
    pub fn get_edge(&self, id: &EdgeId) -> Option<&Edge> {
        self.edges.get(id)
    }

    /// Remove an edge
    pub fn remove_edge(&mut self, id: &EdgeId) -> Option<Edge> {
        if let Some(edge) = self.edges.remove(id) {
            if let Some(out_list) = self.outgoing.get_mut(&edge.from) {
                out_list.retain(|e| e != id);
            }
            if let Some(in_list) = self.incoming.get_mut(&edge.to) {
                in_list.retain(|e| e != id);
            }
            Some(edge)
        } else {
            None
        }
    }

    // ─── Traversal ─────────────────────────────────────────────

    /// Get outgoing edges from a node
    pub fn outgoing_edges(&self, node_id: &NodeId) -> Vec<&Edge> {
        self.outgoing
            .get(node_id)
            .map(|ids| ids.iter().filter_map(|eid| self.edges.get(eid)).collect())
            .unwrap_or_default()
    }

    /// Get incoming edges to a node
    pub fn incoming_edges(&self, node_id: &NodeId) -> Vec<&Edge> {
        self.incoming
            .get(node_id)
            .map(|ids| ids.iter().filter_map(|eid| self.edges.get(eid)).collect())
            .unwrap_or_default()
    }

    /// Get direct successors (outgoing neighbors)
    pub fn successors(&self, node_id: &NodeId) -> Vec<&Node> {
        self.outgoing_edges(node_id)
            .iter()
            .filter_map(|e| self.nodes.get(&e.to))
            .collect()
    }

    /// Get direct predecessors (incoming neighbors)
    pub fn predecessors(&self, node_id: &NodeId) -> Vec<&Node> {
        self.incoming_edges(node_id)
            .iter()
            .filter_map(|e| self.nodes.get(&e.from))
            .collect()
    }

    /// Topological sort of the graph (Kahn's algorithm).
    /// Returns None if the graph contains a cycle.
    pub fn topological_sort(&self) -> Option<Vec<NodeId>> {
        let mut in_degree: HashMap<NodeId, usize> = HashMap::new();
        for node_id in self.nodes.keys() {
            in_degree.insert(*node_id, self.incoming_edges(node_id).len());
        }

        let mut queue: VecDeque<NodeId> = in_degree
            .iter()
            .filter(|(_, &deg)| deg == 0)
            .map(|(id, _)| *id)
            .collect();

        let mut result = Vec::with_capacity(self.nodes.len());

        while let Some(node_id) = queue.pop_front() {
            result.push(node_id);
            for succ in self.successors(&node_id) {
                let deg = in_degree.get_mut(&succ.id).unwrap();
                *deg -= 1;
                if *deg == 0 {
                    queue.push_back(succ.id);
                }
            }
        }

        if result.len() == self.nodes.len() {
            Some(result)
        } else {
            None // cycle detected
        }
    }

    /// Check if the graph has a cycle
    pub fn has_cycle(&self) -> bool {
        self.topological_sort().is_none()
    }

    /// Find all nodes reachable from `start` via BFS
    pub fn reachable_from(&self, start: &NodeId) -> HashSet<NodeId> {
        let mut visited = HashSet::new();
        let mut queue = VecDeque::new();
        queue.push_back(*start);

        while let Some(current) = queue.pop_front() {
            if !visited.insert(current) {
                continue;
            }
            for succ in self.successors(&current) {
                if !visited.contains(&succ.id) {
                    queue.push_back(succ.id);
                }
            }
        }

        visited
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_test_graph() -> Graph {
        let mut g = Graph::new("test");
        let a = Node::new("task", "analyze");
        let b = Node::new("task", "compose");
        let c = Node::new("task", "send");
        let a_id = g.add_node(a);
        let b_id = g.add_node(b);
        let c_id = g.add_node(c);
        g.add_edge(Edge::new(a_id, b_id, EdgeType::DependsOn));
        g.add_edge(Edge::new(b_id, c_id, EdgeType::DependsOn));
        g
    }

    #[test]
    fn test_topological_sort() {
        let g = make_test_graph();
        let order = g.topological_sort().unwrap();
        assert_eq!(order.len(), 3);
    }

    #[test]
    fn test_no_cycle() {
        let g = make_test_graph();
        assert!(!g.has_cycle());
    }

    #[test]
    fn test_edge_removal() {
        let mut g = make_test_graph();
        let edges: Vec<EdgeId> = g.edges.keys().cloned().collect();
        assert_eq!(g.edge_count(), 2);
        g.remove_edge(&edges[0]);
        assert_eq!(g.edge_count(), 1);
    }
}
