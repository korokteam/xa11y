# Shell surfaces in the accessibility tree — field report for xa11y#374

**What this is.** Direct measurement of how OS-owned UI (taskbar, tray, system menu bar,
docks, desktop, shell flyouts, shell context menus) is represented in each platform's
accessibility API — and what xa11y sees of it today. Applications are deliberately out of
scope; they are already covered.

**Status:** Windows measured. Linux measured. macOS measured — on macOS 26.5.2 (25F84),
arm64, in an attended session with Accessibility granted. Raw dumps in
`evidence/mac-*.txt`.

Everything below marked *measured* has raw output in `evidence/`. Everything marked
*unverified* is exactly that.

---

## 0. Reproducing

```
# Windows — run in an interactive desktop session
cd design/shell-surfaces/probes/windows && cargo build --release
./target/release/shell-probe roots --raw          # UIA desktop-root children
./target/release/shell-probe rootchild Taskbar --depth 9 --raw
./target/release/shell-probe act 0x<taskbar-hwnd> "Show Hidden Icons" invoke
./target/release/shell-probe act 0x<hwnd> "<name>" ctx   # IUIAutomationElement3::ShowContextMenu

# Linux
cd design/shell-surfaces/probes/linux
docker build -t xa11y-shell-linux . && docker run --rm xa11y-shell-linux

# macOS — run from a terminal granted Accessibility permission
cd design/shell-surfaces/probes/macos
swift shell-probe.swift apps                    # per-process AXMenuBar / AXExtrasMenuBar
swift shell-probe.swift extras                  # status items, every process
swift shell-probe.swift dock
swift shell-probe.swift cgwindows               # xa11y's list_gui_apps() basis
swift shell-probe.swift app com.apple.controlcenter
swift shell-probe.swift hittest 100 900
swift shell-probe.swift showmenu com.apple.dock Finder
swift shell-probe.swift press com.apple.controlcenter id:com.apple.menuextra.controlcenter
swift shell-probe.swift dismiss                 # Escape, to close a flyout a probe opened
```

### Environment caveats that limit the macOS results

Attended session, single 1920x1243-point display, one user. Consequences:

- Accessibility was granted but **Screen & System Audio Recording was not required** for
  anything measured here. That matters, because Screen Recording is what gates layer-0
  windows in `CGWindowListCopyWindowInfo`, and therefore gates `list_gui_apps()` — a
  different permission from the AX trust that gates the trees themselves (§4.6).
- The status-item population is whatever this machine happens to run: four processes own
  an `AXExtrasMenuBar`, two of them third-party. The *shapes* below generalise; the
  counts do not.
- `press` and `showmenu` mutate the UI. Every such probe here was followed by
  `dismiss`. Unlike the Windows session, input simulation and foreground activation both
  work, so there is no headless control group — the CI question for macOS is open.

### Environment caveats that limit the Windows results

The Windows session is **RDP session 1 in `Disc` (disconnected) state**, 640×480, Windows 11
Pro 26200. Two consequences, both measured:

- `GetForegroundWindow()` returns `NULL`, and `SendInput` fails with `ERROR_ACCESS_DENIED (5)`
  even for a bare mouse move. **No input simulation was possible at all**, so the "right-click
  the tray icon" path could not be exercised by simulation.
- Shell surfaces hosted **outside** explorer that need foreground activation
  (Start menu, Search, Task View) did not open when driven through UIA. Surfaces that do not
  (tray overflow, Quick Settings, Notification Center, shell context menus) opened fine. So
  the failures below are *not* a blanket "nothing works" — there is a working control group.

This is worth keeping: it is the same shape as a CI/headless runner, so it is a preview of
what integration tests for this feature can and cannot assert.

---

## 1. The gate today is discovery, not capability

On all three platforms these surfaces are **already ordinary elements in the ordinary tree**.
Nothing is hidden behind a private API. What blocks xa11y is per-platform root filtering.

**Windows** — `xa11y-windows/src/uia.rs:507-552`. `get_children(None)` takes the UIA desktop
root's children, keeps only `ControlType == Window`, requires a non-empty `Name`, and
deduplicates by PID. Every shell surface is a `Pane`, so every one is dropped:

```
$ xa11y apps
7836    Windows PowerShell                 # ← the only app; explorer.exe absent

$ xa11y tree --pid 8008                    # explorer
error: No element matched selector: application with pid=8008
```

while the raw UIA root at the same moment contained (`evidence/win-01-uia-root-children.txt`):

```
Pane "Desktop 1"            class=#32769
  Pane "Taskbar"            class=Shell_TrayWnd            pid=8008(explorer.exe)
  Pane "Program Manager"    class=Progman                  pid=8008(explorer.exe)
  Window "Windows PowerShell" class=CASCADIA_HOSTING_WINDOW_CLASS pid=7836
  ... (+ transient shell surfaces, see §2.5)
```

**Linux** — `xa11y-linux/src/atspi.rs:1208-1243`. `get_children(None)` returns *every* AT-SPI
application with a non-empty name. Measured: the panel is right there.

```
desktop children = 4
  'xfce4-panel'   'wrapper-2.0'   'wrapper-2.0'   'trayapp.py'
```

So on Linux **xa11y can already reach the panel today** — `app("xfce4-panel")` works. There is
no `Unsupported` to return for panels; only the *tray protocol* has a genuine gap (§3).

**macOS** — two independent gates, and only the first was known before measuring.

*Gate one, the menu bar.* `xa11y-macos/src/ax.rs:1759-1761` explicitly filters it out:

```rust
if parent_role == Role::Application && child_role == "AXMenuBar" {
    return true;   // filter
}
```

