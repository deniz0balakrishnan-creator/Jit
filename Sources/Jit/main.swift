import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate  // LSUIElement in Info.plist keeps Jit out of the Dock
app.run()
