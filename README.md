# QuickNote

A minimal, semi-transparent floating note-taking app for macOS. Lives in the menu bar, stays out of your way.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange)

## Features

- **Floating HUD panel** — semi-transparent, always on top, across all spaces
- **Buckets** — group sections into tabs; click `+` to add, double-click a tab to rename, click `×` on a tab to close
- **Sections** — multiple independent note cards in one window
- **Search** — `Cmd+F` to open the search bar, `Esc` to dismiss
- **Drag to reorder** — rearrange sections by dragging the handle
- **Multi-select & merge** — `Cmd+click` sections to select them, then merge into one
- **Copy button** — copy any section's content with one click
- **Duplicate button** — duplicate a section and place it directly below, cursor moves to the new one
- **Tab navigation** — `Tab` / `Shift+Tab` cycles focus between sections
- **Hover highlight** — sections brighten on mouse over
- **Smart links** — URLs auto-collapse to domain; double-click to expand/collapse, `Option+click` to open
- **Auto-focus** — reopening the panel focuses the last section you were in
- **Per-bucket focus** — switching tabs resumes at the last section you edited in that tab
- **Undo / Redo** — per-keystroke undo, not all-at-once
- **Restore deleted section** — `Option+Shift+T` or click the **Undo** button that appears after deletion
- **Restore closed tab** — `Cmd+Shift+T` restores the most recently closed tab with all its sections
- **Auto-save** — notes persist automatically between sessions
- **Remembers layout** — window size and position restore across launches
- **Drag anywhere** — move the panel by grabbing any empty background area
- **Hide on outside click** — panel dismisses when you click away
- **No dock icon** — lives quietly in the menu bar

## Shortcuts

| Action | How |
|---|---|
| Show / hide | `Cmd+Shift+Space` or click the **N** menu bar icon |
| New section | `Cmd+Shift+N` or type ` ``` ` anywhere in a section |
| Switch bucket | Click a tab at the top |
| New bucket | Click `+` in the tab bar |
| Rename bucket | Double-click its tab |
| Close bucket | Click `×` on its tab |
| Restore closed bucket | `Cmd+Shift+T` |
| Restore deleted section | `Option+Shift+T` |
| Search | `Cmd+F` to open, `Esc` to close |
| Navigate sections | `Tab` / `Shift+Tab` |
| Select sections | `Cmd+click` |
| Merge selected | Click **Merge** (appears when 2+ sections selected) |
| Copy section | Click copy icon in the section header |
| Duplicate section | Click duplicate icon in the section header |
| Delete section | Click `×` in the section header |
| Open link | `Option+click` on a URL |
| Expand / collapse link | Double-click on a URL |
| Cut / Copy / Paste | `Cmd+X` / `Cmd+C` / `Cmd+V` |
| Undo / Redo | `Cmd+Z` / `Cmd+Shift+Z` |
| Select all | `Cmd+A` |
| Hide panel | `Cmd+Shift+Space` or click outside the window |

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