The role mapping already knows `AXMenuBar` / `AXMenuBarExtra` → `Role::MenuBar`
(`docs/site/src/content/docs/guides/platform-details.mdx:25`). So on macOS the menu bar is
reachable and mapped, and is being deliberately dropped one line deep in the child filter.
(An earlier draft of this report cited `ax.rs:1605-1607`; the filter is at 1759-1761 at the
tip of this branch. The code is unchanged, the citation was wrong.)

*Gate two, app discovery — measured, and the more consequential of the two.*
`list_gui_apps()` (`ax.rs:1311`) builds the app list from `CGWindowListCopyWindowInfo`,
keyed by `kCGWindowOwnerPID` with a non-empty `kCGWindowOwnerName`. Measured
(`mac-09-cgwindow-owners.txt`): 29 owner pids, all named, so the name rule drops nothing.
Dock, Control Center, Notification Center, Finder and Spotlight are all in that list and
are **nameable today**.

But a status-item-only accessory app is not:

```
com.haystacksoftware.ArqMonitor  pid=41090   AXExtrasMenuBar = populated, menu works
                                             CGWindowList entries = 0
```

It owns no CG window, so `list_gui_apps()` cannot see it — while its `AXExtrasMenuBar` is
fully enumerable through `AXUIElementCreateApplication(pid)`. `SystemUIServer`,
`WallpaperAgent` and `WindowManager` are absent for the same reason. So on macOS the tray
equivalent fans out over processes, and some of those processes are invisible to the app
list even though the AX API serves them.

*Already reachable, needing nothing.* The **desktop** is an `AXScrollArea` with
`AXDescription = "desktop"` sitting directly in Finder's `AXChildren`, not in `AXWindows`
(`mac-04-finder-desktop.txt`). Since `ax.rs:376` reads `AXChildren` and never touches
`AXWindows`, the desktop and its icons are already in the walk.

> **Design consequence.** The feature is less "add a new primitive" than "stop filtering, and
> give callers a way to name the surfaces". A synthetic `MenuBar` root would invent a parent
> that exists on no platform, and on Windows would have to merge ≥6 unrelated top-level
> windows under it.
>
> The macOS measurement adds a second, cheaper consequence: one of the two gates is in the
> **app list**, not the tree walk. A process that owns a status item but no window is
> unreachable by name today, and widening `list_gui_apps()` past `CGWindowListCopyWindowInfo`
> (e.g. `NSWorkspace.runningApplications` filtered to a live `AXExtrasMenuBar`) fixes that
> without touching the element model at all.

---

## 2. Windows 11 (26200) — measured

### 2.1 Surface inventory

Every one of these is a direct child of the UIA desktop root. None is `ControlType == Window`
except Notification Center.

| Surface | Class | Control type | Host process | Lifetime |
|---|---|---|---|---|
| Taskbar (incl. tray) | `Shell_TrayWnd` | Pane | explorer.exe | permanent |
| Desktop icons | `Progman` | Pane | explorer.exe | permanent |
| Tray overflow flyout | `TopLevelWindowForOverflowXamlIsland` | Pane | explorer.exe | **root child only while open** |
| Quick Settings | `ControlCenterWindow` | Pane | ShellHost.exe | created on first open, then persists hidden |
| Notification Center | `Windows.UI.Core.CoreWindow` | **Window** | ShellExperienceHost.exe | created on open, removed on close |
| Shell context menu | `Microsoft.UI.Content.PopupWindowSiteBridge` ("PopupHost") | Pane | explorer.exe | while open |
| Start / Search / Task View | — | — | StartMenuExperienceHost.exe / SearchHost.exe / explorer | **never materialised in this session** |

### 2.2 Taskbar anatomy (`evidence/win-02-taskbar-raw.txt`)

```
Pane "Taskbar" class=Shell_TrayWnd fw=Win32
├─ Pane "" class=TrayNotifyWnd                      ← EMPTY (no children)
├─ Pane "" class=ReBarWindow32
│   └─ Pane "Running applications" class=MSTaskSwWClass   ← EMPTY (no children)
└─ Pane "DesktopWindowXamlSource" class=Windows.UI.Composition.DesktopWindowContentBridge
    └─ Pane "" class=Windows.UI.Input.InputSite.WindowClass  fw=XAML
        ├─ Pane "" aid=TaskbarFrame
        │   └─ Group aid=TaskbarFrameRepeater
        │       ├─ Button "Widgets 86°F Clear"  aid=WidgetsButton   class=ToggleButton
        │       ├─ Button "Start"               aid=StartButton     class=ToggleButton
        │       ├─ Button "Search"              aid=SearchButton    class=ToggleButton
        │       ├─ Button "Task View"           aid=TaskViewButton  class=ToggleButton
        │       └─ Button "Terminal - 3 running windows pinned"
        │              aid="Appid: Microsoft.WindowsTerminal_8wekyb3d8bbwe!App"
        │              class=Taskbar.TaskListButtonAutomationPeer
        ├─ Button "Show Hidden Icons"        aid=SystemTrayIcon class=SystemTray.NormalButton
        ├─ Button "Network <SSID>\nInternet access\n\nTailscale\nNo internet access"
        │                                    aid=SystemTrayIcon class=SystemTray.AccentButton
        ├─ Button "Volume No audio device is installed"  aid=SystemTrayIcon
        ├─ Button "Clock 10:27 AM\n‎8/‎22/‎2026"          aid=SystemTrayIcon class=SystemTray.OmniButton
        └─ Button "Show Desktop"             aid=SystemTrayIcon class=SystemTray.ShowDesktopButton
```

Points that matter:

- **The Win7–10 named-region walk finds nothing here.** `TrayNotifyWnd` and `MSTaskSwWClass`
  still exist as HWNDs but are childless husks. A dual-discovery implementation must treat an
  empty legacy region as "this is Win11", not as "no icons" — which is exactly the
  fail-loudly-on-unknown-layout requirement in the issue, now with a measured trigger.
- **The tray is not a subtree.** The `SystemTray*` buttons are siblings of `TaskbarFrame`
  under the same `InputSite`, in both the control view and the raw view. There is no
  "notification area" container element to hand back as a group.
- **`AutomationId` does not identify an icon.** Every icon on the visible row is
  `aid="SystemTrayIcon"`. The only discriminators are `ClassName`
  (`NormalButton` / `AccentButton` / `OmniButton` / `OmniButtonRight` / `ShowDesktopButton`)
  and `Name`.
- **`Name` is a flattened, stateful tooltip.** It embeds newlines, LTR marks (`‎`), and
  live state: `"Terminal - 3 running windows pinned"`, `"Clock 10:27 AM\n‎8/‎22/‎2026"`. Any
  selector built on it breaks when the state changes. The Network button's name even contains
  a *second* app's status (`Tailscale`) because it is an aggregated flyout button.
- **App attribution is genuinely absent.** Every node reports `pid=8008 (explorer.exe)`. The
  owning processes do exist as hidden HWNDs (`SecHealth Window Class` → SecurityHealthSystray.exe,
  `MSRDCSysTrayClass_WSL` → msrdc.exe, `tray_icon_app` → pulpw.exe;
  `evidence/win-05-toplevel-hwnds.txt`) but nothing in UIA links a tray button to them. The
  issue's "omit `pid` on Windows" is correct.
- One useful exception: taskbar **app** buttons carry the AppUserModelID in `AutomationId`
  (`"Appid: Chrome"`, `"Appid: Microsoft.WindowsStore_8wekyb3d8bbwe!App"`). That is a stable
  key — for the task band, not for the tray.

### 2.3 The overflow flyout is genuinely stateful

Measured, `evidence/win-06-…` / `win-07-…`:

- Closed: `TopLevelWindowForOverflowXamlIsland` is **not** a child of the UIA root at all. Its
  HWND persists but `ElementFromHandle` yields a host Pane with **zero children** and legacy
  state `0x108000` (`STATE_SYSTEM_INVISIBLE`). The XAML island is not instantiated.
- `Invoke()` on `Button "Show Hidden Icons"` → `Ok(())`, window flips `vis=0 → vis=1`, and the
  icons appear.
- Open, the icons are distinguishable from the pinned row by `AutomationId`:
  **`aid="NotifyItemIcon"`** vs `aid="SystemTrayIcon"`. That is a real, cheap signal for
  `area: visible | overflow`.

```
Button "Pulp is running"                              aid=NotifyItemIcon  pats=[Invoke,...]
Button " Ollama"                                      aid=NotifyItemIcon
Button " Docker Desktop running"                      aid=NotifyItemIcon
Button " Tailscale: Connected. Click for options."    aid=NotifyItemIcon
Button "Bluetooth Devices"                            aid=NotifyItemIcon
Button "Windows Security - No actions needed. …"      aid=NotifyItemIcon
```

(Note the leading spaces — the tooltip is concatenated after an empty app-name field.)

> **Design consequence.** "List the hidden tray icons" **cannot** be a read-only operation on
> Windows. It requires genuinely pressing the chevron. Any `tree`/`dump` of the tray either
> mutates the screen or is incomplete, and the API should make the caller choose which.

### 2.4 Action fidelity — three measured traps

These are the sharpest findings in the report, because each one is a *silent* failure and
xa11y's tenet 1 forbids exactly that.

**(a) Taskbar app buttons expose no activation pattern at all.**
`Taskbar.TaskListButtonAutomationPeer` supports only `ScrollItem`, `LegacyIAccessible`, `Drag` —
no Invoke, no Toggle, no SelectionItem, no ExpandCollapse. xa11y's `press`
(`uia.rs:715-789`) tries exactly those four and then returns `ActionNotSupported`. So today
`press` on a taskbar app button fails. The only remaining path is
`LegacyIAccessible::DoDefaultAction` (its `DefaultAction` string is `"Press"`), which returns
`S_OK` — but in this session it did **not** launch Chrome or raise Terminal. Adding it as a
fallback would be both a tenet-1 fallback chain and unverified.

**(b) `Toggle` on the Start button lies.**

```
act "Start" toggle  → Toggle -> Ok(())
Button "Start" … legacy{state=0x100014} toggle=Ok(1)     # now reports CHECKED/pressed
```

…and no Start menu appeared; `StartMenuExperienceHost.exe` never created a window. The
element's *visual state changed* while the *action did not happen*. Because xa11y's `press`
falls through Invoke → **Toggle**, `press` on `Start`/`Search`/`Task View`/`Widgets` would
report success and do nothing. (Foreground activation is blocked in this session, so the
underlying cause may be environmental — but the *false success* is not: the API returned
`S_OK` and flipped `ToggleState` regardless.)

**(c) `ShowContextMenu` works on Win32 shell UI and silently no-ops on XAML shell UI.**

`IUIAutomationElement3::ShowContextMenu` is a real accessibility API — not input simulation.
Measured with before/after top-level window snapshots:

| Target | Result | Popup created? |
|---|---|---|
| Desktop `ListItem "Recycle Bin"` (SysListView32) | `S_OK` | **yes** — 8 `PopupHost` windows |
| Tray icon `Button "Pulp is running"` (XAML) | `S_OK` | **no** — window set unchanged |
| Taskbar app button `"Terminal - 3 running windows"` (XAML) | `S_OK` | **no** |

