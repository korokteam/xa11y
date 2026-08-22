// macOS shell-surface accessibility probe — the AX counterpart of the Windows
// UIA probe in ../src/main.rs and the Linux AT-SPI probe in ../linux/dump.py.
//
//   swift shell-probe.swift menubar          # frontmost app's AXMenuBar, deep
//   swift shell-probe.swift extras           # AXExtrasMenuBar (status items) for every process
//   swift shell-probe.swift dock             # com.apple.dock
//   swift shell-probe.swift app <bundle-id>  # any app's AX tree (Control Center, Spotlight, ...)
//   swift shell-probe.swift apps             # every running app + which shell attributes it exposes
//   swift shell-probe.swift press <bundle-id> <title>      # AXPress the first element with that title
//        <title> matches AXTitle or AXDescription; use "id:<AXIdentifier>" to match by identifier
//   swift shell-probe.swift showmenu <bundle-id> <title>   # AXShowMenu, then dump the menu it produced
//   swift shell-probe.swift hittest <x> <y>                # system-wide hit test at a screen point
//   swift shell-probe.swift dismiss                        # send Escape to close any open shell flyout
//   swift shell-probe.swift cgwindows                      # CGWindowList owners (xa11y's app-discovery basis)
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

// A needle is matched against AXTitle/AXDescription, or against AXIdentifier when
// prefixed with "id:". The AXApplication root is never matched by title — its title is
// the app name, which collides with the shell surfaces we are usually aiming at
// (e.g. "Control Center" is both the process and one of its menu extras).
func matches(_ el: AXUIElement, _ needle: String) -> Bool {
    if needle.hasPrefix("id:") {
        return axString(el, kAXIdentifierAttribute as String) == String(needle.dropFirst(3))
    }
    if axString(el, kAXRoleAttribute as String) == (kAXApplicationRole as String) { return false }
    return axString(el, kAXTitleAttribute as String) == needle
        || axString(el, kAXDescriptionAttribute as String) == needle
}

func find(_ root: AXUIElement, title: String, depth: Int = 0) -> AXUIElement? {
    if matches(root, title) { return root }
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
    print("--- subtree BEFORE AXPress (\(children(t).count) direct children) ---")
    dump(t)
    let err = AXUIElementPerformAction(t, kAXPressAction as CFString)
    print("AXPress -> \(err.rawValue) (\(err == .success ? "success" : "FAILED"))")
    Thread.sleep(forTimeInterval: 1.5)
    print("--- subtree AFTER AXPress (\(children(t).count) direct children) ---")
    dump(t)

case "showmenu":
    guard args.count >= 3 else { print("usage: showmenu <bundle-id> <title>"); exit(1) }
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
    let shownBefore = copyAttr(t, "AXShownMenuUIElement")
    print("AXShownMenuUIElement before = \(shownBefore == nil ? "nil" : "present")")
    let err = AXUIElementPerformAction(t, "AXShowMenu" as CFString)
    print("AXShowMenu -> \(err.rawValue) (\(err == .success ? "success" : "FAILED"))")
    Thread.sleep(forTimeInterval: 1.0)
    if let shown = copyAttr(t, "AXShownMenuUIElement") {
        print("--- AXShownMenuUIElement after ---")
        dump(shown as! AXUIElement)
    } else {
        print("AXShownMenuUIElement after = nil  <-- returned success but produced no menu")
    }
    print("--- target subtree after ---")
    dump(t)

case "hittest":
    guard args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) else {
        print("usage: hittest <x> <y>"); exit(1)
    }
    let sys = AXUIElementCreateSystemWide()
    var hit: AXUIElement?
    let err = AXUIElementCopyElementAtPosition(sys, Float(x), Float(y), &hit)
    print("AXUIElementCopyElementAtPosition(\(Int(x)),\(Int(y))) -> \(err.rawValue)")
    guard let h = hit else { print("no element at that point"); exit(0) }
    print("hit: " + line(h, 0))
    print("--- ancestry ---")
    var cur: AXUIElement? = h
    var depth = 0
    while let c = cur, depth < 12 {
        print(line(c, depth))
        cur = copyAttr(c, kAXParentAttribute as String).map { $0 as! AXUIElement }
        depth += 1
    }

case "dismiss":
    let src = CGEventSource(stateID: .hidSystemState)
    CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
    print("sent Escape")

case "cgwindows":
    // Mirrors xa11y-macos/src/ax.rs list_gui_apps(): CGWindowListCopyWindowInfo(0, 0),
    // dedup by kCGWindowOwnerPID, keep entries with a non-empty kCGWindowOwnerName.
    // This is the basis xa11y uses to decide which apps exist at all, so whether a
    // shell process shows up here decides whether it is nameable by `App::by_name`.
    guard let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)
        as? [[String: Any]] else {
        print("CGWindowListCopyWindowInfo returned nil (Screen Recording denied?)"); exit(1)
    }
    print("\n=== CGWindowListCopyWindowInfo(.optionAll): \(info.count) window entries ===")
    var seen = Set<pid_t>()
    var rows: [(pid_t, String, Int, Int)] = []   // pid, name, minLayer, windowCount
    for w in info {
        guard let pid = w["kCGWindowOwnerPID"] as? pid_t else { continue }
        let name = (w["kCGWindowOwnerName"] as? String) ?? ""
        let layer = (w["kCGWindowLayer"] as? Int) ?? 0
        if let idx = rows.firstIndex(where: { $0.0 == pid }) {
            rows[idx].2 = min(rows[idx].2, layer)
            rows[idx].3 += 1
        } else {
            rows.append((pid, name, layer, 1))
            seen.insert(pid)
        }
    }
    let named = rows.filter { !$0.1.isEmpty }
    print("distinct owner pids = \(rows.count); with a non-empty owner name = \(named.count)")
    print("(list_gui_apps() keeps exactly the named ones)\n")
    for r in named.sorted(by: { $0.0 < $1.0 }) {
        let bid = NSRunningApplication(processIdentifier: r.0)?.bundleIdentifier ?? "-"
        print("pid=\(r.0) windows=\(r.3) minLayer=\(r.2) name=\"\(r.1)\" bundle=\(bid)")
    }
    let anonymous = rows.filter { $0.1.isEmpty }
    if !anonymous.isEmpty {
        print("\ndropped by the non-empty-name rule:")
        for r in anonymous.sorted(by: { $0.0 < $1.0 }) {
            let bid = NSRunningApplication(processIdentifier: r.0)?.bundleIdentifier ?? "-"
            print("pid=\(r.0) windows=\(r.3) minLayer=\(r.2) bundle=\(bid)")
        }
    }

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
      showmenu <bundle-id> <title>   AXShowMenu and dump AXShownMenuUIElement
      hittest <x> <y>         system-wide hit test at a screen point
      dismiss                 send Escape to close an open shell flyout
      cgwindows               CGWindowList owners — the basis of xa11y's list_gui_apps()
    env MAXD=<n> controls depth (default 8)
    """)
}
