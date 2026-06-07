# Task 1: Scaffold a data model

Create a file `Sources/TrialLib/Models/Item.swift` with:
- A `struct Item` that conforms to `Codable` and `Identifiable`
- Properties: `id: UUID`, `title: String`, `createdAt: Date`, `isComplete: Bool`
- A default initializer that generates a new UUID and sets createdAt to now
- A static `sample` property that returns a pre-filled example

Add the file to the existing Swift package target `TrialLib`.
Commit when done.