The desktop context menu it produced is fully accessible:

```
Pane "PopupHost" class=Microsoft.UI.Content.PopupWindowSiteBridge
  └─ Window "Popup" aid=OverflowPopup
      └─ Pane class=ScrollViewer
          ├─ MenuItem "Open"                aid=open              pats=[Invoke] legacy action="Execute"
          ├─ MenuItem "Empty Recycle Bin"   aid=empty
          ├─ MenuItem "Pin to Quick access" aid=pintohome
          ├─ MenuItem "Pin to Start"        aid=PinToStartScreen
          ├─ MenuItem "Properties"          aid=properties
          └─ MenuItem "Show more options"   aid=expandtoclassic
```

> **Design consequence.** The issue says the tray context menu has *no* accessibility
> interface and must be an `InputSim` composition. That is half right: the interface exists
> and is standard, but the Win11 XAML tray peer does not implement it — **and returns `S_OK`
> anyway**, so the failure is undetectable from the HRESULT. If `show_menu` is ever advertised
> on Windows shell chrome, the provider has to *verify a popup appeared* and error if not.
> That is a new shape of provider contract worth naming explicitly.

### 2.5 Other shell surfaces

**Desktop** (`evidence/win-04-desktop-progman.txt`) — completely conventional and the best-behaved
surface on Windows:

```
Pane "Program Manager" class=Progman
  └─ Pane class=SHELLDLL_DefView
      └─ List "Desktop" class=SysListView32 aid=1  pats=[MultipleView,Selection]
          ├─ ListItem "Recycle Bin"  aid=ListViewItem-0  pats=[Invoke,ScrollItem,SelectionItem]
          │                                              legacy action="Double Click"
          └─ ListItem "Google Chrome" aid=ListViewItem-2 …
```

**Quick Settings** (`evidence/win-08-…`) — hosted by `ShellHost.exe`, and unlike the tray it has
**stable, meaningful AutomationIds**:

```
Button "Wi-Fi"          aid=Microsoft.QuickAction.WiFi              pats=[Toggle]  toggle=On
Button "Bluetooth"      aid=Microsoft.QuickAction.Bluetooth         pats=[Toggle]
Button "Airplane mode"  aid=Microsoft.QuickAction.AirplaneMode      pats=[Toggle]
Button "Accessibility"  aid=Microsoft.QuickAction.Accessibility     pats=[Invoke]
Button "Night light"    aid=Microsoft.QuickAction.BlueLightReduction
Button "Manage Wi-Fi connections"  aid=SplitL2Button                pats=[Invoke]
```

Two lifetime quirks: the `ControlCenterWindow` host **stays a root child with unchanged bounds
after dismissal** — only the XAML content goes `IsOffscreen` with `0x0` rects. Visibility must
be read from the content, not the host. And in this headless session the content never
rendered at all (68 of 74 nodes `OFFSCREEN`), while Notification Center did render — so
"opened" and "rendered" are separable states.

**Notification Center** (`evidence/win-09-…`) — the one shell surface that *is* `ControlType == Window`,
so it would already survive xa11y's root filter once open. Stable aids throughout
(`NotificationCenterGrid`, `DoNotDisturbButton`, `ClearAllButton`, `MainListView`,
`ExpandButton`, `DismissButton`, `CalendarCenterGrid`). **Its `Name` changes with state**:
`"Windows Shell Experience Host"` in transition, `"Notification Center"` when open. Another
name-based-selector hazard.

**Transient junk in the tree.** While the overflow was open, the same host window also carried a
`Xaml_WindowedPopupClass` → `Window "Popup"` → `ToolTip "Pulp is running"` subtree — a hover
tooltip materialising as a sibling of the icons. Whatever the abstraction is, it will need a
story for tooltip/popup nodes appearing and vanishing under shell roots.

**Not covered** (could not be reached here): Start menu, Search flyout, Task View,
Widgets board, jump lists, multi-monitor `Shell_SecondaryTrayWnd`, Windows 10 layout,
lock screen, UAC secure desktop, IME candidate window.

---

## 3. Linux — measured (Ubuntu 24.04, Xvfb, xfce4-panel, AT-SPI2)

`evidence/linux-01-atspi-panel-and-tray.txt`. The container runs a real panel plus a probe app
publishing **both** tray protocols at once: a legacy XEmbed `Gtk.StatusIcon` and a
StatusNotifierItem via AyatanaAppIndicator.

### 3.1 The panel is an ordinary application, and it is already reachable

```
application 'xfce4-panel' pid=37
  frame '' pid=37 [0,0 1280x27]  attrs=['toolkit:gtk', 'window-type:dock']     ← the panel
    panel ''
      toggle button 'Applications'  actions=[click]  desc='Applications'
      toggle button '2026-08-22'    actions=[click]                            ← clock
      toggle button 'root'          actions=[click]                            ← user menu
  frame '' pid=37 [487,975 306x49] attrs=['toolkit:gtk', 'window-type:dock']   ← the dock
      toggle button 'Show Desktop'  actions=[click] desc='Minimize all open windows…'
      push button   'Terminal Emulator' actions=[click]
```

- **`window-type:dock` in the AT-SPI attribute set is the natural discriminator** between shell
  chrome and app windows. Nothing else is needed to classify Linux surfaces.
- Panel plugins run **out of process** (`wrapper-2.0`, pids 54/58) yet are spliced into the
  panel's tree transparently, and *each node reports its true owning pid*. Cross-process app
  attribution — the thing that is impossible on Windows — is free here.

### 3.2 The two tray protocols behave in opposite, complementary ways

