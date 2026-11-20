// epub-webkit-helper: lays an EPUB out into fixed-size pages with WebKit (the
// engine Safari and Apple Books use, so MathML, SVG and modern CSS all work)
// and renders those pages as bitmaps for the zathura plugin in plugin.c.
//
//   epub-webkit-helper BOOK.epub     then commands on stdin, one per line:
//
//   (on start)            -> "ok PAGES WIDTH HEIGHT MODE\n" (MODE: scroll or pages)
//                            or "err MESSAGE\n"
//   toc                   -> "toc N\n" + N lines "LEVEL PAGE TITLE" (pages from 0)
//   render PAGE PW PH     -> "img PW PH\n" + PW*PH*4 bytes, premultiplied BGRA
//                            (cairo's ARGB32 on little-endian), top row first
//   labels                -> "labels N\n" + N lines, one per page: the printed edition's
//                            page(s) it shows, as the book marks them ("41", "41–42"),
//                            or an empty line (no print pages marked there, or at all)
//   eval PAGE JS          -> "ok RESULT\n": runs JS in that page's chapter (debugging)
//
// The book's files are read straight out of the .epub. Its page layout (page counts,
// contents, print pages) is cached in ~/Library/Caches/zathura-epub-webkit/<key>.json,
// a few KB, so a second open doesn't lay it out again.
// It runs as its own process because WebKit has to live on a main thread with
// a Cocoa run loop, and zathura renders pages from its own worker threads.

import AppKit
import Compression
import CryptoKit
import WebKit

// ---- page geometry (CSS px; zathura gets the same numbers as points) ----

// your own CSS on top of every book: ~/.config/zathura/epub.css
let userCSSFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/zathura/epub.css")
let userCSS = (try? String(contentsOf: userCSSFile, encoding: .utf8)) ?? ""

/// A number set in epub.css as `--epub-page-width: 800;`, if it's there
func userNumber(_ name: String) -> CGFloat? {
    guard let r = userCSS.range(of: "--\(name)\\s*:\\s*([0-9.]+)", options: .regularExpression) else { return nil }
    return Double(userCSS[r].split(separator: ":")[1].trimmingCharacters(in: .whitespaces)).map { CGFloat($0) }
}

// Between an e-reader page and a printed tech book page, at 16px text: about 70-75
// characters a line, the comfortable range for reading. Smaller pages suit e-readers,
// but on a computer zathura fits the page to the window and the text comes out huge.
// Set --epub-page-width, --epub-page-height and --epub-margin (CSS px) in epub.css.
let pageW: CGFloat = min(max(userNumber("epub-page-width") ?? 620, 300), 3000)
let pageH: CGFloat = min(max(userNumber("epub-page-height") ?? 860, 300), 4000)
let margin: CGFloat = min(max(userNumber("epub-margin") ?? 48, 0), pageW / 4)
// Scrolling (the default): each chapter is one long column cut into page-high strips,
// which zbuf shows with no gap between pages, so text runs on without page breaks.
// `--epub-layout: pages` in epub.css lays it out in separate pages instead.
let paged = userCSS.range(of: "--epub-layout\\s*:\\s*pages", options: .regularExpression) != nil
// bump when the layout CSS changes, so cached layouts are redone
let layoutVersion = 14

