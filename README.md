# Graphics Script Editor

Native macOS editor for `Graphics Script` files with live syntax highlighting,
validation, and structure-aware indentation.

## Overview

`Graphics Script Editor` is a dedicated, reusable editor for `.gsc` files. It
knows the shared graphics-script DSL and can be extended with command definitions
for each tool that uses the format. It was originally developed for the
application presented in the paper *"Reassessing Quality, Performance, and
Reproducibility of Higher-Order Filtering and Virtual Samples in Volume
Rendering"*.

The editor is built for writing and checking graphics scripts quickly, without
forcing that work into a general-purpose text editor.

The app combines a native editing experience with just enough IDE behavior to be useful:

- live syntax highlighting and diagnostics
- script-aware indentation
- smart block pasting
- tool-specific command and function definitions
- configurable appearance

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
- External command definitions are applied immediately to validation and syntax
  highlighting

### Command Definitions

The editor always knows the base graphics-script DSL and base tool commands.
Application-specific commands can be loaded from a human-readable `.gsccommands`
file. Each non-empty line defines one signature:

```text
commandName(type, type)
commandWithNoArguments()
matrixCommand(float * 16)
input(string) -> string
```

Supported argument types are `int`, `int64`, `uint32`, `bool`, `float`,
`double`, `string`, and `restString`. Use repeated lines for overloads. Lines
can contain `#` comments. A definition without `->` is an ordinary command.
A definition with `-> returnType` is a value-returning function that can be
used on the right-hand side of `set`:

```text
input(string) -> string
fileinput(string) -> string
dirinput(string) -> string
```

With those definitions loaded, these script lines are valid:

```text
set name input "Enter your name"
set file fileinput "Select a file"
set directory dirinput "Select a directory"
```

Single- and double-quoted script arguments can contain whitespace. Function
overloads are declared by repeating the function name with another signature.

Definitions loaded manually and definitions referenced by the current script are
combined. Loading a definition file or changing the reference in the script
updates validation and syntax highlighting immediately; reopening the script is
not required.

Load a definition file with the `Commands` toolbar button or the corresponding
menu command. To load definitions automatically, put their path in the first
comment found in the script:

```text
# CommandDefinitions/volume-renderer.gsccommands
```

Relative paths are resolved next to the script file. The sample volume-renderer
definitions live in `CommandDefinitions/volume-renderer.gsccommands`. In a
sandboxed build, the editor first explains why access is needed and then opens a
dedicated command-definition dialog already pointed at the referenced file. The
user may decline; in that case the definitions cannot be loaded and otherwise
valid tool-specific commands may be reported as errors. Granted access is
remembered for future use.

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

- macOS 15+
- Xcode 16 or newer

## Getting Started

1. Open `GraphicsScriptEditor.xcodeproj` in Xcode.
2. Build and run the `Graphics Script Editor` target.
3. Open or create a `.gsc` file and start editing.

## Typical Workflow

1. Double-click a `.gsc` file in Finder or open one from inside the app.
2. Load a `.gsccommands` file manually or reference it in the script's first
   comment when the target tool adds commands to the base DSL.
3. Edit the script with live syntax highlighting and diagnostics.
4. Use the built-in indentation support to keep block structure clean.

## Screenshots

![Main Window](docs/main-window.png)
