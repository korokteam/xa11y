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
// Added for §4.8 (the AXMenuBar child-filter question):
//   swift shell-probe.swift census [<bundle-id>]           # menu-bar vs rest-of-tree node counts, depth, wall clock
//   swift shell-probe.swift collide [<bundle-id>]          # name-set intersection, menu bar vs window content
//   swift shell-probe.swift lazy <bundle-id> <menu-title>  # cold menu-bar counts, AXPress a menu, re-count, diff
//   swift shell-probe.swift applist                        # current vs proposed app list, symmetric difference
//   swift shell-probe.swift lockcheck                      # screen-lock state; locked screens corrupt window subtrees
//   swift shell-probe.swift extrascost [<timeout-secs>]    # AXExtrasMenuBar fan-out cost over every process
// env NODECAP / DEPTHCAP bound the walks; env REPEAT sets the repeat count (default 3).
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

// ── measurement helpers (added for §4.8: menu-bar size / ratio / collision) ──
//
// These exist to answer one question: if the AXMenuBar child filter in
// xa11y-macos/src/ax.rs:1759 is lifted, how much bigger does a tree get and
// what starts colliding with in-window names? Everything here counts and
// times; nothing here mutates, except `lazy`, which says so.

let NODECAP = Int(ProcessInfo.processInfo.environment["NODECAP"] ?? "400000") ?? 400000
let DEPTHCAP = Int(ProcessInfo.processInfo.environment["DEPTHCAP"] ?? "80") ?? 80
let REPEAT = Int(ProcessInfo.processInfo.environment["REPEAT"] ?? "3") ?? 3

struct Stats {
    var nodes = 0
    var maxDepth = 0
    var hitNodeCap = false
    var hitDepthCap = false
    var cycles = 0
    var caps: String {
        var f: [String] = []
        if hitNodeCap { f.append("NODECAP") }
        if hitDepthCap { f.append("DEPTHCAP") }
        if cycles > 0 { f.append("CYCLES=\(cycles)") }
        return f.isEmpty ? "-" : f.joined(separator: "+")
    }
}

/// Depth-first node count. Counts `el` itself, so a leaf is 1 node.
/// `depth` is relative to the walk root (root = 0), so maxDepth is edges, not nodes.
///
/// `ancestors` exists because AXChildren is not always a tree. With the screen
/// locked, several apps return the AXApplication element itself as its own
/// child (see the `lockcheck` command), which makes an unguarded walk run to
/// whatever depth cap it is given. Cutting at a repeated ancestor keeps the
/// count finite and reports how many times it happened.
func countWalk(_ el: AXUIElement, _ depth: Int, _ s: inout Stats,
               _ ancestors: inout [AXUIElement]) {
    s.nodes += 1
    if depth > s.maxDepth { s.maxDepth = depth }
    if s.nodes >= NODECAP { s.hitNodeCap = true; return }
    if depth >= DEPTHCAP { s.hitDepthCap = true; return }
    ancestors.append(el)
    defer { ancestors.removeLast() }
    for c in children(el) {
        if s.hitNodeCap { return }
        if ancestors.contains(where: { CFEqual($0, c) }) {
            s.cycles += 1
            s.nodes += 1          // count the repeat once, then stop descending
            continue
        }
        countWalk(c, depth + 1, &s, &ancestors)
    }
}

/// Convenience wrapper for the common "fresh walk" case.
func countWalk(_ el: AXUIElement, _ depth: Int, _ s: inout Stats) {
    var anc: [AXUIElement] = []
    countWalk(el, depth, &s, &anc)
}

func timed<T>(_ body: () -> T) -> (T, Double) {
    let t0 = ProcessInfo.processInfo.systemUptime
    let r = body()
    return (r, ProcessInfo.processInfo.systemUptime - t0)
}

func msStr(_ t: Double) -> String { String(format: "%.1f", t * 1000) }
func pctStr(_ x: Double) -> String { String(format: "%.1f", x) }