```
panel [1115,0 53x26]                                        ← systray plugin (pid 54)
├─ panel [1115,0 26x26]
│   └─ filler → filler pid=66                               ← crosses into the owning app
│       └─ frame 'LegacyXEmbedIcon' pid=66 window-type:normal desc='Legacy XEmbed icon'
│           └─ icon '' pid=66 [1117,2 22x22] actions=[]           ← XEmbed: named, NOT pressable
├─ panel [1142,0 26x26]
│   └─ push button '' pid=54 actions=[click]                      ← SNI: pressable, ANONYMOUS
└─ toggle button '' pid=54 [-2147483648,-2147483648 1x1] actions=[click]   ← hidden-items toggle
```

| | Legacy XEmbed (`GtkStatusIcon`) | StatusNotifierItem (D-Bus) |
|---|---|---|
| In the AT-SPI tree? | yes, as the app's own `frame`+`icon` | yes, but only as the panel's `push button` |
| Name / description | **yes** — `set_title` → frame name, tooltip → desc | **no** — empty name, empty desc |
| Owning pid | **yes** (66 = the app) | **no** (54 = the panel plugin) |
| Activatable via AT-SPI | **no** — `actions=[]` | **yes** — `actions=[click]` |
| Menu reachable via AT-SPI | (untested) | **no** — see below |

Both were live: `org.kde.StatusNotifierWatcher` reported
`RegisteredStatusNotifierItems = [':1.14/org/ayatana/NotificationItem/xa11y_probe_sni']` and
`IsStatusNotifierHostRegistered = true`.

**The SNI menu is invisible to AT-SPI.** `doAction("click")` on the SNI push button returned
`True`, and a full before/after diff of the AT-SPI desktop tree showed **no change** — no menu
node anywhere. SNI menus are `com.canonical.dbusmenu` objects on the session bus; they are not
accessibility objects at all.

> **Design consequence.** The issue's "Linux returns `Unsupported` because tray icons use SNI,
> a separate subsystem" is right about the *mechanism* but wrong about the *scope*. Panels are
> fully available today. Even tray icons are partially available: XEmbed icons give you
> identity and owner, SNI icons give you activation. What is genuinely unavailable is the SNI
> **menu**, and only that.

**Unresolved on Linux:** `doAction("click")` on `toggle button 'Applications'` returned `True`
and set `CHECKED`, but no menu frame appeared. There is no window manager in the container, so
this cannot be attributed to the a11y layer vs. the plugin. It echoes the Windows Start-button
result closely enough to be worth re-running on a real desktop session.

**Not covered:** GNOME Shell top bar (St widgets over AT-SPI), KDE Plasma panel (Qt over
AT-SPI), Wayland variants of any of it.

---

## 4. macOS — measured

macOS 26.5.2 (25F84), arm64, attended session, Accessibility granted to the terminal
running `swift`. Every claim here has a dump in `evidence/mac-*.txt`.

The short version: **macOS is the best-behaved of the three platforms.** Identity is
strong, the owning process is always known, most surfaces need no click to enumerate,
`AXShowMenu` genuinely works, and no probe produced a false success. The gap is almost
entirely in discovery, and half of it is in the app list rather than the tree.

### 4.1 Status items are a per-process fan-out, not one tray

There is no tray object. Each process that vends a status item owns its own
`AXExtrasMenuBar` (`mac-02`). On this machine, 4 of 67 apps had one:

```
com.apple.controlcenter    7 AXMenuBarItem (4 live + 3 zero-size DISABLED placeholders)
com.apple.Spotlight        1
com.haystacksoftware.ArqMonitor  1   (third-party, NSMenu-backed)
com.openai.codex           1   (third-party, NSMenu-backed)
```

Windows has one tray to walk; Linux has N panel processes; macOS has N *application*
processes, and the only way to find them is to ask every process. Note also that
`AXExtrasMenuBar` and `AXMenuBar` appear in the **attribute-name list of nearly every
process** while their value is nil (`mac-01`) — name presence is not a discriminator, the
value has to be read.

### 4.2 Identity is strong — the opposite of Windows

Windows tray icons all share `aid="SystemTrayIcon"`. macOS carries a real identifier on
almost everything:

| Surface | Identity |
|---|---|
| Apple menu extras | `AXIdentifier` = `com.apple.menuextra.battery` / `.clock` / `.wifi` / `.controlcenter` |
| Control Center controls | `controlcenter-wifi`, `controlcenter-bluetooth`, `controlcenter-volume-slider`, … |
| Dock items | `AXURL` (the bundle/folder URL) + `AXTitle` + a meaningful `AXSubrole` |
| NC widgets | `widget-local:com.apple.weather:com.apple.weather.widget:com.apple.weather` |

Two caveats. Module-hosted Control Center controls (Stage Manager, Dark Mode, Capture
Screen) use a composite id ending in a **per-install UUID**, so those are not portable
(`mac-06`). And third-party status items carry no useful id at the menu-bar-item level —
Arq's menu items fall back to nib ids (`_NS:18`, `_NS:21`), which are build artifacts.

Dock subroles are the cleanest kind tag on any platform:
`AXApplicationDockItem` / `AXFolderDockItem` / `AXTrashDockItem` / `AXSeparatorDockItem`.

### 4.3 Owning pid is always right

Every status item, dock item and menu extra reports the pid of the app that owns it.
Windows reports `explorer.exe` for everything; Linux gets it right for XEmbed and not for
StatusNotifierItems. macOS is the only platform where per-item ownership is unconditionally
available — the AX element *is* the owning process's element.

### 4.4 Enumeration is mostly non-mutating — with one exception

