# Disk Sweeper

A small native macOS app (SwiftUI) that shows what's eating your disk — especially the mysterious **"System Data"** — and helps you clean it up safely.

## Features

- **Common Locations** — measures ~30 known space hogs (caches, logs, temp files, Trash, Downloads, Xcode DerivedData/Archives/DeviceSupport, simulators, iPhone backups, Docker, app containers, Homebrew, npm/pip/HuggingFace caches, Ollama models, …), sorted by size. Each is tagged **Safe to delete**, **Review first**, or **Careful**. Expand any row to see its 25 largest items.
- **Large Files** — finds files in your home folder over a size threshold (default 500 MB).
- **Tips** — lists Time Machine local snapshots and handy cleanup commands.
- Reveal in Finder, Move to Trash (with confirmation), and Empty Trash.

Deletions always go to the Trash — nothing is removed permanently until you empty it.

## Requirements

- macOS 14 or later
- Xcode or the Xcode Command Line Tools (`swiftc`, `actool`) — Xcode 26+ is needed to compile the `.icon` app icon

## Build & run

```bash
git clone https://github.com/tphuc/DiskSweeper.git
cd DiskSweeper
./build.sh
open DiskSweeper.app
```

`build.sh` compiles `DiskSweeper.swift` with `swiftc`, compiles `DiskSweeper.icon` with `actool`, and assembles `DiskSweeper.app` in the project folder. Drag it to `/Applications` if you want to keep it.

## Full Disk Access

Some folders (Mail, Messages, app Containers) report too small a size without Full Disk Access. Grant it in **System Settings → Privacy & Security → Full Disk Access**, add `DiskSweeper.app`, then click **Rescan**.
