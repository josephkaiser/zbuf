# zbuf

One zathura window, many documents. zbuf keeps a single zathura open and swaps
the file it shows, like buffers in vim, with oil-style menus drawn inside the
window. It works with the zathura you already have: nothing is patched, and
zathura started any other way behaves exactly as before.

Runs on Linux and macOS.

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

zbuf does not become your default PDF and EPUB viewer unless you say so. The
installer asks (in a terminal only; `ZBUF_DEFAULT=yes` or `no` answers ahead of
time), `./install.sh default` asks again later, and uninstalling puts back the
viewer you had before.

On Homebrew, zathura-pdf-mupdf has to be linked into zathura's plugin folder
for zathura to see it (`brew info zathura-pdf-mupdf` shows how); the installer
tells you if no PDF plugin is found.

## Use

```sh
zbuf paper.pdf book.epub   # start, or add files to the running window
zbuf                       # reopen the last document you read
```

In the window:

| key        | does                                   |
|------------|----------------------------------------|
| `o`        | files in the current folder            |
| `b`        | open buffers                           |
| `gt` / `gT`| next / previous buffer                 |
| `gd`       | close the buffer                       |
| `Tab`      | the document's own contents (zathura)  |

In the `o` and `b` menus: `j`/`k` move, `Enter` or `l` opens, `-` or `h` goes up
a folder, `~` goes home, `b`/`o` swap menus, `q` or `Esc` closes.

From a shell: `zbuf next`, `zbuf prev`, `zbuf close`, `zbuf list`, `zbuf quit`.

Pages are remembered per file by zathura's own history, as usual.

## Cost

Measured on an M4 with 10 PDFs (88 KB to 2 MB), `page-cache-size 100`, and 20
pages read in each. Memory is footprint: what each process owns, which is what
Activity Monitor shows. Shared libraries (GTK, mupdf, about 85 MB) are loaded
once either way and are not included.

|                       | 10 zathura windows   | zbuf, one window            |
|-----------------------|----------------------|-----------------------------|
| memory with 10 files  | 332 MB (33 MB each)  | 49 MB, plus 1 MB for D-Bus  |
| opening a file        | ~210 ms (new process)| ~25 ms                      |
| switching files       | instant, all loaded  | ~25 ms, reopened at your page |

zbuf's own cost is the 1 MB bus and about 10 to 30 ms per command. Memory stays
flat as you open more files, because only the shown document is kept; the
trade-off is that a document you switch back to is drawn again.

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

Upgrading from an earlier zbuf that replaced Homebrew's mupdf plugin: run
`./install.sh` and it puts mupdf back.
