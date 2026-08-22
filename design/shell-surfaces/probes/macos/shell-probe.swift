// macOS shell-surface accessibility probe — the AX counterpart of the Windows
// UIA probe in ../src/main.rs and the Linux AT-SPI probe in ../linux/dump.py.
//
//   swift shell-probe.swift menubar          # frontmost app's AXMenuBar, deep
//   swift shell-probe.swift extras           # AXExtrasMenuBar (status items) for every process
//   swift shell-probe.swift dock             # com.apple.dock
//   swift shell-probe.swift app <bundle-id>  # any app's AX tree (Control Center, Spotlight, ...)
//   swift shell-probe.swift apps             # every running app + which shell attributes it exposes
//   swift shell-probe.swift press <bundle-id> <title>   # AXPress the first element with that title
//
// The host process must be granted Accessibility permission
// (System Settings > Privacy & Security > Accessibility) — for `swift`, that
// means granting the terminal you run it from.

import AppKit
import ApplicationServices
import Foundation

let MAXD = Int(ProcessInfo.processInfo.environment["MAXD"] ?? "8") ?? 8

func copyAttr(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
    return value
}

func attrNames(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(el, &names) == .success else { return [] }
    return (names as? [String]) ?? []
}

func actionNames(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
    return (names as? [String]) ?? []
}

func children(_ el: AXUIElement) -> [AXUIElement] {
    (copyAttr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

func axString(_ el: AXUIElement, _ attr: String) -> String? {
    copyAttr(el, attr) as? String
}

func axPid(_ el: AXUIElement) -> pid_t {
    var pid: pid_t = 0
    AXUIElementGetPid(el, &pid)
    return pid
}

func procName(_ pid: pid_t) -> String {
    NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        ?? NSRunningApplication(processIdentifier: pid)?.localizedName
        ?? "pid:\(pid)"
}

func frameOf(_ el: AXUIElement) -> String {
    var pos = CGPoint.zero
    var size = CGSize.zero
    if let p = copyAttr(el, kAXPositionAttribute as String), CFGetTypeID(p) == AXValueGetTypeID() {
        AXValueGetValue(p as! AXValue, .cgPoint, &pos)
    }
    if let s = copyAttr(el, kAXSizeAttribute as String), CFGetTypeID(s) == AXValueGetTypeID() {
        AXValueGetValue(s as! AXValue, .cgSize, &size)
    }
    return "[\(Int(pos.x)),\(Int(pos.y)) \(Int(size.width))x\(Int(size.height))]"
}

func describeValue(_ v: CFTypeRef?) -> String {
    guard let v = v else { return "-" }
    if let s = v as? String { return "\"\(s)\"" }
    if let n = v as? NSNumber { return n.stringValue }
    return "<\(CFCopyTypeIDDescription(CFGetTypeID(v)) as String? ?? "?")>"
}

func line(_ el: AXUIElement, _ depth: Int) -> String {
    let pad = String(repeating: "  ", count: depth)
    let role = axString(el, kAXRoleAttribute as String) ?? "?"
    let sub = axString(el, kAXSubroleAttribute as String)
    let title = axString(el, kAXTitleAttribute as String) ?? ""
    let desc = axString(el, kAXDescriptionAttribute as String) ?? ""
    let ident = axString(el, kAXIdentifierAttribute as String) ?? ""
    let help = axString(el, kAXHelpAttribute as String) ?? ""
    let pid = axPid(el)
    let acts = actionNames(el)
    let attrs = attrNames(el)
    var extra = ""
    if !desc.isEmpty { extra += " desc=\"\(desc)\"" }
    if !ident.isEmpty { extra += " id=\"\(ident)\"" }
    if !help.isEmpty { extra += " help=\"\(help)\"" }
    if let sub = sub { extra += " subrole=\(sub)" }
    if attrs.contains(kAXValueAttribute as String) {
        extra += " value=\(describeValue(copyAttr(el, kAXValueAttribute as String)))"
    }
    if attrs.contains(kAXEnabledAttribute as String),
       let e = copyAttr(el, kAXEnabledAttribute as String) as? Bool, !e {
        extra += " DISABLED"
    }
    if attrs.contains(kAXSelectedAttribute as String),
       let s = copyAttr(el, kAXSelectedAttribute as String) as? Bool, s {
        extra += " SELECTED"
    }
    return "\(pad)\(role) \"\(title)\" pid=\(pid)(\(procName(pid))) \(frameOf(el))"
        + "\(extra) actions=[\(acts.joined(separator: ","))]"
        + " attrs=[\(attrs.joined(separator: ","))]"
}

func dump(_ el: AXUIElement, _ depth: Int = 0) {
    print(line(el, depth))
    guard depth < MAXD else { return }
    for child in children(el).prefix(200) { dump(child, depth + 1) }
}

func appElement(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }

func runningApps() -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular || $0.activationPolicy == .accessory
    }
}

