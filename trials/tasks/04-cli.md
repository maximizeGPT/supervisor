# Task 4: Wire a minimal CLI

Create `Sources/TrialCLI/main.swift` (a new executable target) with:
- `add <title>` — creates and persists a new Item
- `list` — prints all items (title + complete status)
- `done <id-prefix>` — marks an item complete by UUID prefix match
- Uses `ItemStore` with a default path of `~/.trial-items.json`

Add the `TrialCLI` executable target to Package.swift.
Commit when done.