/// xa11y's own name rule, transcribed from xa11y-macos/src/ax.rs:1543-1550:
///   name = AXTitle, else (AXValue-as-string if role is AXStaticText), else AXDescription.
/// Empty strings are NOT filtered there, so they are not filtered here either —
/// they are reported separately instead.
func xa11yName(_ el: AXUIElement, _ roleStr: String) -> String? {
    if let t = axString(el, kAXTitleAttribute as String) { return t }
    if roleStr == "AXStaticText" {
        if let v = copyAttr(el, kAXValueAttribute as String) as? String { return v }
    }
    return axString(el, kAXDescriptionAttribute as String)
}

/// AX roles that xa11y maps to Role::MenuItem (ax.rs:1024). Selectors are
/// role-scoped, so `menu_item[name=...]` can only ever match these.
let MENU_ITEM_ROLES: Set<String> = ["AXMenuItem", "AXMenuBarItem"]

/// Collect (name, axRole) for every node in a subtree.
func collectNames(_ el: AXUIElement, _ depth: Int, _ out: inout [(String, String)],
                  _ s: inout Stats, _ ancestors: inout [AXUIElement]) {
    s.nodes += 1
    if depth > s.maxDepth { s.maxDepth = depth }
    let role = axString(el, kAXRoleAttribute as String) ?? "?"
    if let n = xa11yName(el, role) { out.append((n, role)) }
    if s.nodes >= NODECAP { s.hitNodeCap = true; return }
    if depth >= DEPTHCAP { s.hitDepthCap = true; return }
    ancestors.append(el)
    defer { ancestors.removeLast() }
    for c in children(el) {
        if s.hitNodeCap { return }
        if ancestors.contains(where: { CFEqual($0, c) }) { s.cycles += 1; continue }
        collectNames(c, depth + 1, &out, &s, &ancestors)
    }
}

func collectNames(_ el: AXUIElement, _ depth: Int, _ out: inout [(String, String)], _ s: inout Stats) {
    var anc: [AXUIElement] = []
    collectNames(el, depth, &out, &s, &anc)
}

func regularApps() -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
}

func bundleOf(_ a: NSRunningApplication) -> String {
    a.bundleIdentifier ?? a.localizedName ?? "pid:\(a.processIdentifier)"
}

