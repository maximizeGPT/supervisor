# Task 3: Add filtering and search

Add to `ItemStore`:
- `func incomplete() throws -> [Item]` — returns items where isComplete == false
- `func search(_ query: String) throws -> [Item]` — case-insensitive title search
- `func toggleComplete(id: UUID) throws` — flips isComplete for the item with that id

Add tests for all three methods. Commit when done.