This is the sharpest contrast with Windows, where hidden tray icons do not exist as
elements until the chevron is pressed.

**NSMenu-backed status items expose their whole menu while closed.** Arq's and codex's
complete menus — titles, `AXPress`/`AXPick`, submenus — are readable with the menu shut,
parked at frame `[0,1243 0x0]` (`mac-02`). No click needed.

**Control Center is the exception.** Closed, the process has one child (the menu-extra
bar), no `AXWindow`, and each menu extra has zero children (`mac-05`). Its contents do not
exist until it is opened. So "enumerate the status items" is read-only on macOS, but
"enumerate what is *inside* Control Center" is not.

> **Design consequence.** Same conclusion as Windows §2.3, reached from a different
> direction: whether a shell enumeration mutates is a property of the *individual surface*,
> not of the platform. An API that documents "dump is read-only" per-platform will be wrong
> on macOS in one direction and on Windows in the other.

### 4.5 Actions: no false successes, but the result lands somewhere surprising

Windows produced three measured false successes (§6.4). macOS produced none.

- **`AXShowMenu` on a Dock item genuinely works** (`mac-07`). Success *and* a real,
  fully accessible menu. `AXShownMenuUIElement` is nil before and present after, so there
  is a **verifiable post-condition** — exactly what Windows' `ShowContextMenu` lacks.
  The menu is hosted in a *different process* (`com.apple.dock.helper`, pid 45063, not
  `com.apple.dock`, pid 1223), and the cross-process hop is transparent to a tree walk.
- **`AXPress` on the Control Center menu extra genuinely opens it** (`mac-12`, `mac-06`) —
  but the pressed element's child count is **0 before and 0 after**. What appears is a new
  `AXWindow subrole=AXSystemDialog` on the *application*, a sibling of the menu bar, not
  reachable via `AXShownMenuUIElement`.
- **Unsupported actions fail honestly.** `AXPress` on an element with `actions=[]` returns
  `-25200` (`kAXErrorFailure`); on the `AXApplication` element, `-25206`
  (`kAXErrorActionUnsupported`).

> **Design consequence.** The naive post-verify — "re-read the target's subtree and check
> something appeared" — reports the Control Center press as a no-op. Post-verification has
> to be scoped to the owning *application*, not the pressed element.

One wart: Control Center's action list is not a clean enum. Alongside `AXPress` and
`AXShowMenu`, `AXUIElementCopyActionNames` returns a literal three-line string
`Name:show details / Target:0x0 / Selector:(null)` — an ObjC custom-action description
leaking through (`mac-06`). Same shape of problem as Windows' flattened multi-line tray
tooltips, in a different field.

### 4.6 Permissions split along a different seam than expected

The known claim was that on macOS 26+ without Screen & System Audio Recording, the AX API
exposes only menu bars (`README.md:72`). The measurement refines it: **Accessibility trust
alone was enough for every tree in this report** — Dock, Control Center, Notification
Center, the Finder desktop, all status items. Screen Recording gates
`CGWindowListCopyWindowInfo`, and therefore `list_gui_apps()` — i.e. it gates *naming an
app*, not *reading its tree*. Those are two different permissions guarding two different
stages, and a surface reachable by pid can be unreachable by name.

### 4.7 Odds and ends

- **Hit-testing works everywhere** (`mac-08`). `AXUIElementCopyElementAtPosition` returns
  the right element for the desktop, a menu extra, and a dock item, and every `AXParent`
  chain terminates at an `AXApplication`, so a point maps cleanly to (surface, process).
  It respects z-order: a window over a desktop icon wins.
- **`SystemUIServer` and `WallpaperAgent` are empty** (`mac-10`) — `AXApplication` with
  zero children. Same present-but-empty shape as the Win11 legacy taskbar regions (§2.2),
  and the same clean era discriminator.
- **`WindowManager` has verbs but no elements** — zero children, but the application
  element itself carries `AXShowDesktop` and `AXHideDesktop`.
- **Desktop widgets persist in the tree** (`mac-11`). Notification Center holds an
  `AXWindow "Forecast"` while NC is closed, with a stable widget id and `AXShowMenu`. Its
  content is exposed only as flattened `AXDescription` strings on `AXUnknown` nodes — no
  roles, no values. Widgets are visible but not really inspectable.
- **There is no system-owned menu bar.** Each app vends its own copy of the Apple menu;
  22 of 67 processes had a live `AXMenuBar`. "The menu bar" is per-application, which is
  why a single `system_menu_bar()` does not fit even the platform it was named for.


## 5. Cross-platform comparison

| | Windows 11 | Linux (xfce4/AT-SPI) | macOS 26 |
|---|---|---|---|
| Reachable today by xa11y | ✗ (root filter drops Panes) | **✓ already** | partly — desktop/Dock **✓ already**; menu bar filtered at `ax.rs:1759`; status-item-only apps unnameable |
| Shell surface is… | ≥6 separate top-level windows | frames with `window-type:dock` | N application processes, each with its own `AXExtrasMenuBar` / tree |
| Discriminator | class name + owning process | `window-type:dock` attribute | `AXSubrole` (`AXMenuExtra`, `AXApplicationDockItem`, …) + bundle id |
| Per-icon owner pid | **✗** (all explorer) | ✓ XEmbed / ✗ SNI | **✓ always** |
| Stable per-icon id | ✗ (all `aid=SystemTrayIcon`) | ✗ (SNI is anonymous) | **✓ Apple items** (`com.apple.menuextra.*`); ✗ third-party (nib ids) |
| visible vs overflow | ✓ `SystemTrayIcon` vs `NotifyItemIcon` | ✓ (hidden-items toggle exists) | n/a — no overflow on this display |
| Enumerating hidden icons | **requires opening the flyout** | (untested) | **not needed** for NSMenu items; **required** for Control Center contents |
| Activate an icon | ✓ `Invoke` | ✓ SNI only | ✓ `AXPress`, and it really acts |
| Icon context menu | ✗ (`ShowContextMenu` returns S_OK, no-ops) | ✗ (dbusmenu, not AT-SPI) | **✓ `AXShowMenu` works**, menu hosted cross-process |
| Shell context menu elsewhere | ✓ Win32 desktop, fully accessible | n/a | ✓ desktop + every Dock item |
| False successes measured | **3** | 0 | **0** |
| Desktop | ✓ Progman/SysListView32 | n/a | ✓ Finder `AXScrollArea desc="desktop"` (in `AXChildren`, not `AXWindows`) |
| Hit-test to element | (untested) | (untested) | ✓ every surface, z-order respected |