/// The AXMenuBar *attribute* value, and whether that same element is also
/// returned in the app element's AXChildren. CFEqual is the identity test —
/// AXUIElementRef implements it.
func menuBarInfo(_ appEl: AXUIElement) -> (mb: AXUIElement?, inChildren: Bool, childIndex: Int, kids: [AXUIElement]) {
    let kids = children(appEl)
    guard let raw = copyAttr(appEl, kAXMenuBarAttribute as String) else {
        return (nil, false, -1, kids)
    }
    let mb = raw as! AXUIElement
    for (i, k) in kids.enumerated() where CFEqual(k, mb) {
        return (mb, true, i, kids)
    }
    return (mb, false, -1, kids)
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

case "census":
    // Q1 (menu-bar size), Q2 (ratio), Q5 (is AXMenuBar even a child?).
    // One row per activationPolicy == .regular app. Optional arg limits to one bundle id.
    let onlyBundle = args.dropFirst().first
    print("\n=== menu-bar vs rest-of-tree census — activationPolicy == .regular ===")
    print("NODECAP=\(NODECAP) DEPTHCAP=\(DEPTHCAP) REPEAT=\(REPEAT)")
    print("node counts include the walk root; maxDepth is edges below the walk root.")
    print("'rest' = the app element's AXChildren MINUS the AXMenuBar element, each recursed.")
    print("total  = 1 (the AXApplication element) + menubar + rest.\n")
    for app in regularApps() {
        let bid = bundleOf(app)
        if let ob = onlyBundle, bid != ob { continue }
        let pid = app.processIdentifier
        let appEl = appElement(pid)
        print("--- \(bid) pid=\(pid) ---")
        let attrs = attrNames(appEl)
        if attrs.isEmpty {
            print("  app element attrs=[] — no AX connection; skipping walks")
            print("  AXChildren = \(children(appEl).count)")
            print("")
            continue
        }
        let info = menuBarInfo(appEl)
        print("  AXChildren = \(info.kids.count) roles=[\(info.kids.map { axString($0, kAXRoleAttribute as String) ?? "?" }.joined(separator: ","))]")
        // The filter at ax.rs:1759 is keyed on child_role == "AXMenuBar", so it drops
        // every AXMenuBar-role child, not just the one the AXMenuBar attribute names.
        // Classify each so the blast radius of lifting the filter is explicit.
        let extrasEl = copyAttr(appEl, "AXExtrasMenuBar").map { $0 as! AXUIElement }
        for (i, k) in info.kids.enumerated()
        where axString(k, kAXRoleAttribute as String) == "AXMenuBar" {
            var kind = "neither attribute"
            if let mb = info.mb, CFEqual(k, mb) { kind = "== AXMenuBar attribute" }
            if let ex = extrasEl, CFEqual(k, ex) { kind = "== AXExtrasMenuBar attribute" }
            var cs = Stats()
            countWalk(k, 0, &cs)
            print("    child[\(i)] role=AXMenuBar \(kind) frame=\(frameOf(k)) subtree=\(cs.nodes)")
        }
        guard let mb = info.mb else {
            print("  AXMenuBar attribute = nil  (attribute name present = \(attrs.contains(kAXMenuBarAttribute as String)))")
            print("")
            continue
        }
        print("  AXMenuBar attribute = present; returned in AXChildren = \(info.inChildren)"
            + (info.inChildren ? " (index \(info.childIndex) of \(info.kids.count))" : ""))
        let mbTop = children(mb)
        print("  AXMenuBar top-level items = \(mbTop.count): "
            + mbTop.map { "\"\(axString($0, kAXTitleAttribute as String) ?? "")\"" }.joined(separator: " "))

        var mbRuns: [(Int, Int, Double, String)] = []
        for _ in 0..<REPEAT {
            var s = Stats()
            let (_, dt) = timed { countWalk(mb, 0, &s) }
            mbRuns.append((s.nodes, s.maxDepth, dt, s.caps))
        }
        for (i, r) in mbRuns.enumerated() {
            print("  menubar run\(i + 1): nodes=\(r.0) maxDepth=\(r.1) walk=\(msStr(r.2))ms caps=\(r.3)")
        }

        let restKids = info.kids.filter { !CFEqual($0, mb) }
        var restRuns: [(Int, Int, Double, String)] = []
        for _ in 0..<REPEAT {
            var s = Stats()
            let (_, dt) = timed {
                var anc: [AXUIElement] = [appEl]
                for k in restKids { countWalk(k, 1, &s, &anc) }
            }
            restRuns.append((s.nodes, s.maxDepth, dt, s.caps))
        }
        for (i, r) in restRuns.enumerated() {
            print("  rest    run\(i + 1): nodes=\(r.0) maxDepth=\(r.1) walk=\(msStr(r.2))ms caps=\(r.3) (\(restKids.count) non-menubar children)")
        }

        let mbNodes = mbRuns.map { $0.0 }.min() ?? 0
        let restNodes = restRuns.map { $0.0 }.min() ?? 0
        let total = 1 + mbNodes + restNodes
        print("  => menubar=\(mbNodes) rest=\(restNodes) total=\(total) "
            + "menubar share = \(pctStr(Double(mbNodes) * 100.0 / Double(max(total, 1))))% "
            + "growth factor on tree() = \(String(format: "%.2f", Double(total) / Double(max(1 + restNodes, 1))))x")
        print("")
    }

case "collide":
    // Q4 (name collision). Set of xa11y `name` values in the menu-bar subtree vs
    // the rest of the app tree, intersected — over all nodes, and again scoped to
    // the AX roles that map to Role::MenuItem.
    let onlyBundle = args.dropFirst().first
    print("\n=== name collision: AXMenuBar subtree vs rest of app tree ===")
    print("name rule = xa11y's own (ax.rs:1543): AXTitle, else AXValue if AXStaticText, else AXDescription")
    print("menu_item roles = \(MENU_ITEM_ROLES.sorted().joined(separator: ", "))\n")
    for app in regularApps() {
        let bid = bundleOf(app)
        if let ob = onlyBundle, bid != ob { continue }
        let appEl = appElement(app.processIdentifier)
        let info = menuBarInfo(appEl)
        guard let mb = info.mb else { continue }
        print("--- \(bid) pid=\(app.processIdentifier) ---")

        var mbNames: [(String, String)] = []
        var s1 = Stats()
        let (_, t1) = timed { collectNames(mb, 0, &mbNames, &s1) }
        // Split the non-menu-bar remainder in two. The AXExtrasMenuBar is ALSO an
        // AXMenuBar-role child (see `census`), so lumping it in with window content
        // manufactures a menu-bar-vs-"window" collision that is really menu-bar-vs-
        // status-item-menu. Both are dropped by the same filter, so both come back
        // together; only the window column speaks to the selector question.
        var windowNames: [(String, String)] = []
        var otherBarNames: [(String, String)] = []
        var s2 = Stats()
        var s3 = Stats()
        let (_, t2) = timed {
            var anc: [AXUIElement] = [appEl]
            for k in info.kids where !CFEqual(k, mb) {
                if axString(k, kAXRoleAttribute as String) == "AXMenuBar" {
                    collectNames(k, 1, &otherBarNames, &s3, &anc)
                } else {
                    collectNames(k, 1, &windowNames, &s2, &anc)
                }
            }
        }
        let restNames = windowNames + otherBarNames
        print("  menubar:      \(s1.nodes) nodes, \(mbNames.count) named, collect=\(msStr(t1))ms caps=\(s1.caps)")
        print("  window:       \(s2.nodes) nodes, \(windowNames.count) named, caps=\(s2.caps)")
        print("  other AXMenuBar-role children: \(s3.nodes) nodes, \(otherBarNames.count) named")
        print("  (window + other) collect=\(msStr(t2))ms")

        // Report the AX roles on each side of every collision. A collision only
        // threatens an existing role-scoped selector if the SAME role appears on
        // both sides — otherwise `menu_item[name=X]` could never have matched the
        // window-side node, and lifting the filter cannot steal the match.
        func report(_ label: String, _ a: [(String, String)], _ b: [(String, String)]) {
            var rolesA: [String: Set<String>] = [:]
            var rolesB: [String: Set<String>] = [:]
            for (n, r) in a { rolesA[n, default: []].insert(r) }
            for (n, r) in b { rolesB[n, default: []].insert(r) }
            let sa = Set(a.map { $0.0 })
            let sb = Set(b.map { $0.0 })
            let inter = sa.intersection(sb)
            let interNonEmpty = inter.filter { !$0.isEmpty }
            let sameRole = interNonEmpty.filter { !rolesA[$0]!.isDisjoint(with: rolesB[$0]!) }
            print("  [\(label)] menubar distinct names=\(sa.count) rest distinct names=\(sb.count) "
                + "intersection=\(inter.count) (non-empty \(interNonEmpty.count), "
                + "of which same-role \(sameRole.count))")
            if inter.contains("") { print("    (the empty-string name \"\" is in both — separators and unnamed nodes)") }
            for n in interNonEmpty.sorted() {
                let ra = rolesA[n]!.sorted().joined(separator: "/")
                let rb = rolesB[n]!.sorted().joined(separator: "/")
                let tag = rolesA[n]!.isDisjoint(with: rolesB[n]!) ? "cross-role" : "SAME-ROLE"
                print("    COLLIDE [\(tag)] \"\(n)\"  menubar=\(ra)  window=\(rb)")
            }
        }
        report("all nodes vs WINDOW", mbNames, windowNames)
        report("menu_item scope vs WINDOW",
               mbNames.filter { MENU_ITEM_ROLES.contains($0.1) },
               windowNames.filter { MENU_ITEM_ROLES.contains($0.1) })
        if !otherBarNames.isEmpty {
            report("all nodes vs OTHER MENU BARS", mbNames, otherBarNames)
        }
        report("all nodes vs WINDOW+OTHER (the raw AXChildren remainder)", mbNames, restNames)
        print("")
    }

case "lazy":
    // Q3 (lazy or eager). Cold menu-bar dump, AXPress one top-level menu, re-count.
    // THIS MUTATES THE UI: it opens a menu. It sends Escape afterwards.
    guard args.count >= 3 else { print("usage: lazy <bundle-id> <top-level-menu-title>"); exit(1) }
    let bid = args[1], menuTitle = args[2]
    guard let a = NSWorkspace.shared.runningApplications.first(where: { bundleOf($0) == bid }) else {
        print("\(bid) not running"); exit(1)
    }
    let appEl = appElement(a.processIdentifier)
    guard let mb = menuBarInfo(appEl).mb else { print("no AXMenuBar"); exit(1) }
    print("\n=== lazy-vs-eager: \(bid) pid=\(a.processIdentifier), pressing \"\(menuTitle)\" ===")

    func snapshot(_ label: String) -> Int {
        var s = Stats()
        let (_, dt) = timed { countWalk(mb, 0, &s) }
        print("\(label): menubar nodes=\(s.nodes) maxDepth=\(s.maxDepth) walk=\(msStr(dt))ms caps=\(s.caps)")
        for item in children(mb) {
            var cs = Stats()
            countWalk(item, 0, &cs)
            print("    \"\(axString(item, kAXTitleAttribute as String) ?? "")\" subtree=\(cs.nodes) depth=\(cs.maxDepth) directChildren=\(children(item).count)")
        }
        return s.nodes
    }

    let before = snapshot("COLD")
    guard let target = children(mb).first(where: { axString($0, kAXTitleAttribute as String) == menuTitle }) else {
        print("no top-level menu titled \"\(menuTitle)\""); exit(1)
    }
    let err = AXUIElementPerformAction(target, kAXPressAction as CFString)
    print("\nAXPress \"\(menuTitle)\" -> \(err.rawValue) (\(err == .success ? "success" : "FAILED"))")
    Thread.sleep(forTimeInterval: 1.5)
    let after = snapshot("OPEN")
    print("\ndelta = \(after - before) nodes (\(before) -> \(after))")

    let src = CGEventSource(stateID: .hidSystemState)
    CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 1.0)
    let closed = snapshot("AFTER-ESCAPE")
    print("\nafter dismiss = \(closed) nodes")

