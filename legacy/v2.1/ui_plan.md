# UI Layout Fixes for Matrix Rain Legibility

## Issue Analysis
The visual overlapping between the `MatrixRainView` and the terminal text occurs because the `ScrollView` containing the terminal output in both `ContentView` and `SecurityTerminalView` lacks a background. As a result, the bright Matrix Rain (especially in red during Security mode) clashes directly with the foreground text, making it highly illegible.

## Proposed Layout Changes

### 1. `ContentView.swift` -> `terminalView`
**Current:**
The `ScrollView` displaying the `terminalOutput` has no background defined, rendering it fully transparent.
**Fix:**
Apply a semi-transparent black background to the `ScrollView` to provide contrast while preserving the Matrix Rain aesthetic.
```swift
ScrollView {
    // ... LazyVStack ...
}
.background(Color.black.opacity(0.75)) // <-- Add this
```

### 2. `SecurityTerminalView.swift` -> Terminal Logs
**Current:**
The `ScrollView` explicitly uses `.background(Color.clear)`. The red/white text overlaps with the red Matrix Rain.
**Fix:**
Change the clear background to a dark, semi-transparent backdrop. 
```swift
ScrollView {
    // ... VStack ...
}
.background(Color.black.opacity(0.85)) // <-- Change from Color.clear
.onChange(of: terminalOutput.count) { _, _ in
    // ...
}
```

### 3. `ContentView.swift` -> `activityMonitorView`
**Current:**
The `List` view displaying processes uses `.scrollContentBackground(.hidden)` and `listRowBackground(Color.clear)`.
**Fix:**
Add a background to the `List` as well to maintain visual consistency and ensure legibility across all tabs.
```swift
List(processManager.processes) { process in
    // ...
}
.listStyle(PlainListStyle())
.scrollContentBackground(.hidden)
.background(Color.black.opacity(0.75)) // <-- Add this
```

## Summary
By adding a `Color.black.opacity(0.75)` (or `0.85` for the red security terminal) to the scrolling text areas, we create a dark glass-like overlay. This ensures the terminal text remains highly legible while the Matrix Rain animation continues to play dynamically in the background layer.
