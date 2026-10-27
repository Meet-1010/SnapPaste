/// Undo/redo stacks of whole editor states.
///
/// States are cheap to keep: annotations are small value types and images are shared references,
/// so only crop/resize steps hold extra bitmaps.
public struct EditHistory<State> {
    public struct Entry {
        public let state: State
        public let actionName: String
        let coalescingKey: String?
    }

    public private(set) var undoStack: [Entry] = []
    public private(set) var redoStack: [Entry] = []
    public let limit: Int

    public init(limit: Int = 100) {
        self.limit = max(1, limit)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoActionName: String? { undoStack.last?.actionName }
    public var redoActionName: String? { redoStack.last?.actionName }

    /// Records the state before a change. Consecutive changes with the same non-nil `coalescingKey`
    /// (for example dragging a thickness slider) collapse into one undo step.
    public mutating func record(previous: State, actionName: String, coalescingKey: String? = nil) {
        redoStack.removeAll()
        if let key = coalescingKey, undoStack.last?.coalescingKey == key { return }
        undoStack.append(Entry(state: previous, actionName: actionName, coalescingKey: coalescingKey))
        if undoStack.count > limit {
            undoStack.removeFirst(undoStack.count - limit)
        }
    }

    /// Ends any coalescing run so the next change starts a new undo step.
    public mutating func breakCoalescing() {
        guard let last = undoStack.popLast() else { return }
        undoStack.append(Entry(state: last.state, actionName: last.actionName, coalescingKey: nil))
    }

    public mutating func undo(current: State) -> State? {
        guard let entry = undoStack.popLast() else { return nil }
        redoStack.append(Entry(state: current, actionName: entry.actionName, coalescingKey: nil))
        return entry.state
    }

    public mutating func redo(current: State) -> State? {
        guard let entry = redoStack.popLast() else { return nil }
        undoStack.append(Entry(state: current, actionName: entry.actionName, coalescingKey: nil))
        return entry.state
    }

    public mutating func removeAll() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
