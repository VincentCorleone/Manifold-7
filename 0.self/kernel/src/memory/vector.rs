// Vector memory — semantic embedding storage with similarity search

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Distance metric for vector similarity
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum DistanceMetric {
    /// Euclidean (L2) distance
    Euclidean,
    /// Cosine similarity (1 - cosine_distance)
    Cosine,
    /// Dot product (higher = more similar)
    DotProduct,
}

/// A single vector entry in memory
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VectorEntry {
    /// Unique key
    pub key: String,

    /// The embedding vector
    pub vector: Vec<f32>,

    /// Associated metadata
    pub metadata: HashMap<String, String>,

    /// Timestamp
    pub created_at: f64,
}

impl VectorEntry {
    pub fn new(key: impl Into<String>, vector: Vec<f32>) -> Self {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs_f64();

        Self {
            key: key.into(),
            vector,
            metadata: HashMap::new(),
            created_at: now,
        }
    }

    pub fn with_metadata(mut self, k: impl Into<String>, v: impl Into<String>) -> Self {
        self.metadata.insert(k.into(), v.into());
        self
    }
}

/// In-memory vector store with nearest-neighbor search
///
/// This is a simple brute-force implementation suitable for up to ~100K vectors.
/// Production deployments should replace with FAISS/Milvus/Qdrant backend.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VectorMemory {
    entries: HashMap<String, VectorEntry>,
}

impl VectorMemory {
    /// Create a new empty vector memory
    pub fn new() -> Self {
        Self {
            entries: HashMap::new(),
        }
    }

    /// Number of stored vectors
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Check if empty
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Insert a vector entry
    pub fn insert(&mut self, entry: VectorEntry) {
        self.entries.insert(entry.key.clone(), entry);
    }

    /// Get a vector entry by key
    pub fn get(&self, key: &str) -> Option<&VectorEntry> {
        self.entries.get(key)
    }

    /// Remove a vector entry
    pub fn remove(&mut self, key: &str) -> Option<VectorEntry> {
        self.entries.remove(key)
    }

    /// Search for nearest neighbors
    ///
    /// Returns up to `k` entries sorted by distance (closest first).
    pub fn search(
        &self,
        query: &[f32],
        k: usize,
        metric: DistanceMetric,
    ) -> Vec<(f32, &VectorEntry)> {
        let mut results: Vec<(f32, &VectorEntry)> = self
            .entries
            .values()
            .map(|entry| {
                let dist = Self::distance(query, &entry.vector, metric);
                (dist, entry)
            })
            .collect();

        // Sort by distance (ascending for Euclidean/Cosine, descending for dot product)
        results.sort_by(|a, b| {
            if metric == DistanceMetric::DotProduct {
                b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal)
            } else {
                a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal)
            }
        });

        results.truncate(k);
        results
    }

    /// Compute distance between two vectors
    pub fn distance(a: &[f32], b: &[f32], metric: DistanceMetric) -> f32 {
        if a.len() != b.len() {
            return f32::INFINITY;
        }

        match metric {
            DistanceMetric::Euclidean => {
                let sum: f32 = a.iter().zip(b.iter()).map(|(x, y)| (x - y).powi(2)).sum();
                sum.sqrt()
            }
            DistanceMetric::Cosine => {
                let dot: f32 = a.iter().zip(b.iter()).map(|(x, y)| x * y).sum();
                let norm_a: f32 = a.iter().map(|x| x.powi(2)).sum::<f32>().sqrt();
                let norm_b: f32 = b.iter().map(|x| x.powi(2)).sum::<f32>().sqrt();
                if norm_a == 0.0 || norm_b == 0.0 {
                    1.0 // max distance for zero vectors
                } else {
                    1.0 - dot / (norm_a * norm_b)
                }
            }
            DistanceMetric::DotProduct => {
                a.iter().zip(b.iter()).map(|(x, y)| x * y).sum()
            }
        }
    }
}

impl Default for VectorMemory {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_insert_and_search() {
        let mut mem = VectorMemory::new();
        mem.insert(VectorEntry::new("a", vec![1.0, 0.0, 0.0]));
        mem.insert(VectorEntry::new("b", vec![0.0, 1.0, 0.0]));
        mem.insert(VectorEntry::new("c", vec![1.0, 1.0, 0.0]));

        let results = mem.search(&[1.0, 0.0, 0.0], 2, DistanceMetric::Cosine);
        assert_eq!(results.len(), 2);
        assert_eq!(results[0].1.key, "a"); // exact match should be first
    }

    #[test]
    fn test_euclidean_distance() {
        let d = VectorMemory::distance(
            &[0.0, 0.0],
            &[3.0, 4.0],
            DistanceMetric::Euclidean,
        );
        assert!((d - 5.0).abs() < 0.001);
    }

    #[test]
    fn test_cosine_similarity() {
        // Same vector → distance 0
        let d = VectorMemory::distance(
            &[1.0, 0.0],
            &[1.0, 0.0],
            DistanceMetric::Cosine,
        );
        assert!(d.abs() < 0.001);

        // Orthogonal → distance 1
        let d = VectorMemory::distance(
            &[1.0, 0.0],
            &[0.0, 1.0],
            DistanceMetric::Cosine,
        );
        assert!((d - 1.0).abs() < 0.001);
    }
}