case "applist":
    // Q6 (app list diff). current = list_gui_apps(): CGWindowList owner pids with a
    // non-empty owner name. proposed = NSWorkspace .regular + any pid with a live
    // AXExtrasMenuBar. Report the exact symmetric difference.
    var current: [pid_t: String] = [:]
    if let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
        for w in info {
            guard let pid = w["kCGWindowOwnerPID"] as? pid_t else { continue }
            let name = (w["kCGWindowOwnerName"] as? String) ?? ""
            if name.isEmpty { continue }
            if current[pid] == nil { current[pid] = name }
        }
    } else {
        print("CGWindowListCopyWindowInfo returned nil (Screen Recording denied?)"); exit(1)
    }

    let all = NSWorkspace.shared.runningApplications
    var proposed: [pid_t: String] = [:]
    var reason: [pid_t: String] = [:]
    for a in all where a.activationPolicy == .regular {
        proposed[a.processIdentifier] = bundleOf(a)
        reason[a.processIdentifier] = "regular"
    }
    var extrasScanned = 0
    for a in all {
        extrasScanned += 1
        if copyAttr(appElement(a.processIdentifier), "AXExtrasMenuBar") != nil {
            let p = a.processIdentifier
            proposed[p] = bundleOf(a)
            reason[p] = reason[p].map { "\($0)+extras" } ?? "extras"
        }
    }
    print("\n=== app list: current (CGWindowList) vs proposed (regular + AXExtrasMenuBar) ===")
    print("NSWorkspace.runningApplications total = \(all.count) "
        + "(regular=\(all.filter { $0.activationPolicy == .regular }.count) "
        + "accessory=\(all.filter { $0.activationPolicy == .accessory }.count) "
        + "prohibited=\(all.filter { $0.activationPolicy == .prohibited }.count))")
    print("extras attribute probed on all \(extrasScanned) of them")
    print("current = \(current.count) pids; proposed = \(proposed.count) pids")

    func axKids(_ p: pid_t) -> Int { children(appElement(p)).count }
    func label(_ p: pid_t) -> String {
        let bid = NSRunningApplication(processIdentifier: p)?.bundleIdentifier ?? "-"
        let pol = NSRunningApplication(processIdentifier: p)?.activationPolicy.rawValue
        let k = axKids(p)
        return "pid=\(p) bundle=\(bid) policy=\(pol.map(String.init) ?? "?") axChildren=\(k)"
            + (k == 0 ? "  <-- ZERO AX CHILDREN" : "")
    }

    let onlyCurrent = Set(current.keys).subtracting(proposed.keys).sorted()
    let onlyProposed = Set(proposed.keys).subtracting(current.keys).sorted()
    let both = Set(current.keys).intersection(proposed.keys).sorted()
    print("\n--- DISAPPEAR (\(onlyCurrent.count)): in current, not in proposed ---")
    for p in onlyCurrent { print("  \(label(p)) cgOwnerName=\"\(current[p] ?? "")\"") }
    print("\n--- APPEAR (\(onlyProposed.count)): in proposed, not in current ---")
    for p in onlyProposed { print("  \(label(p)) reason=\(reason[p] ?? "?")") }
    print("\n--- IN BOTH (\(both.count)) ---")
    for p in both { print("  \(label(p)) cgOwnerName=\"\(current[p] ?? "")\" reason=\(reason[p] ?? "?")") }

