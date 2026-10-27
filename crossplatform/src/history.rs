//! Undo/redo of whole editor states. Images are `Arc`s, so most snapshots share pixel storage.

use crate::annotate::Annotation;
use image::RgbaImage;
use std::sync::Arc;

#[derive(Clone)]
pub struct EditorState {
    pub image: Arc<RgbaImage>,
    pub annotations: Vec<Annotation>,
}

impl PartialEq for EditorState {
    fn eq(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.image, &other.image) && self.annotations == other.annotations
    }
}

struct Entry<S> {
    state: S,
    name: String,
    key: Option<String>,
}

pub struct History<S> {
    undo: Vec<Entry<S>>,
    redo: Vec<Entry<S>>,
    limit: usize,
}

impl<S> History<S> {
    pub fn new(limit: usize) -> Self {
        Self { undo: Vec::new(), redo: Vec::new(), limit: limit.max(1) }
    }

    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }

    pub fn undo_name(&self) -> Option<&str> {
        self.undo.last().map(|e| e.name.as_str())
    }

    /// Records the state before a change. Consecutive changes with the same `key`
    /// (a slider drag, arrow-key nudges) become one undo step.
    pub fn record(&mut self, previous: S, name: &str, key: Option<&str>) {
        self.redo.clear();
        if key.is_some() && self.undo.last().and_then(|e| e.key.as_deref()) == key {
            return;
        }
        self.undo.push(Entry { state: previous, name: name.to_string(), key: key.map(str::to_string) });
        if self.undo.len() > self.limit {
            let excess = self.undo.len() - self.limit;
            self.undo.drain(..excess);
        }
    }

    pub fn break_coalescing(&mut self) {
        if let Some(last) = self.undo.last_mut() {
            last.key = None;
        }
    }

    pub fn undo(&mut self, current: S) -> Option<S> {
        let entry = self.undo.pop()?;
        self.redo.push(Entry { state: current, name: entry.name.clone(), key: None });
        Some(entry.state)
    }

    pub fn redo(&mut self, current: S) -> Option<S> {
        let entry = self.redo.pop()?;
        self.undo.push(Entry { state: current, name: entry.name.clone(), key: None });
        Some(entry.state)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn undo_redo_order_and_redo_clearing() {
        let mut h = History::new(10);
        h.record(0, "A", None);
        h.record(1, "B", None);
        assert_eq!(h.undo(2), Some(1));
        assert_eq!(h.undo(1), Some(0));
        assert_eq!(h.undo(0), None);
        assert_eq!(h.redo(0), Some(1));
        h.record(1, "C", None);
        assert!(!h.can_redo());
    }

    #[test]
    fn coalescing_and_limit() {
        let mut h = History::new(3);
        h.record(0, "Width", Some("w"));
        h.record(1, "Width", Some("w"));
        h.record(2, "Width", Some("w"));
        assert_eq!(h.undo(3), Some(0));
        for i in 0..10 {
            h.record(i, "X", None);
        }
        assert_eq!(h.undo(99), Some(9));
        assert_eq!(h.undo(9), Some(8));
        assert_eq!(h.undo(8), Some(7));
        assert_eq!(h.undo(7), None);
    }
}