---

## 6. What the data suggests about the abstraction

Framed as observations and questions, not a design.

1. **A single `system_menu_bar() -> Element` does not match the measured shape — and macOS
   is now the strongest evidence against it, not for it.** macOS does not have "one menu
   bar" either: the menu bar is *per application* (22 of 67 processes had one), status items
   fan out over N processes, and the Dock, desktop and Control Center are three more
   unrelated surfaces in three more processes. Windows has a taskbar, a tray, a desktop and
   3+ transient flyouts as unrelated siblings; Linux has N dock frames across N panel
   processes. A collection with a kind tag (`taskbar` / `tray` / `menubar` / `dock` /
   `desktop` / `flyout` / `notifications`) fits all three; a synthetic single root fits none
   of them. The name too: there is no "menu bar" on Windows or Linux, and on macOS it names
   the one surface that is least shell-owned.

2. **The Windows work is mostly a *filter*, not a walk.** Keep root children that are not
   ordinary app windows and are owned by shell processes. Linux is a filter on
   `window-type:dock`. That is a much smaller surface than a dual-discovery region walk — the
   region walk is only needed for Win10, and §2.2 shows the Win11 legacy regions are
   present-but-empty, which is a clean, detectable discriminator between the two eras.

   macOS was assumed to be "delete three lines of child filtering". Measured, it is that
   *plus* a change to app discovery: `list_gui_apps()` is built on
   `CGWindowListCopyWindowInfo`, and a process that owns a status item but no window is
   absent from it (§1, `mac-09`). Deleting the filter alone would expose menu bars for apps
   xa11y can already name, and still leave `LSUIElement` status-item apps unreachable.

3. **Enumeration has side effects, and the API should say so — per surface, not per
   platform.** Hidden tray icons on Windows do not exist as elements until the chevron is
   pressed. Either `tree`/`dump` of the tray is documented as returning only the visible row,
   or there is an explicit "open overflow" step. Silently pressing the chevron during a
   `dump` would surprise anyone.

   macOS splits the same way *within one platform*: NSMenu-backed status items expose their
   entire menu while closed, while Control Center's contents do not exist until it is opened
   (§4.4). So "is dump read-only here?" is a property of the surface. Whatever the kind tag
   ends up being, it is the natural place to carry that bit.

4. **`press` needs a stronger contract here than it does for apps — but the problem is
   Windows-shaped, not universal.** Measured on Windows: `Toggle` on the Start button returns
   success and flips `ToggleState` without acting; `DoDefaultAction` on a taskbar app button
   returns `S_OK` without launching; `ShowContextMenu` returns `S_OK` without showing. Shell
   chrome returns success far more freely than app widgets do. Options worth weighing:
   (a) don't advertise the verb where it can't be verified, (b) post-verify (window appeared /
   toggle state settled) and error otherwise, (c) advertise it and document the lie. Tenet 1
   points hard at (a) or (b).

   macOS produced **zero** false successes across the same probes (§4.5): `AXShowMenu` really
   shows, `AXPress` really presses, unsupported actions return `-25200` / `-25206`. So (a)
   would strip a verb that works on two platforms to route around one. That argues for (b),
   with one measured caveat: on macOS the Control Center press lands as a new window on the
   *application*, not under the pressed element, so post-verification scoped to the target's
   subtree gives a false negative. Verify at application scope.

5. **`pid` is per-protocol, not per-OS.** Windows: never. Linux: yes for XEmbed, no for SNI.
   macOS: always, unconditionally — the element belongs to the owning process (§4.3). A flat
   "reported on macOS, omitted on Windows" rule happens to be right at the endpoints and
   still under-describes Linux, where it depends on which tray protocol the icon used.

6. **Identity needs something better than `Name`.** Windows tray names are flattened
   multi-line tooltips carrying live state and embedded LTR marks; Linux SNI items have no name
   at all. Whatever selector story ships should not be "match on name" by default. Some
   surfaces are much better behaved (`Microsoft.QuickAction.*`, `Appid: <AUMID>`,
   `ListViewItem-N`) and those aids should be surfaced.

   macOS shows what "good" looks like and where it stops: Apple menu extras have stable
   reverse-DNS identifiers, Dock items have `AXURL`, NC widgets have composite widget ids —
   but third-party status items fall back to nib ids (`_NS:18`), and some Control Center
   controls embed a per-install UUID (§4.2). So even the best platform needs the selector
   story to degrade gracefully; an id-only selector would work for Apple's surfaces and fail
   on exactly the third-party ones users care about automating.

7. **Liveness/staleness dominates.** Surfaces appear in and disappear from the root; some
   persist as hidden hosts with stale bounds (`ControlCenterWindow`); names change with state
   (`Windows Shell Experience Host` ↔ `Notification Center`); tooltips materialise as sibling
   subtrees. Auto-wait and element-staleness semantics will be exercised much harder than by
   app trees.