func find(_ root: AXUIElement, title: String, depth: Int = 0) -> AXUIElement? {
    if axString(root, kAXTitleAttribute as String) == title { return root }
    if axString(root, kAXDescriptionAttribute as String) == title { return root }
    guard depth < 12 else { return nil }
    for c in children(root) {
        if let hit = find(c, title: title, depth: depth + 1) { return hit }
    }
    return nil
}

// ── main ────────────────────────────────────────────────────────────────
let trusted = AXIsProcessTrustedWithOptions(
    [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary)
print("AXIsProcessTrusted = \(trusted)")
if !trusted {
    print("!! Not trusted. Grant Accessibility to the terminal running this script and re-run.")
}

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "help"

switch cmd {
case "apps":
    print("\n=== every running app: which shell attributes does it expose? ===")
    for app in runningApps() {
        let el = appElement(app.processIdentifier)
        let names = attrNames(el)
        let interesting = names.filter {
            $0.contains("MenuBar") || $0.contains("Extras") || $0 == "AXFocusedWindow"
        }
        let hasMenuBar = copyAttr(el, kAXMenuBarAttribute as String) != nil
        let hasExtras = copyAttr(el, "AXExtrasMenuBar") != nil
        print("pid=\(app.processIdentifier) policy=\(app.activationPolicy.rawValue) "
            + "\(app.bundleIdentifier ?? app.localizedName ?? "?") "
            + "AXMenuBar=\(hasMenuBar) AXExtrasMenuBar=\(hasExtras) attrs=\(interesting)")
    }

case "menubar":
    guard let front = NSWorkspace.shared.frontmostApplication else {
        print("no frontmost application"); exit(1)
    }
    print("\n=== frontmost app: \(front.bundleIdentifier ?? "?") pid=\(front.processIdentifier) ===")
    let el = appElement(front.processIdentifier)
    print("app attrs = \(attrNames(el))")
    if let mb = copyAttr(el, kAXMenuBarAttribute as String) {
        print("--- AXMenuBar ---")
        dump(mb as! AXUIElement)
    } else {
        print("no AXMenuBar attribute")
    }

case "extras":
    print("\n=== AXExtrasMenuBar (status items) across all processes ===")
    for app in runningApps() {
        let el = appElement(app.processIdentifier)
        guard let extras = copyAttr(el, "AXExtrasMenuBar") else { continue }
        print("\n--- \(app.bundleIdentifier ?? app.localizedName ?? "?") "
            + "pid=\(app.processIdentifier) policy=\(app.activationPolicy.rawValue) ---")
        dump(extras as! AXUIElement)
    }

case "dock":
    guard let dock = runningApps().first(where: { $0.bundleIdentifier == "com.apple.dock" }) else {
        print("Dock not found"); exit(1)
    }
    print("\n=== com.apple.dock pid=\(dock.processIdentifier) ===")
    dump(appElement(dock.processIdentifier))

case "app":
    guard let bid = args.dropFirst().first else { print("usage: app <bundle-id>"); exit(1) }
    guard let a = runningApps().first(where: { $0.bundleIdentifier == bid }) else {
        print("\(bid) not running"); exit(1)
    }
    print("\n=== \(bid) pid=\(a.processIdentifier) ===")
    let el = appElement(a.processIdentifier)
    print("app attrs = \(attrNames(el))")
    dump(el)

case "press":
    guard args.count >= 3 else { print("usage: press <bundle-id> <title>"); exit(1) }
    let bid = args[1], title = args[2]
    guard let a = runningApps().first(where: { $0.bundleIdentifier == bid }) else {
        print("\(bid) not running"); exit(1)
    }
    var roots = [appElement(a.processIdentifier)]
    if let extras = copyAttr(appElement(a.processIdentifier), "AXExtrasMenuBar") {
        roots.append(extras as! AXUIElement)
    }
    var target: AXUIElement?
    for r in roots where target == nil { target = find(r, title: title) }
    guard let t = target else { print("no element titled \"\(title)\""); exit(1) }
    print("target: " + line(t, 0))
    for action in actionNames(t) {
        print("  available action: \(action)")
    }
    let err = AXUIElementPerformAction(t, kAXPressAction as CFString)
    print("AXPress -> \(err.rawValue) (\(err == .success ? "success" : "FAILED"))")
    Thread.sleep(forTimeInterval: 1.5)
    print("--- subtree after AXPress ---")
    dump(t)

default:
    print("""
    usage: swift shell-probe.swift <command>
      apps                    which processes expose AXMenuBar / AXExtrasMenuBar
      menubar                 frontmost app's AXMenuBar, deep
      extras                  every process's AXExtrasMenuBar (status items)
      dock                    com.apple.dock tree
      app <bundle-id>         any app's tree (com.apple.controlcenter, com.apple.systemuiserver,
                              com.apple.notificationcenterui, com.apple.Spotlight, com.apple.finder)
      press <bundle-id> <title>   AXPress an element and re-dump it
    env MAXD=<n> controls depth (default 8)
    """)
}