// pages: columns one page apart: the html box has the margin as padding, and each
// column is a page minus both margins, so scrolling by pageW moves one page.
// scrolling: one column; a page height of room after it, so the last strip can be
// scrolled to the top of the view like the others
let layoutCSS = paged ? """
html {
  height: \(Int(pageH))px !important; margin: 0 !important;
  padding: \(Int(margin))px !important; box-sizing: border-box !important;
  column-width: \(Int(pageW - 2 * margin))px !important; column-gap: \(Int(2 * margin))px !important;
  column-fill: auto !important; overflow: hidden !important;
  background: white !important;
}
""" : """
html {
  margin: 0 !important; box-sizing: border-box !important;
  padding: \(Int(margin))px \(Int(margin))px \(Int(margin + pageH))px !important;
  overflow: hidden !important; background: white !important;
}
"""
let pageCSS = layoutCSS + """
body { margin: 0 !important; padding: 0 !important; }
img, svg, video { max-width: 100% !important; max-height: \(Int(pageH - 2 * margin))px !important;
  object-fit: contain; break-inside: avoid; }
img { height: auto; }
pre { white-space: pre-wrap !important; overflow-wrap: anywhere !important; }
table { max-width: 100% !important; }
/* keep headings and captions with what follows, and equations and figures whole */
h1, h2, h3, h4, h5, h6, caption, figcaption { break-after: avoid !important; }
[data-type="equation"], figure, .equation, math[display="block"] { break-inside: avoid !important; }
/* STIX Two Math (part of macOS) has the data WebKit needs to stretch brackets
   and roots; books often size math by the window, which is wrong in a page */
math { font-family: "STIX Two Math", math !important; font-size: 1em !important; }
math[display="block"] { max-width: 100%; font-size: 1.05em !important; }
/* reading defaults, used where the book leaves the font to the reader (the
   generic serif, which is Times) or sets tight, ragged text; redefine these
   in ~/.config/zathura/epub.css */
:root { --epub-serif: Charter, "Iowan Old Style", Georgia, serif; --epub-line-height: 1.45; --epub-align: justify; }
p, li, dd, blockquote { -webkit-hyphens: auto !important; hyphens: auto !important; }
"""


// Run on every chapter before it is measured: swap Times for the reading font,
// and loosen and justify paragraphs. Reads every style first, then writes, so
// the page is restyled once rather than per element.
let readingFixes = """
const xhtml = 'http://www.w3.org/1999/xhtml';
const blocks = new Set(['p', 'li', 'dd', 'dt', 'blockquote', 'figcaption']);
const plan = [...document.body.querySelectorAll('*')].filter(e => e.namespaceURI === xhtml).map(e => {
  const c = getComputedStyle(e);
  const first = c.fontFamily.split(',')[0].trim().replace(/["']/g, '').toLowerCase();
  return {e, serif: first === 'serif' || first.startsWith('times'),
          block: blocks.has(e.localName) && !e.closest('pre, table'), align: c.textAlign};
});
for (const {e, serif, block, align} of plan) {
  if (serif) e.style.setProperty('font-family', 'var(--epub-serif)', 'important');
  if (block) e.style.setProperty('line-height', 'var(--epub-line-height)', 'important');
  // (not in list items: their narrow, indented lines justify into wide gaps)
  if (block && e.localName === 'p' && !e.closest('li') && (align === 'left' || align === 'start'))
    e.style.setProperty('text-align', 'var(--epub-align)', 'important');
}
// hyphenation needs to know the language
const root = document.documentElement;
if (!root.lang && !root.getAttributeNS('http://www.w3.org/XML/1998/namespace', 'lang')) root.lang = 'en';
await document.fonts.ready;
"""

// Run on every chapter before it is measured:
// - a bracket alone in its own <mrow> (common in converted books) only stretches
//   to that empty row, so lift it out next to the matrix or fraction it encloses
// - a display equation wider than its column is scaled down to fit
let mathFixes = """
for (const r of [...document.getElementsByTagNameNS('http://www.w3.org/1998/Math/MathML', 'mrow')]) {
  if (r.childElementCount === 1 && r.firstElementChild.localName === 'mo' && r.attributes.length === 0 &&
      r.textContent.trim() === r.firstElementChild.textContent.trim()) r.replaceWith(r.firstElementChild);
}
for (const m of document.querySelectorAll('math[display="block"]')) {
  // (bounding rects span every column a box runs through, so use box widths)
  const p = m.parentElement, cs = getComputedStyle(p);
  const avail = p.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
  const need = m.scrollWidth;
  if (avail > 0 && need > avail) m.style.zoom = (avail / need).toFixed(3);
}
"""

// ---- output ----

let out = FileHandle.standardOutput
func reply(_ s: String) { out.write(s.data(using: .utf8)!) }
func fail(_ s: String) -> Never {
    reply("err \(s.replacingOccurrences(of: "\n", with: " "))\n")
    exit(1)
}

