# QuickNote

A lightweight, always-on-top note app that lives in your Mac's menu bar. Press a shortcut to pop it open, jot something down, and click away to dismiss it. No windows to manage, no dock icon.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange)

---

## What it looks like

A semi-transparent floating panel, slightly warm-tinted, that stays above all your other windows and follows you across Spaces. It remembers where you left it, what size it was, and which section you were last editing.

---

## Core concepts

**Tabs** — organize your notes into separate workspaces (e.g. Work, Personal, Travel). Each tab is independent — switching tabs resumes where you left off in that tab.

**Sections** — each tab contains one or more note cards. Think of them as sticky notes inside a tab. You can reorder, merge, duplicate, or delete them individually.

---

## Things you can do

### Writing
- Plain text with **strikethrough** (`Cmd+Shift+X`) and **checklists**
- Type `/list` + `Enter` or press `Cmd+Option+L` to start a checklist
- Select existing lines and press `Cmd+Option+L` to convert them to checklist items
- Click `☐` / `☑` to check/uncheck items
- URLs auto-collapse to their domain — double-click to expand, `Option+click` to open
- Per-keystroke undo/redo (`Cmd+Z` / `Cmd+Shift+Z`)

### Sections
- `Cmd+Shift+N` or type ` ``` ` anywhere to split into a new section
- Drag the handle on the left to reorder
- `Cmd+click` to select multiple, then **Merge** to combine them into one
- Copy, duplicate, or delete from the section header
- Deleted sections can be restored with `Option+Shift+T` or the **Undo** button

### Tabs
- `Cmd+N` or the `+` button (follows the last tab) to add a new tab
- `Cmd+1` through `Cmd+9` to jump to a tab directly
- Double-click a tab to rename it
- Drag tabs left/right to reorder
- Drag a section onto a tab to move it there
- Closed tabs can be restored with `Cmd+Shift+T`

### Search & navigation
- `Cmd+F` to search across all sections in the current tab
- `Tab` / `Shift+Tab` to move focus between sections

### Export & Import
- Use the `↑` / `↓` icons in the top-right corner to export or import all notes as a `.json` file
- Import offers **Replace** (overwrite everything) or **Merge** (add alongside existing tabs)

---

## Keyboard shortcuts

| Action | Shortcut |
|---|---|
| Show / hide panel | `Cmd+Shift+Space` |
| New section | `Cmd+Shift+N` or type ` ``` ` |
| New tab | `Cmd+N` |
| Switch to tab 1–9 | `Cmd+1` … `Cmd+9` |
| Search | `Cmd+F` / `Esc` to close |
| Start checklist | `/list` + `Enter` or `Cmd+Option+L` |
| Convert selection to checklist | Select lines + `Cmd+Option+L` |
| Strikethrough | `Cmd+Shift+X` |
| Undo / Redo | `Cmd+Z` / `Cmd+Shift+Z` |
| Navigate sections | `Tab` / `Shift+Tab` |
| Restore deleted section | `Option+Shift+T` |
| Restore closed tab | `Cmd+Shift+T` |
| Rename tab | Double-click the tab |
| Reorder tabs | Drag left / right |
| Move section to another tab | Drag section onto a tab |
| Open link | `Option+click` a URL |
| Expand / collapse link | Double-click a URL |

---

## Install

**Requirements:** macOS 13 (Ventura) or later and Xcode Command Line Tools.

```bash
xcode-select --install  # skip if already installed
```

```bash
git clone https://github.com/tudose_adobe/QuickNote.git
cd QuickNote
./build.sh
open build/QuickNote.app
```

The app appears in your menu bar. Click the icon or press `Cmd+Shift+Space` to open it.

> **First launch:** macOS may block unsigned apps. Go to **System Settings → Privacy & Security** and click **Open Anyway**.

### Update

```bash
cd ~/QuickNote && git pull && ./build.sh && pkill -x QuickNote; open build/QuickNote.app
```

### Run at login

1. Open **System Settings → General → Login Items**
2. Click `+` and select `QuickNote.app` from the `build/` folder
