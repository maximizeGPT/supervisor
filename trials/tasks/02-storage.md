# Task 2: Add JSON persistence

Create `Sources/TrialLib/Storage/ItemStore.swift` with:
- A `class ItemStore` that reads/writes `[Item]` to a JSON file
- `init(path: URL)` — the file path for persistence
- `func load() throws -> [Item]` — reads and decodes
- `func save(_ items: [Item]) throws` — encodes and writes
- `func add(_ item: Item) throws` — appends and saves

Write a test in `Tests/TrialLibTests/ItemStoreTests.swift` that:
- Creates a temp file
- Adds 3 items
- Loads and verifies count == 3
- Cleans up

Commit when done.