case "timeone":
    // Time the individual AX queries against ONE pid. Used with SIGSTOP to make a
    // deliberately unresponsive app and measure what an enumeration pays for it.
    guard args.count >= 2, let pid = pid_t(args[1]) else { print("usage: timeone <pid> [timeout-secs]"); exit(1) }
    let el = appElement(pid)
    if args.count >= 3, let t = Double(args[2]) {
        AXUIElementSetMessagingTimeout(el, Float(t))
        print("AXUIElementSetMessagingTimeout = \(t)s")
    }
    print("pid=\(pid) (\(procName(pid)))")
    for attr in ["AXRole", "AXMenuBar", "AXExtrasMenuBar", "AXChildren"] {
        let (v, dt) = timed { copyAttr(el, attr) }
        print("  \(attr): \(msStr(dt))ms -> \(v == nil ? "nil" : "present")")
    }
    let (names, dtn) = timed { attrNames(el) }
    print("  AXUIElementCopyAttributeNames: \(msStr(dtn))ms -> \(names.count) names")

case "lockcheck":
    // Screen-lock state, and what it does to each regular app's AXChildren.
    // Added after a census run straddled an automatic screen lock and the
    // affected apps started returning the AXApplication element as its own
    // child. Everything the census reports depends on this being 0.
    var locked = "unknown"
    if let d = CGSessionCopyCurrentDictionary() as? [String: Any] {
        locked = "\(d["CGSSessionScreenIsLocked"] ?? 0)"
    }
    print("\n=== CGSSessionScreenIsLocked = \(locked) ===")
    print("(1 = screen locked. Menu-bar subtrees stay intact either way; window subtrees do not.)\n")
    for app in regularApps() {
        let appEl = appElement(app.processIdentifier)
        let kids = children(appEl)
        var flags: [String] = []
        for (i, k) in kids.enumerated() {
            let r = axString(k, kAXRoleAttribute as String) ?? "?"
            if CFEqual(k, appEl) { flags.append("child[\(i)] IS THE APP ELEMENT (role=\(r))") }
        }
        var mbNodes = -1
        if let mb = menuBarInfo(appEl).mb {
            var s = Stats(); countWalk(mb, 0, &s); mbNodes = s.nodes
        }
        print("\(bundleOf(app)) pid=\(app.processIdentifier) "
            + "childRoles=[\(kids.map { axString($0, kAXRoleAttribute as String) ?? "?" }.joined(separator: ","))] "
            + "menubarNodes=\(mbNodes) selfRefChildren=\(flags.count)")
        for f in flags { print("    \(f)") }
    }

