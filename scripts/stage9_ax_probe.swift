import AppKit
import SwiftUI
import ApplicationServices
let app = NSApplication.shared
app.finishLaunching()
let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 400, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
let host = NSHostingView(rootView: VStack { Text("正在检查…"); Button("保存") {}.accessibilityIdentifier("save") })
window.contentView = host
window.makeKeyAndOrderFront(nil)
host.layoutSubtreeIfNeeded()
DispatchQueue.global().async {
 let remote = AXUIElementCreateApplication(getpid())
 var children: CFTypeRef?
 let result = AXUIElementCopyAttributeValue(remote, kAXChildrenAttribute as CFString, &children)
 print("Self AX client read", result.rawValue)
}
RunLoop.main.run(until: Date().addingTimeInterval(3))
var seen = Set<ObjectIdentifier>()
func walk(_ value: Any, depth: Int) {
 guard depth < 12, let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
 func get(_ name: String) -> Any? {
  let sel = NSSelectorFromString(name)
  return object.responds(to: sel) ? object.perform(sel)?.takeUnretainedValue() : nil
 }
 print(depth, String(describing:type(of:object)), "protocol",object is NSAccessibilityProtocol,
       ["accessibilityRole","accessibilityTitle","accessibilityLabel","accessibilityValue"].map { String(describing:get($0)) })
 for child in get("accessibilityChildren") as? [Any] ?? [] { walk(child, depth: depth+1) }
}
walk(window,depth:0)
window.close()