// ---- the package: chapters and contents ----

struct Chapter: Codable {
    var path: String       // inside the book
    var mediaType: String
    var pages = 0
    var first = 0          // index of the chapter's first page in the book
    var anchors: [String: Int] = [:]  // element id -> page within the chapter
    var marks: [Mark] = []            // print page starts, in order
}
/// A printed page starts here: on `page` of the chapter, `at` of the way down it
struct Mark: Codable { var page: Int; var at: Double; var label: String }
struct TocEntry: Codable { var title: String; var href: String; var level: Int }
/// `stamp` is what the layout was measured for (see below); a layout for anything else is redone
struct Layout: Codable { var chapters: [Chapter]; var toc: [TocEntry]; var stamp: String? }

guard CommandLine.arguments.count == 2 else { fail("usage: epub-webkit-helper BOOK.epub") }
let book = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
guard let attrs = try? FileManager.default.attributesOfItem(atPath: book.path) else { fail("cannot read \(book.path)") }

// ---- reading files straight out of the EPUB (a zip) ----

/// The book's files, read from the .epub as they're asked for: it's mapped, not read
/// into memory, and nothing is unpacked to disk. Handles what EPUBs use: files stored
/// as they are or deflated, in a zip under 4 GB.
final class Zip: @unchecked Sendable {
    struct Entry { var method: UInt16; var size: Int; var packed: Int; var header: Int }
    let data: Data
    var entries: [String: Entry] = [:]

    init?(_ url: URL) {
        guard let d = try? Data(contentsOf: url, options: .alwaysMapped), d.count >= 22 else { return nil }
        data = d
        // the end-of-directory record sits at the end, after an optional comment of up to 64 KB
        var end = d.count - 22
        while end >= max(0, d.count - 22 - 65535), u32(end) != 0x0605_4b50 { end -= 1 }
        guard end >= 0, u32(end) == 0x0605_4b50 else { return nil }
        var at = Int(u32(end + 16))
        for _ in 0..<Int(u16(end + 10)) {
            guard at + 46 <= d.count, u32(at) == 0x0201_4b50 else { return nil }
            let nameLen = Int(u16(at + 28)), extraLen = Int(u16(at + 30)), commentLen = Int(u16(at + 32))
            guard at + 46 + nameLen <= d.count else { return nil }
            let name = String(decoding: d[(d.startIndex + at + 46)..<(d.startIndex + at + 46 + nameLen)], as: UTF8.self)
            entries[name] = Entry(method: u16(at + 10), size: Int(u32(at + 24)), packed: Int(u32(at + 20)),
                                  header: Int(u32(at + 42)))
            at += 46 + nameLen + extraLen + commentLen
        }
    }

    func u16(_ i: Int) -> UInt16 { UInt16(data[data.startIndex + i]) | UInt16(data[data.startIndex + i + 1]) << 8 }
    func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }

    /// The file at `name` (a path inside the book), or nil
    func read(_ name: String) -> Data? {
        guard let e = entries[name], e.header + 30 <= data.count, u32(e.header) == 0x0403_4b50 else { return nil }
        let start = e.header + 30 + Int(u16(e.header + 26)) + Int(u16(e.header + 28))
        guard start + e.packed <= data.count else { return nil }
        let packed = data[(data.startIndex + start)..<(data.startIndex + start + e.packed)]
        switch e.method {
        case 0:
            return Data(packed)
        case 8:
            if e.size == 0 { return Data() }
            var out = Data(count: e.size)
            let n = out.withUnsafeMutableBytes { dst in
                packed.withUnsafeBytes { src in
                    // COMPRESSION_ZLIB is raw deflate, which is what zip stores
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, e.size,
                                              src.bindMemory(to: UInt8.self).baseAddress!, e.packed, nil, COMPRESSION_ZLIB)
                }
            }
            return n == e.size ? out : nil
        default:
            return nil
        }
    }
}

let zip: Zip = {
    if let z = Zip(book) { return z }
    fail("cannot read \(book.lastPathComponent) (not a zip?)")
}()

