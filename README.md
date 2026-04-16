# QuickNote

A minimal, semi-transparent floating note-taking app for macOS. Lives in the menu bar, stays out of your way.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange)

## Features

- **Floating HUD panel** — semi-transparent, always on top, across all spaces
- **Sections** — multiple independent note cards in one window
- **Search** — filter sections instantly with highlighted matches
- **Drag to reorder** — rearrange sections by dragging the `· · ·` handle
- **Multi-select & merge** — `Cmd+click` sections to select them, then merge into one
- **Copy button** — copy any section's content with one click (`⎘`)
- **Tab navigation** — `Tab` / `Shift+Tab` cycles focus between sections
- **Hover highlight** — sections brighten on mouse over
- **Smart links** — URLs auto-collapse to domain; double-click to expand/collapse, `Option+click` to open
- **Auto-focus** — reopening the panel focuses the last section you were in
- **Undo / Redo** — per-keystroke undo, not all-at-once
- **Auto-save** — notes persist automatically between sessions
- **Remembers layout** — window size and position restore across launches
- **Hide on outside click** — panel dismisses when you click away
- **No dock icon** — lives quietly in the menu bar

## Shortcuts

| Action | How |
|---|---|
| Show / hide | `Cmd+Shift+Space` or click the **N** menu bar icon |
| New section | `Cmd+Shift+N` or type ` ``` ` anywhere in a section |
| Navigate sections | `Tab` / `Shift+Tab` |
| Select sections | `Cmd+click` |
| Merge selected | Click **⊕ Merge** (appears when 2+ sections selected) |
| Copy section | Click `⎘` in the section header |
| Delete section | Click `×` in the section header |
| Open link | `Option+click` on a URL |
| Expand / collapse link | Double-click on a URL |
| Cut / Copy / Paste | `Cmd+X` / `Cmd+C` / `Cmd+V` |
| Undo / Redo | `Cmd+Z` / `Cmd+Shift+Z` |
| Select all | `Cmd+A` |
| Hide panel | Click outside the window or `×` button |

## Install

### Requirements

- macOS 13 (Ventura) or later
- Xcode Command Line Tools

Install the command line tools if you don't have them:

```bash
xcode-select --install
```

### Build & Run

```bash
git clone https://git.corp.adobe.com/tudose/QuickNote.git
cd QuickNote
./build.sh
open build/QuickNote.app
```

The app will appear as an **N** icon in your menu bar.

> **First launch:** macOS may show a security warning for unsigned apps. Go to **System Settings → Privacy & Security** and click **Open Anyway**.

### Optional: Keep it running at login

1. Open **System Settings → General → Login Items**
2. Click `+` and select `QuickNote.app` from the `build/` folder
