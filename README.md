# Graphics Script Editor

Native macOS editor for `Graphics Script` files with live validation, structure-aware indentation, and one-click execution.

## Overview

`Graphics Script Editor` is a dedicated script editor for `.gsc` files. It is built for the workflow of writing, checking, and running graphics scripts quickly, without forcing that work into a general-purpose text editor.

The app combines a native editing experience with just enough IDE behavior to be useful:

- live syntax diagnostics
- script-aware indentation
- smart block pasting
- configurable appearance
- direct runner integration

## Why It Exists

Graphics scripts tend to be edited in tools that understand plain text but not the structure of the language. That leads to avoidable friction:

- indentation drifts out of sync
- syntax issues are only discovered at runtime
- running scripts requires manual command-line steps
- opening scripts from Finder has no dedicated editing experience

This project narrows the scope on purpose. It focuses on the actual authoring loop for Graphics Script files and keeps everything else out of the way.

## Features

### Editing

- Native macOS editor for `.gsc` files
- Open, save, and save-as with `gsc` as the default extension
- Line numbers and cursor position display
- Configurable font, font size, indentation style, and syntax colors
- Optional autosave

### Structure Awareness

- Block-aware indentation for:
  - `if`
  - `else`
  - `endif`
  - `repeat`
  - `endrepeat`
- Paste behavior that reindents pasted blocks to the current code context
- Indentation correction command for normalizing existing scripts

### Validation

- Live syntax checking while editing
- Diagnostics with line-numbered error reporting
- Validation powered by the built-in command interpreter in validation mode

### Execution

- Configure an external runner executable in Settings
- Run the current script directly from the editor
- Captures and displays combined standard output and error output

The runner is invoked as:

```bash
<runner> --script <file>
```

### macOS Integration

- Registers `.gsc` as a dedicated document type
- Supports opening files directly from Finder
- Restores open file-backed tabs on launch when enabled
- Tracks recent files

## File Type

The project exports this Uniform Type Identifier:

- UTI: `de.cgvis.graphicsscript`
- Extension: `.gsc`
- Conforms to: `public.plain-text`

## Build Requirements

- macOS 13+
- Xcode 16+ recommended

## Getting Started

1. Open `GraphicsScriptEditor.xcodeproj` in Xcode.
2. Build and run the `Graphics Script Editor` target.
3. Open `Settings`.
4. Choose the external runner executable you want the app to use.
5. Open or create a `.gsc` file and start editing.

## Typical Workflow

1. Double-click a `.gsc` file in Finder or open one from inside the app.
2. Edit the script with live syntax highlighting and diagnostics.
3. Use the built-in indentation support to keep block structure clean.
4. Run the script through your configured external executable.
5. Inspect output directly inside the editor.

## Screenshots

Add screenshots here once you have them. A good set would be:

- main editor window
- syntax diagnostics panel
- settings window
- `.gsc` file opened from Finder

Example:

```md
![Main Window](docs/screenshots/main-window.png)
![Settings](docs/screenshots/settings.png)
```

## Project Structure

```text
Sources/
├── CommandInterpreter.swift
├── ContentView.swift
├── Diagnostics.swift
├── DSLCommandSet.swift
├── DslIdeApp.swift
├── DSLValidator.swift
├── EditorModel.swift
├── EditorTextView.swift
├── ScriptRunner.swift
├── SecurityScopedAccess.swift
├── SettingsView.swift
└── SyntaxHighlighter.swift
```

## Design Notes

- The editor is intentionally specialized rather than general-purpose.
- Validation and execution are separate concerns: syntax is checked locally, execution is delegated to the configured external runner.
- The UI uses SwiftUI for the app shell and AppKit where tighter control over text editing behavior is needed.

## Roadmap Ideas

- document icon for `.gsc` files
- richer diagnostics with multiple errors per file
- command completion / autocomplete
- script templates
- integrated runner presets
- search in project / multi-file workflows

## License

Add your preferred license here.
