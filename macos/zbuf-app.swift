// zbuf.app: lets Finder (and `open`) hand documents to zbuf. It has no window
// or Dock icon of its own; it passes the files on to zbuf, brings the zathura
// window forward and quits.
//
//   zbuf.app/Contents/MacOS/zbuf-app --get-default type
//     print the bundle id of the app that opens type (a UTI), if any
//   zbuf.app/Contents/MacOS/zbuf-app --set-default type bundle-id
//     make bundle-id the app that opens type
//
// install.sh uses these to make zbuf the PDF/EPUB viewer when asked, and to
// put the previous viewer back on uninstall.

import AppKit
import CoreServices

let args = CommandLine.arguments

if args.count == 3, args[1] == "--get-default" {
    if let id = LSCopyDefaultRoleHandlerForContentType(args[2] as CFString, .all)?.takeRetainedValue() {
        print(id as String)
    }
    exit(0)
}

if args.count == 4, args[1] == "--set-default" {
    let status = LSSetDefaultRoleHandlerForContentType(args[2] as CFString, .all, args[3] as CFString)
    if status != noErr {
        FileHandle.standardError.write("zbuf-app: could not set \(args[3]) for \(args[2]): \(status)\n".data(using: .utf8)!)
        exit(1)
    }
    exit(0)
}

final class Launcher: NSObject, NSApplicationDelegate {
    var opened = false

    func run(_ args: [String]) {
        let zbuf = Process()
        zbuf.executableURL = Bundle.main.url(forResource: "zbuf", withExtension: nil)
        zbuf.arguments = args
        // apps started from Finder get a bare PATH; zbuf needs dbus from Homebrew
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        zbuf.environment = env
        try? zbuf.run()
        zbuf.waitUntilExit()
        raiseZathura()
    }

    // zbuf records zathura's pid in its session dir
    func raiseZathura() {
        let state = "/tmp/zbuf-\(getuid())/state"
        guard let text = try? String(contentsOfFile: state, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("ZPID=") }),
              let pid = pid_t(line.dropFirst(5)),
              let zathura = NSRunningApplication(processIdentifier: pid)
        else { return }
        zathura.activate()
    }

    func application(_ app: NSApplication, open urls: [URL]) {
        opened = true
        run(urls.map(\.path))
    }

    // documents arrive before this when Finder launched us with some
    func applicationDidFinishLaunching(_ note: Notification) {
        if !opened {
            run([])
        }
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let launcher = Launcher()
app.delegate = launcher
app.run()
