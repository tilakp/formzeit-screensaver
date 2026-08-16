import Cocoa
import ScreenSaver

// Loads the built Formzeit.saver bundle exactly the way the real
// screensaver host would (NSBundle -> principalClass), hosts it in a plain
// window, and takes a screenshot after a short delay so the visual design
// can be reviewed without a full System Settings round-trip.

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: TestHarness <path-to-.saver> <screenshot-out.png> [seconds] [W] [H]\n".data(using: .utf8)!)
    exit(1)
}
let saverPath = args[1]
let outPath = args[2]
let showConfig = args.contains("--config")
let isPreviewMode = args.contains("--preview")
let positional = args.dropFirst(3).filter { $0 != "--config" && $0 != "--preview" }
let delay = positional.count > 0 ? Double(positional[0]) ?? 2.0 : 2.0
let width = positional.count > 1 ? Int(positional[1]) ?? 1200 : 1200
let height = positional.count > 2 ? Int(positional[2]) ?? 800 : 800

guard let bundle = Bundle(path: saverPath) else {
    FileHandle.standardError.write("could not open bundle at \(saverPath)\n".data(using: .utf8)!)
    exit(1)
}
guard bundle.load() else {
    FileHandle.standardError.write("bundle.load() failed\n".data(using: .utf8)!)
    exit(1)
}
guard let principal = bundle.principalClass as? ScreenSaverView.Type else {
    FileHandle.standardError.write("principalClass is not a ScreenSaverView subclass: \(String(describing: bundle.principalClass))\n".data(using: .utf8)!)
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let frame = NSRect(x: 0, y: 0, width: width, height: height)
let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "Formzeit preview"

guard let saverView = principal.init(frame: frame, isPreview: isPreviewMode) else {
    FileHandle.standardError.write("failed to instantiate principal class\n".data(using: .utf8)!)
    exit(1)
}
window.contentView = saverView
window.makeKeyAndOrderFront(nil)
window.center()
app.activate(ignoringOtherApps: true)

func captureAndExit(_ view: NSView, to path: String) {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        FileHandle.standardError.write("could not create bitmap rep\n".data(using: .utf8)!)
        exit(1)
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("could not encode png\n".data(using: .utf8)!)
        exit(1)
    }
    do {
        try data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    } catch {
        FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!)
    }
    exit(0)
}

if showConfig {
    guard let sheet = saverView.configureSheet, let contentView = sheet.contentView else {
        FileHandle.standardError.write("no configure sheet\n".data(using: .utf8)!)
        exit(1)
    }
    sheet.makeKeyAndOrderFront(nil)
    sheet.center()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        captureAndExit(contentView, to: outPath)
    }
} else {
    saverView.startAnimation()
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        captureAndExit(saverView, to: outPath)
    }
}

app.run()
