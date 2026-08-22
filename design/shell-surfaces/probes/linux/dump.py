#!/usr/bin/env python3
"""Dump the AT-SPI2 desktop tree, with the detail a shell-surface design needs.

Usage: dump.py [maxdepth] [--press NAME]
"""
import sys

import pyatspi

args = sys.argv[1:]
MAXD = 14
PRESS = None
i = 0
while i < len(args):
    if args[i] == "--press-at":
        PRESS = ("at", int(args[i + 1]), int(args[i + 2]))
        i += 3
    elif args[i] == "--press":
        PRESS = args[i + 1]
        i += 2
    else:
        MAXD = int(args[i])
        i += 1


def iface_names(node):
    try:
        return sorted(node.get_interfaces())
    except Exception:
        return []


def actions(node):
    try:
        a = node.queryAction()
    except Exception:
        return []
    return [a.getName(n) for n in range(a.nActions)]


def states(node):
    try:
        s = node.getState()
    except Exception:
        return []
    out = []
    for name in (
        "VISIBLE",
        "SHOWING",
        "ENABLED",
        "SENSITIVE",
        "FOCUSABLE",
        "FOCUSED",
        "SELECTABLE",
        "SELECTED",
        "EXPANDABLE",
        "EXPANDED",
        "CHECKED",
    ):
        const = getattr(pyatspi, "STATE_" + name, None)
        if const is not None and s.contains(const):
            out.append(name)
    return out


def extents(node):
    try:
        e = node.queryComponent().getExtents(pyatspi.DESKTOP_COORDS)
        return f"[{e.x},{e.y} {e.width}x{e.height}]"
    except Exception:
        return "[-]"


def pid_of(node):
    for attr in ("get_process_id", "getProcessID"):
        f = getattr(node, attr, None)
        if f:
            try:
                return f()
            except Exception:
                pass
    return "?"


def label(node, depth):
    try:
        name = node.name
        role = node.getRoleName()
    except Exception as exc:
        return "  " * depth + f"<unreadable: {exc}>"
    try:
        desc = node.description
    except Exception:
        desc = ""
    try:
        attrs = node.getAttributes()
    except Exception:
        attrs = []
    line = (
        f"{'  ' * depth}{role} {name!r} pid={pid_of(node)} {extents(node)} "
        f"states=[{','.join(states(node))}] actions=[{','.join(actions(node))}] "
        f"ifaces=[{','.join(i for i in iface_names(node) if i != 'Accessible')}]"
    )
    if desc:
        line += f" desc={desc!r}"
    if attrs:
        line += f" attrs={attrs}"
    return line


def dump(node, depth=0):
    print(label(node, depth))
    if depth >= MAXD:
        return
    try:
        n = node.childCount
    except Exception:
        return
    for idx in range(min(n, 200)):
        try:
            child = node.getChildAtIndex(idx)
        except Exception:
            continue
        if child is not None:
            dump(child, depth + 1)


def walk(node, fn, depth=0):
    if depth > 20:
        return
    fn(node)
    try:
        n = node.childCount
    except Exception:
        return
    for idx in range(min(n, 200)):
        try:
            child = node.getChildAtIndex(idx)
        except Exception:
            continue
        if child is not None:
            walk(child, fn, depth + 1)


desktop = pyatspi.Registry.getDesktop(0)

if PRESS:
    hits = []

    def collect(node):
        try:
            if isinstance(PRESS, tuple):
                e = node.queryComponent().getExtents(pyatspi.DESKTOP_COORDS)
                if (
                    e.x <= PRESS[1] < e.x + e.width
                    and e.y <= PRESS[2] < e.y + e.height
                    and node.queryAction().nActions > 0
                ):
                    hits.append(node)
            elif node.name == PRESS:
                hits.append(node)
        except Exception:
            pass

    for idx in range(desktop.childCount):
        app = desktop.getChildAtIndex(idx)
        if app is not None:
            walk(app, collect)
    if not hits:
        print(f"no node named {PRESS!r}")
    else:
        target = hits[-1]
        print("pressing: " + label(target, 0))
        a = target.queryAction()
        print(f"doAction(0) [{a.getName(0)}] -> {a.doAction(0)}")
    sys.exit(0)

print(f"desktop children = {desktop.childCount}")
for idx in range(desktop.childCount):
    app = desktop.getChildAtIndex(idx)
    if app is None:
        continue
    try:
        toolkit = app.toolkitName
    except Exception as exc:
        toolkit = f"<{exc}>"
    try:
        version = app.version
    except Exception:
        version = "?"
    print(f"\n=== app[{idx}] {app.name!r} toolkit={toolkit} version={version} ===")
    dump(app, 0)
