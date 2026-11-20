<img src="icon.png" alt="zbuf icon" width="128" align="right">

# zbuf

One zathura window, many documents. zbuf keeps a single zathura pane open and 
offer tab like switching across files with natively-styled menus. It wraps around
zathura to get, what is my opinion, better behavior than the default. 

Tested on macOS.

## Install

You need zathura with a PDF plugin (mupdf or poppler), zathura's development
headers, pkg-config, a C compiler and D-Bus. sqlite3 is optional; zbuf uses it
to reopen the last document you read.

```sh
# macOS (Homebrew)
brew install zathura zathura-pdf-mupdf pkg-config dbus

# Arch
sudo pacman -S zathura zathura-pdf-mupdf base-devel sqlite

# Debian, Ubuntu
sudo apt install zathura zathura-dev libgirara-dev libgtk-3-dev build-essential pkg-config dbus sqlite3

# Fedora
sudo dnf install zathura zathura-devel zathura-pdf-mupdf girara-devel gtk3-devel gcc pkgconf dbus-tools sqlite
```

Then, from a clone of this repo:

```sh
./install.sh             # rerun after upgrading zathura
./install.sh uninstall   # undoes all of it
```

This builds zbuf's library, links `zbuf` into `~/.local/bin` (set `BINDIR` to
change that), and adds a launcher so a file manager can open documents in zbuf:
`~/Applications/zbuf.app` on macOS, a `zbuf.desktop` entry in your applications
menu on Linux.

On Homebrew, zathura-pdf-mupdf has to be linked into zathura's plugin folder
for zathura to see it (`brew info zathura-pdf-mupdf` shows how); the installer
tells you if no PDF plugin is found.

## Use

```sh
zbuf paper.pdf book.epub   # start, or add files to the running window
zbuf                       # reopen what you had open last time
```

Closing the window keeps its buffer list. The next session starts with those
buffers again, oldest read first, and leaves out files that are gone or that
you haven't read in 30 days (`ZBUF_KEEP_DAYS` changes that). Starting with no
files shows the one you read last.

In the window:

| key        | does                                   |
|------------|----------------------------------------|
| `o`        | files in the current folder            |
| `b`        | open buffers                           |
| `gt` / `gT`| next / previous buffer                 |
| `gd`       | close the buffer                       |
| `Tab`      | table of contents (native zathura)     |

In the `o` and `b` menus: `j`/`k` move, `Enter` or `l` opens, `-` or `h` goes up
a folder, `~` goes home, `b`/`o` swap menus, `q` or `Esc` closes.

From a shell: `zbuf next`, `zbuf prev`, `zbuf close`, `zbuf list`, `zbuf quit`.

Pages are remembered per file by zathura's own history, as usual.

## EPUBs with math (macOS)

MuPDF has no MathML support, so equations in EPUBs come out as a flat run of
symbols. On macOS, `./install.sh` also builds `zathura-epub-webkit/`, and zbuf
opens EPUBs through it instead: WebKit, the engine behind Safari and Apple
Books, lays the book out into pages, so equations, SVG and modern CSS look the
way they do in Apple Books, and each chapter scrolls as one column (zbuf drops
the gap between pages while an EPUB is up). MuPDF still opens PDFs. An open
EPUB costs about 125 MB (WebKit runs in its own processes); the first open of a
book takes a couple of seconds to lay it out, later opens are instant. Page
numbers differ from MuPDF's, so a position saved under MuPDF lands a little off
once. If the plugin isn't built, EPUBs open with MuPDF as before. Set
`ZBUF_EPUB_PLUGIN` to use a build somewhere else.

## Memory Footprint

Measured with 10 PDFs (88 KB to 2 MB), `page-cache-size 100`, and 20 pages 
read in each. Memory is footprint: what each process owns, which is what
Activity Monitor shows. Shared libraries (GTK, mupdf, about 85 MB) are loaded
once either way and are not included.

|                       | 10 zathura windows   | zbuf, one window            |
|-----------------------|----------------------|-----------------------------|
| memory with 10 files  | 332 MB (33 MB each)  | 49 MB, plus 1 MB for D-Bus  |
| opening a file        | ~210 ms (new process)| ~25 ms                      |
| switching files       | instant, all loaded  | ~25 ms, reopened at your page |

zbuf's cost is the 1 MB bus and about 10 to 30 ms per command. Memory stays
flat as you open more files, because only the shown document is kept.

## How it works

- `zbuf` (POSIX sh) runs zathura on a private D-Bus and switches files with
  zathura's `OpenDocument`. While running it keeps `/tmp/zbuf-$UID/`, removed
  when the window closes.
- `zbuf-index.c` draws the `b`/`o` menus and the buffer count in the window.
  zbuf loads it into its own zathura only (`LD_PRELOAD`, or
  `DYLD_INSERT_LIBRARIES` on macOS), where it wraps the PDF plugin to see which
  document is open. zbuf's key maps signal it to open the menus. Zathura's
  plugin folder is never changed.
- `macos/` is the only macOS-specific part. It builds `zbuf.app`, a
  windowless launcher that passes files from Finder to `zbuf`, with a copy of
  zathura inside it, so the window shows as "zathura + zbuf" with zbuf's own
  icon in Cmd-Tab and the Dock. The copy is refreshed by `./install.sh`, so
  rerun it after upgrading zathura.
- `zathura-epub-webkit/` (macOS) is a zathura plugin for EPUBs: `plugin.c`
  pipes pages from `helper.swift`, which lays the book out in WebKit. zbuf adds
  it to its own zathura's plugin path only. See its README.

Upgrading from an earlier zbuf that replaced Homebrew's mupdf plugin: run
`./install.sh` and it puts mupdf back.