case "extrascost":
    // Q7 (fan-out cost). Time the AXExtrasMenuBar query across every running process.
    let all = NSWorkspace.shared.runningApplications
    print("\n=== AXExtrasMenuBar fan-out cost over \(all.count) processes, \(REPEAT) rounds ===")
    // The timeout is a property of the AXUIElement instance, not of the pid, so it
    // has to be set on the very element the query goes through. Setting it on a
    // throwaway element created from the same pid does nothing — that was the first
    // version of this probe, and it measured no effect because it had no effect.
    var timeoutSecs: Float? = nil
    if let t = args.dropFirst().first, let secs = Double(t) {
        timeoutSecs = Float(secs)
        print("AXUIElementSetMessagingTimeout = \(secs)s, applied to each element before its query")
    } else {
        print("messaging timeout = system default (no AXUIElementSetMessagingTimeout call)")
    }
    for round in 1...max(REPEAT, 1) {
        var rows: [(Double, String, pid_t, Bool)] = []
        let t0 = ProcessInfo.processInfo.systemUptime
        for a in all {
            let el = appElement(a.processIdentifier)
            if let t = timeoutSecs { AXUIElementSetMessagingTimeout(el, t) }
            let (v, dt) = timed { copyAttr(el, "AXExtrasMenuBar") }
            rows.append((dt, bundleOf(a), a.processIdentifier, v != nil))
        }
        let total = ProcessInfo.processInfo.systemUptime - t0
        let hits = rows.filter { $0.3 }
        print("\nround \(round): total=\(msStr(total))ms for \(all.count) processes "
            + "(mean \(msStr(total / Double(all.count)))ms) hits=\(hits.count)")
        for r in rows.sorted(by: { $0.0 > $1.0 }).prefix(8) {
            print("    slowest: \(msStr(r.0))ms  \(r.1) pid=\(r.2) hit=\(r.3)")
        }
        let slow = rows.filter { $0.0 > 0.1 }
        print("    queries over 100ms: \(slow.count)")
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
      census [<bundle-id>]    menu-bar vs rest-of-tree node counts, depth, wall clock (regular apps)
      collide [<bundle-id>]   name-set intersection between menu bar and window content
      lazy <bundle-id> <menu> cold menu-bar counts, AXPress a top-level menu, re-count (MUTATES)
      applist                 current (CGWindowList) vs proposed (regular + AXExtrasMenuBar) app list
      timeone <pid> [secs]    time individual AX queries against one pid (use with SIGSTOP)\n      lockcheck               screen-lock state + whether any app returns itself as its own child\n      extrascost [<secs>]     AXExtrasMenuBar fan-out cost; optional AXUIElementSetMessagingTimeout
    env MAXD=<n> controls dump depth (default 8)
    env NODECAP/DEPTHCAP bound counting walks (default 400000 / 80); REPEAT sets repeats (default 3)
    """)
}