8. **Testability is a first-class constraint.** In a disconnected/headless session —
   i.e. CI — `GetForegroundWindow()` is `NULL`, `SendInput` is denied, and cross-process shell
   surfaces do not open. Tray overflow, Quick Settings, Notification Center and Win32 context
   menus *do*. That split defines what can be asserted in automated tests versus what needs an
   attended machine.

   The macOS run was attended, so it establishes no such split — and the parts most worth
   testing are the least deterministic: which processes own status items is whatever the
   machine happens to run. The stable, assertable facts are the Apple-owned ones (Dock
   subroles, `com.apple.menuextra.*` identifiers, the Finder desktop scroll area,
   SystemUIServer being empty). Anything asserting on third-party status items will be
   asserting on the runner's software inventory.

---

## 7. Files

```
design/shell-surfaces/
  README.md                                  this document
  evidence/win-01..05-*.txt                  UIA root children, taskbar (raw + control view),
                                             desktop/Progman, all top-level HWNDs
  evidence/win-06,07-tray-overflow-*.txt     overflow flyout open vs closed
  evidence/win-08-quick-settings-open.txt
  evidence/win-09-notification-center-open.txt
  evidence/win-10-showcontextmenu.txt        the S_OK-but-no-popup measurement
  evidence/win-11-start-toggle-false-success.txt
                                             Start Toggle: state flips, menu never opens, restored
  evidence/linux-01,02-*.txt                 AT-SPI panel + dual-protocol tray dumps
  evidence/mac-01-apps-menubar-inventory.txt per-process AXMenuBar / AXExtrasMenuBar inventory
  evidence/mac-02-extras-status-items.txt    all four status-item owners, menus included
  evidence/mac-03-dock.txt                   Dock: subroles, AXURL, AXShowMenu/AXShowExpose
  evidence/mac-04-finder-desktop.txt         the desktop is an AXScrollArea in AXChildren
  evidence/mac-05,06-controlcenter-*.txt     closed vs open — the mutating-enumeration pair
  evidence/mac-07-dock-showmenu.txt          AXShowMenu works; menu hosted cross-process
  evidence/mac-08-hittest.txt                AXUIElementCopyElementAtPosition on each surface
  evidence/mac-09-cgwindow-owners.txt        list_gui_apps() basis; the status-item-app gap
  evidence/mac-10-empty-legacy-hosts.txt     SystemUIServer/WallpaperAgent empty; WindowManager
  evidence/mac-11-notification-center.txt    persistent desktop widget + a full Apple menu
  evidence/mac-12-press-results.txt          honest errors; press lands outside the target
  probes/windows/                            Rust UIA probe (windows-rs 0.62); excluded from the
                                             cargo workspace in the root Cargo.toml
  probes/linux/                              Dockerfile + AT-SPI dumper + dual-protocol tray app
  probes/macos/shell-probe.swift             AX probe — run; produced every mac-*.txt above
```

Four commands were added to `shell-probe.swift` while running it, because the questions in
§4.5–4.7 could not be answered without them: `showmenu` (AXShowMenu + dump
`AXShownMenuUIElement`), `hittest` (system-wide hit test + ancestry), `cgwindows` (mirrors
`list_gui_apps()`), and `dismiss` (Escape, to close a flyout a probe opened). `press` now
dumps the target subtree *before* acting as well as after — the before/after child counts in
`mac-12` are the measurement. Element lookup also gained an `id:<AXIdentifier>` form and no
longer matches the `AXApplication` root by title, which it previously did: the first attempt
at `press com.apple.controlcenter "Control Center"` hit the *process* rather than the menu
extra, and returned a perfectly honest `-25206` for the wrong element.

Machine-identifying strings in `evidence/` are redacted. On Windows: the Wi-Fi SSID appears as
`<SSID>`, the user's home path as `C:\Users\<user>`, and one personal desktop file as
`<redacted desktop item>`. On macOS: the Wi-Fi SSID as `<SSID>`, the weather widget's location
and readings as `<city>` / `<temp>` / `<condition>`, the account name as `<user>`, per-install
Control Center UUIDs as `<uuid>`, one terminal window title, and every user file and folder
name — desktop icons, Finder window titles, Dock recent items and the Apple menu's Recent
Items — as `<file-N>` / `<folder-N>`, numbered consistently across all files so the same item
keeps the same placeholder. Application and bundle identifiers are **not** redacted: the
finding in §1 depends on a real `LSUIElement` status-item app being nameable and checkable.
Roles, subroles, identifiers, actions, attributes, frames and counts are untouched.

Nothing else was altered.

Three corrections worth recording, all caught by re-checking rather than by the first result:
the initial Windows pattern-availability table used guessed property IDs and mislabelled every
pattern (the real IDs are alphabetically ordered from 30027, not grouped); the first
`ShowContextMenu` conclusion ("no-op everywhere") was wrong because the check grepped for the
Win32 menu class `#32768` — the Win11 shell menu is a `PopupWindowSiteBridge`; and the macOS
menu-bar filter was cited as `ax.rs:1605-1607` when it is at 1759-1761. All three are fixed
above; all figures in this report come from the corrected runs in `evidence/`.

One prediction in the pre-measurement draft of §4 was also wrong in a way worth keeping: it
framed macOS as the platform needing the least work ("deleting three lines of child
filtering"). The tree side was right. The app-discovery side — that a status-item-only app is
absent from `CGWindowListCopyWindowInfo` and therefore unnameable — was not anticipated, and
it is the larger of the two gaps.
