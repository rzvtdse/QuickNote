# QuickNote

A minimal, semi-transparent floating note-taking app for macOS. Lives in the menu bar, stays out of your way.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange)

## Features

- **Floating HUD panel** — semi-transparent, always on top, across all spaces
- **Sections** — multiple independent note cards in one window
- **Search** — filter sections instantly with highlighted matches
- **Drag to reorder** — rearrange sections by dragging the handle
- **Copy button** — copy any section's content with one click
- **Auto-save** — notes persist automatically between sessions
- **No dock icon** — lives quietly in the menu bar

## Shortcuts

| Action | How |
|---|---|
| Show / hide | `Cmd+Shift+Space` or click the **N** icon in the menu bar |
| New section | Type ` ``` ` (3 backticks) at the end of a section |
| Copy section | Click the `⎘` button in the section header |
| Delete section | Click the `×` button in the section header |
| Paste / Undo | `Cmd+V` / `Cmd+Z` |
| Hide | Click outside the window |

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