// The measured layout, one small file per book, redone when the book or any of the
// settings it was measured with change
let stamp = "\((attrs[.size] as? Int) ?? 0)|\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(layoutVersion)|\(pageW)x\(pageH)|\(userCSS)"
let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("zathura-epub-webkit")
let layoutFile = cacheRoot.appendingPathComponent(
    SHA256.hash(data: Data(book.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() + ".json")

@Sendable func xml(_ rel: String) -> XMLDocument? {
    zip.read(rel).flatMap { try? XMLDocument(data: $0, options: [.documentTidyXML]) }
}
@Sendable func attr(_ n: XMLNode, _ name: String) -> String? {
    (n as? XMLElement)?.attributes?.first { $0.localName == name }?.stringValue
}
/// "OEBPS/toc.xhtml" + "ch01.html#x" -> "OEBPS/ch01.html#x"
@Sendable func resolve(_ href: String, from file: String) -> String {
    let base = URL(fileURLWithPath: "/" + file).deletingLastPathComponent()
    let parts = href.split(separator: "#", maxSplits: 1).map(String.init)
    let path = (parts[0].removingPercentEncoding ?? parts[0])
    let abs = path.isEmpty ? URL(fileURLWithPath: "/" + file) : URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
    let rel = String(abs.path.dropFirst())
    return parts.count > 1 ? rel + "#" + parts[1] : rel
}

@Sendable func readPackage() -> Layout {
    guard let container = xml("META-INF/container.xml"),
          let rf = try? container.nodes(forXPath: "//*[local-name()='rootfile']").first,
          let opfPath = attr(rf, "full-path"),
          let opf = xml(opfPath) else { fail("not an EPUB (no package document)") }

    var items: [String: (href: String, type: String, props: String)] = [:]
    for n in (try? opf.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']")) ?? [] {
        guard let id = attr(n, "id"), let href = attr(n, "href") else { continue }
        items[id] = (resolve(href, from: opfPath), attr(n, "media-type") ?? "", attr(n, "properties") ?? "")
    }
    var chapters: [Chapter] = []
    for n in (try? opf.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']")) ?? [] {
        guard let id = attr(n, "idref"), let it = items[id] else { continue }
        chapters.append(Chapter(path: it.href, mediaType: it.type))
    }
    guard !chapters.isEmpty else { fail("the EPUB has no chapters") }

    // table of contents: the EPUB 3 nav document, else the EPUB 2 NCX
    var toc: [TocEntry] = []
    if let nav = items.values.first(where: { $0.props.split(separator: " ").contains("nav") }), let doc = xml(nav.href) {
        let navs = (try? doc.nodes(forXPath: "//*[local-name()='nav']")) ?? []
        let tocNav = navs.first { attr($0, "type") == "toc" } ?? navs.first
        func walk(_ list: XMLNode, _ level: Int) {
            for li in list.children ?? [] where li.localName == "li" {
                let a = li.children?.first { $0.localName == "a" || $0.localName == "span" }
                if let a = a, let href = attr(a, "href") {
                    let title = (a.stringValue ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    toc.append(TocEntry(title: title, href: resolve(href, from: nav.href), level: level))
                }
                for sub in li.children ?? [] where sub.localName == "ol" || sub.localName == "ul" { walk(sub, level + 1) }
            }
        }
        if let ol = tocNav?.children?.first(where: { $0.localName == "ol" || $0.localName == "ul" }) { walk(ol, 0) }
    }
    if toc.isEmpty, let ncx = items.values.first(where: { $0.type == "application/x-dtbncx+xml" }), let doc = xml(ncx.href) {
        func walk(_ parent: XMLNode, _ level: Int) {
            for np in parent.children ?? [] where np.localName == "navPoint" {
                let label = np.children?.first { $0.localName == "navLabel" }?.stringValue ?? ""
                let content = np.children?.first { $0.localName == "content" }
                if let src = content.flatMap({ attr($0, "src") }) {
                    let title = label.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    toc.append(TocEntry(title: title, href: resolve(src, from: ncx.href), level: level))
                }
                walk(np, level + 1)
            }
        }
        if let map = try? doc.nodes(forXPath: "//*[local-name()='navMap']").first { walk(map, 0) }
    }
    return Layout(chapters: chapters, toc: toc, stamp: stamp)
}

// ---- serving the book to WebKit ----

/// Serves the book's files out of the .epub, with the media type the package gives
/// them: chapters are XHTML, and parsed as HTML they'd break on `<a id="x"/>`
final class BookScheme: NSObject, WKURLSchemeHandler {
    var types: [String: String] = [:]
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let rel = String(url.path.dropFirst()).removingPercentEncoding ?? ""
        guard let data = zip.read(rel) else {
            task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
            return
        }
        let type = types[rel] ?? mime(for: (rel as NSString).pathExtension)
        task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
    func mime(for ext: String) -> String {
        switch ext.lowercased() {
        case "xhtml", "html", "htm": return "application/xhtml+xml"
        case "css": return "text/css"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "otf": return "font/otf"
        case "ttf": return "font/ttf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }
}

@MainActor
final class Pager: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let window: NSWindow
    let scheme = BookScheme()
    var layout: Layout
    var loaded = -1                        // chapter index in the web view
    var loading: CheckedContinuation<Void, Error>?

    init(_ layout: Layout) {
        self.layout = layout
        for c in layout.chapters where !c.mediaType.isEmpty { scheme.types[c.path] = c.mediaType }
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(scheme, forURLScheme: "epub")
        config.suppressesIncrementalRendering = true
        let style = WKUserScript(source: """
            (() => { const s = document.createElementNS('http://www.w3.org/1999/xhtml', 'style');
                     s.textContent = \(String(data: try! JSONEncoder().encode(pageCSS + "\n" + userCSS), encoding: .utf8)!);
                     (document.head || document.documentElement).appendChild(s); })();
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(style)
        let frame = NSRect(x: 0, y: 0, width: pageW, height: pageH)
        web = WKWebView(frame: frame, configuration: config)
        // never shown: snapshots need the view in a window, not the window on screen
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        super.init()
        web.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading?.resume(); loading = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading?.resume(throwing: error); loading = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading?.resume(throwing: error); loading = nil
    }

    func load(_ i: Int) async throws {
        if loaded == i { return }
        loaded = -1
        let url = URL(string: "epub://book/" + (layout.chapters[i].path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""))!
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loading = c
            web.load(URLRequest(url: url))
        }
        // fonts and images change the layout, so wait for them before measuring
        _ = try? await web.callAsyncJavaScript("""
            await document.fonts.ready;
            await Promise.all([...document.images].map(i => i.decode().catch(() => {})));
            \(readingFixes)
            \(mathFixes)
            """, contentWorld: .page)
        loaded = i
    }

    /// Page count of every chapter, and the page of each id the contents point at
    func measure() async throws {
        var wanted: [String: [String]] = [:]
        for t in layout.toc {
            let parts = t.href.split(separator: "#", maxSplits: 1).map(String.init)
            if parts.count == 2 { wanted[parts[0], default: []].append(parts[1]) }
        }
        var first = 0
        for i in layout.chapters.indices {
            try await load(i)
            let ids = wanted[layout.chapters[i].path] ?? []
            let r = try await web.callAsyncJavaScript("""
                const el = document.documentElement;
                const pages = paged ? Math.max(1, Math.ceil((el.scrollWidth - margin) / pageW - 0.01))
                                    : Math.max(1, Math.ceil((el.scrollHeight - pageH) / pageH - 0.01));
                const anchors = {};
                for (const id of ids) {
                  const e = document.getElementById(id);
                  if (!e) continue;
                  const r = e.getBoundingClientRect();
                  anchors[id] = Math.max(0, Math.floor(paged ? (r.left + el.scrollLeft) / pageW : (r.top + el.scrollTop) / pageH));
                }
                // print page markers: <span epub:type="pagebreak" title="41"/> and
                // role="doc-pagebreak"; the number is in aria-label or title, else in the id
                const ops = 'http://www.idpf.org/2007/ops', marks = [];
                for (const e of document.body.querySelectorAll('*')) {
                  const t = (e.getAttributeNS(ops, 'type') || e.getAttribute('epub:type') || '').split(/\\s+/);
                  const role = (e.getAttribute('role') || '').split(/\\s+/);
                  if (!t.includes('pagebreak') && !role.includes('doc-pagebreak')) continue;
                  const fromId = (e.id || '').match(/^(?:page|pg|p)[_-]?(.+)$/i);
                  const label = (e.getAttribute('aria-label') || e.getAttribute('title') ||
                                 (fromId && fromId[1]) || e.textContent || '').trim();
                  // page numbers look like "41", "xvii" or "A-3"; skip things like "Cover."
                  if (!/^[\\w-]{1,10}$/.test(label)) continue;
                  // where it sits; an empty or hidden marker has no box, so use the
                  // spot just before it, else its parent
                  let r = e.getClientRects()[0];
                  if (!r) { const g = document.createRange(); g.setStartBefore(e); g.collapse(true); r = g.getClientRects()[0]; }
                  if (!r && e.parentElement) r = e.parentElement.getClientRects()[0];
                  if (!r) continue;
                  const x = r.left + el.scrollLeft, y = r.top + el.scrollTop;
                  const page = Math.max(0, Math.floor(paged ? x / pageW : y / pageH));
                  marks.push({page, at: paged ? y / pageH : y / pageH - page, label});
                }
                return {pages, anchors, marks};
                """, arguments: ["ids": ids, "pageW": Double(pageW), "pageH": Double(pageH), "margin": Double(margin), "paged": paged], contentWorld: .page) as? [String: Any]
            layout.chapters[i].pages = (r?["pages"] as? Int) ?? (r?["pages"] as? Double).map(Int.init) ?? 1
            layout.chapters[i].anchors = ((r?["anchors"] as? [String: Any]) ?? [:]).compactMapValues { ($0 as? Int) ?? ($0 as? Double).map(Int.init) }
            layout.chapters[i].marks = ((r?["marks"] as? [[String: Any]]) ?? []).compactMap { m in
                guard let label = m["label"] as? String,
                      let page = (m["page"] as? Int) ?? (m["page"] as? Double).map(Int.init) else { return nil }
                return Mark(page: page, at: (m["at"] as? Double) ?? Double((m["at"] as? Int) ?? 0), label: label)
            }
            layout.chapters[i].first = first
            first += layout.chapters[i].pages
        }
    }

    var pageCount: Int { layout.chapters.last.map { $0.first + $0.pages } ?? 0 }

    func chapter(of page: Int) -> Int {
        layout.chapters.lastIndex { $0.first <= page } ?? 0
    }

    /// Per page, the print page(s) it shows: the one in effect at its top, through the
    /// last one starting on it ("41–42"). Print pages run on across chapters.
    func pageLabels() -> [String] {
        var labels: [String] = [], current: String? = nil
        for c in layout.chapters {
            for k in 0..<c.pages {
                let here = c.marks.filter { $0.page == k }
                // a print page starting right at the top is this page's first
                let top = here.first.flatMap { $0.at < 0.06 ? $0.label : nil } ?? current
                let last = here.last?.label ?? current
                if let top, let last { labels.append(top == last ? top : "\(top)–\(last)") } else { labels.append(last ?? "") }
                current = last
            }
        }
        return labels
    }

    /// "LEVEL PAGE TITLE" per contents entry, in order
    func tocLines() -> [String] {
        layout.toc.compactMap { t in
            let parts = t.href.split(separator: "#", maxSplits: 1).map(String.init)
            guard let c = layout.chapters.first(where: { $0.path == parts[0] }) else { return nil }
            let within = parts.count == 2 ? (c.anchors[parts[1]] ?? 0) : 0
            let title = t.title.replacingOccurrences(of: "\n", with: " ")
            return "\(t.level) \(c.first + min(within, c.pages - 1)) \(title)"
        }
    }

    /// Page `page` as a pw x ph bitmap
    func render(_ page: Int, _ pw: Int, _ ph: Int) async throws -> Data {
        let ci = chapter(of: page)
        try await load(ci)
        let n = CGFloat(page - layout.chapters[ci].first)
        let scroll = paged ? "scrollLeft = \(n * pageW)" : "scrollTop = \(n * pageH)"
        _ = try await web.evaluateJavaScript("document.documentElement.\(scroll); 0")
        let config = WKSnapshotConfiguration()
        config.rect = NSRect(x: 0, y: 0, width: pageW, height: pageH)
        // snapshotWidth is in points; the image comes back at the window's backing scale
        config.snapshotWidth = NSNumber(value: Double(pw) / Double(window.backingScaleFactor))
        config.afterScreenUpdates = true
        let image = try await web.takeSnapshot(configuration: config)

        var data = Data(count: pw * ph * 4)
        data.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.setFillColor(.white)
            ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
            var rect = CGRect(x: 0, y: 0, width: pw, height: ph)
            if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: pw, height: ph))
            }
        }
        return data
    }
}

// ---- main ----

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

/// Runs `work` on the main actor and waits for it, from the stdin thread
func onMain<T: Sendable>(_ work: @escaping @MainActor () async throws -> T) -> Result<T, Error> {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, Error>!
    DispatchQueue.main.async {
        Task { @MainActor in
            do { result = .success(try await work()) } catch { result = .failure(error) }
            done.signal()
        }
    }
    done.wait()
    return result
}

nonisolated(unsafe) var pager: Pager!

Thread {
    let cached = (try? Data(contentsOf: layoutFile)).flatMap { try? JSONDecoder().decode(Layout.self, from: $0) }
        .flatMap { $0.stamp == stamp ? $0 : nil }
    let opened = onMain { () -> Int in
        pager = Pager(cached ?? readPackage())
        if cached == nil {
            try await pager.measure()
            try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(pager.layout) { try? data.write(to: layoutFile, options: .atomic) }
        }
        return pager.pageCount
    }
    guard case .success(let pages) = opened else { fail("layout failed: \(opened)") }
    reply("ok \(pages) \(Int(pageW)) \(Int(pageH)) \(paged ? "pages" : "scroll")\n")

    while let line = readLine() {
        let f = line.split(separator: " ")
        switch f.first {
        case "toc":
            let lines = (try? onMain { pager.tocLines() }.get()) ?? []
            reply("toc \(lines.count)\n" + lines.map { $0 + "\n" }.joined())
        case "labels":
            let labels = (try? onMain { pager.pageLabels() }.get()) ?? []
            reply("labels \(labels.count)\n" + labels.map { $0.replacingOccurrences(of: "\n", with: " ") + "\n" }.joined())
        case "render" where f.count == 4:
            guard let page = Int(f[1]), let pw = Int(f[2]), let ph = Int(f[3]), pw > 0, ph > 0, pw * ph < 200_000_000 else {
                reply("err bad render request\n"); continue
            }
            let p = min(max(page, 0), max(0, pages - 1))
            switch onMain({ try await pager.render(p, pw, ph) }) {
            case .success(let data):
                reply("img \(pw) \(ph)\n")
                out.write(data)
            case .failure(let e):
                reply("err \(e.localizedDescription.replacingOccurrences(of: "\n", with: " "))\n")
            }
        case "eval" where f.count >= 3:
            // debugging: "eval PAGE JS" runs JS in that page's chapter, replies with one line
            guard let page = Int(f[1]) else { reply("err bad eval\n"); continue }
            let js = f[2...].joined(separator: " ")
            let r = onMain { () -> String in
                try await pager.load(pager.chapter(of: page))
                return "\(try await pager.web.callAsyncJavaScript(js, contentWorld: .page) ?? "nil")"
            }
            switch r {
            case .success(let s): reply("ok \(s.replacingOccurrences(of: "\n", with: " "))\n")
            case .failure(let e): reply("err \(e)\n".replacingOccurrences(of: "\n", with: " ") + "\n")
            }
        default:
            reply("err unknown command\n")
        }
    }
    exit(0)
}.start()

app.run()
