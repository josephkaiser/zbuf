# zathura-epub-webkit

A zathura plugin that opens EPUBs through WebKit (macOS), so MathML equations,
SVG and modern CSS render the way they do in Apple Books or on a Kindle. MuPDF,
zathura's usual EPUB backend, prints MathML as a flat line of symbols.

```
zathura ── plugin.c ──pipe── epub-webkit-helper (helper.swift)
                               └ hidden WKWebView lays each chapter out in
                                 CSS columns, one column per page, and
                                 snapshots the page zathura asks for
```

- `./build.sh` builds `plugin/libepub-webkit.dylib` and `plugin/epub-webkit-helper`.
  The dotfiles `install.sh` runs it.
- zbuf picks it up on its own (see the README one folder up): it adds `plugin/` to
  zathura's plugin path, and its preloaded zbuf-index takes EPUB away from MuPDF,
  whose plugin folder zathura reads first.
- The helper reads a book's files straight out of the .epub; nothing is unpacked.
  Only its measured layout is cached, one small file per book in
  `~/Library/Caches/zathura-epub-webkit/`, redone when the book or epub.css changes;
  `./build.sh clean` removes the build and the cache.

Each chapter is laid out as one long column, 620 wide with 48 margins at 16px text
(about 72 characters a line), and cut into 860-high strips. zbuf shows an EPUB
with no gap between pages, so the strips read as one scroll and text never jumps
to a new page; only chapters start fresh. `--epub-layout: pages` in epub.css
gives separate pages instead (zbuf keeps the gap for those).

Before laying a chapter out, the helper fixes two things books often get wrong:
brackets wrapped alone in an `<mrow>` (so they couldn't stretch around a matrix),
and display equations wider than their column (scaled to fit).

Books that leave the body font to the reader (the generic `serif`, which WebKit
fills with Times) get reading defaults instead: Charter, 1.45 line spacing,
justified paragraphs and hyphenation. Change them, or add any CSS of your own,
in `~/.config/zathura/epub.css`; books are laid out again when it changes:

```css
:root { --epub-serif: "Iowan Old Style"; --epub-line-height: 1.5; --epub-align: left; }
/* width (line length), strip or page height, and margins in CSS px */
:root { --epub-page-width: 700; --epub-page-height: 900; --epub-margin: 56; }
/* separate pages instead of one scroll */
:root { --epub-layout: pages; }
```

Books that mark the printed edition's pages (`epub:type="pagebreak"` or
`role="doc-pagebreak"`, about a third of EPUBs) get those numbers as page labels:
the statusbar shows `[130–131 (149/1011)]`, the print pages on screen and the
position in the scroll, and the contents (Tab) list print pages too.

Not done yet: search, text selection and links inside the book. The contents
(Tab) work.

## Testing the helper by hand

```
printf 'toc\nrender 80 1120 1600\n' | plugin/epub-webkit-helper book.epub
printf 'eval 80 return document.title\n' | plugin/epub-webkit-helper book.epub
```

`eval PAGE JS` runs JavaScript in the chapter holding that page and prints the
result, which is handy for checking how WebKit laid something out.
