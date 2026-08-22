# System Status Area and Menu Bars: API Shape Proposal

Proposal for [#374](https://github.com/xa11y/xa11y/issues/374) — reaching the
macOS system menu bar / menu bar extras and the Windows notification area
("tray") through the same tree, selector, and action machinery as app trees.

Status: **proposal**. Nothing here is implemented. The requester's own note
applies — a prototype should confirm the platform facts before the shape is
locked — so every claim that a prototype must verify is marked
**[verify]**, and the checklist at the end collects them.

## 1. The request is three surfaces, not one

The issue asks for one primitive (`system_menu_bar()`) returning one synthetic
root. Reading it against what the platforms actually own, it is three
surfaces with three different ownership models:

| # | Surface | Owner | Exists on |
|---|---|---|---|
| A | An application's own menu bar (File, Edit, View…) | the application process | macOS (`AXMenuBar`), Windows and Linux (in-window menu bars) |
| B | The system status area — macOS menu bar extras, Windows notification-area icons | many processes (macOS) / the shell (Windows) | macOS, Windows |
| C | The popup a menu bar item or status item opens | the owning app (macOS), a transient top-level window (Windows) | all three |

They want different API shapes because they have different roots. Folding
them into one object is where the issue's design proposal and this one
diverge; §5 argues the case.

## 2. What already works, and where the holes are

**A — app menu bars.** On Windows and Linux a menu bar is an ordinary node in
the app tree: `app.locator("menu_bar > menu_item[name=\"File\"]")` resolves
today, and `xa11y/tests/integ/tree.rs::role_menu_bar` covers it. On macOS it
does not, because the provider deliberately drops it:

```rust
// xa11y-macos/src/ax.rs:1759
if parent_role == Role::Application && child_role == "AXMenuBar" {
    return true;   // filtered out of get_children
}
```

The filter is defensible — every full-tree walk would otherwise pay for every
app's entire menu hierarchy, and menus are large — but it is currently a
silent hole: nothing in the API says the menu bar exists and is excluded.
That is the tenet-1 shape of the bug. The fix is an explicit accessor, not
deleting the filter (§4.1).

**B — status area.** Nothing addresses it, but less is missing than it looks:

- Windows: the taskbar is a top-level `Window` with a non-empty name owned by
  `explorer.exe`, so it already passes the `list_apps` filter in
  `xa11y-windows/src/uia.rs:737-793` and is presumably reachable as
  `App::by_name("Taskbar")` **[verify]**. What is missing is a name that is
  not a localized window title, a normalized notion of *which* tray region an
  icon sits in, and a loud failure when the shell's tree shape is not one we
  recognize.
- macOS: `list_apps` enumerates through `CGWindowListCopyWindowInfo`
  (`xa11y-macos/src/ax.rs:1312`), so whether a menu-bar-only agent app (an
  `LSUIElement` with no ordinary window) appears at all is uncertain
  **[verify]**. `AXMenuBarExtra` is already mapped — to `Role::MenuBar`
  (`ax.rs:1025`), which §4.3 argues is the wrong normalization.

**C — popups.** On Windows a classic tray context menu is an unnamed
top-level `#32768` window, and `list_apps` skips unnamed windows
(`uia.rs:776`), so it is invisible. On macOS the open menu hangs off the item
that opened it and needs no new primitive **[verify]**.

## 3. Constraints this shape has to satisfy

From `AGENTS.md` and `design/README.md`, the ones that actually bind here:

1. **No silent fallbacks** (tenet 1). An unrecognized Windows tray layout
   fails with a diagnosis. It never returns an empty list, which reads
   identically to "you have no tray icons".
2. **Only expose what accessibility APIs support** (tenet 2). Right-clicking
   a tray icon has no accessibility interface. It stays out of `actions`, and
   the documented answer is an explicit `InputSim` composition.
3. **Action fidelity** (tenet 3). `press` on an icon or a chevron is the
   platform's own Invoke / AXPress. If we cannot invoke it, we do not
   advertise it.
4. **Errors carry their own diagnosis** (tenet 6). "No status items" and "the
   shell tree looked unfamiliar" are different answers and must be
   distinguishable without re-running under logging.
5. **Don't add value where there is none** (`design/README.md` tenet 3). On
   Windows and Linux, `app.locator("menu_bar")` already works; a new API for
   surface A has to earn its place on macOS alone.
6. **Public API extensibility.** A new `Provider` method is a per-platform
   decision, so it is **required**, not defaulted — the same reasoning
   `Provider::focused_app` documents. Linux writes an explicit
   `Err(Unsupported)` rather than inheriting silence.

## 4. Proposed API

### 4.1 Surface A — `App::menu_bar()`

```rust
// xa11y-core/src/provider.rs
trait Provider {
    /// The application's menu bar, if it has one.
    ///
    /// macOS reads the app element's `AXMenuBar` attribute, which
    /// `get_children` deliberately filters out; Windows and Linux locate the
    /// in-tree menu bar node. Returns `Error::SelectorNotMatched` when the
    /// application has no menu bar — a normal state, not a failure.
    fn menu_bar(&self, app: &ElementData) -> Result<ElementData>;
}

// xa11y-core/src/app.rs
impl App {
    pub fn menu_bar(&self) -> Result<Element>;
}
```

Why a method rather than deleting the macOS filter: keeping the filter keeps
every rootless selector search and every `tree()` cheap, and menu hierarchies
are the single largest subtree most macOS apps expose. The accessor makes the
exclusion explicit and reachable instead of silent. `platform-details.mdx`
gains a line saying so, since the same selector then behaves differently per
platform, which is exactly the kind of divergence that page exists for.

```python
mb = app.menu_bar()
mb.locator('menu_item[name="File"]').press()
mb.locator('menu_item[name="File"] menu_item[name="Save As…"]').press()
```

### 4.2 Prerequisite — `Element::locator()`

The snippet above does not compile today: `Element` has no `locator()`, in
core or in either binding. Every "here's a root element" API needs it —
including the issue's own proposal, which hands back an `Element` and assumes
selectors work against it.

```rust
impl Element {
    /// A Locator scoped to this element's subtree.
    pub fn locator(&self, selector: &str) -> Locator {
        Locator::new(self.provider().clone(), Some(self.data().clone()), selector)
    }
}
```

Three lines in core, one method in each binding, one member each in the
`Element` parity entries. It is worth landing on its own merits regardless of
what happens to the rest of this proposal.

### 4.3 Surface B — `status_items()`

```rust
// xa11y-core/src/provider.rs
trait Provider {
    /// Items in the system status area, in left-to-right screen order.
    ///
    /// macOS: `AXMenuBarExtra` items. Windows: notification-area icons plus
    /// the overflow toggle. Linux: `Error::Unsupported`.
    fn status_items(&self) -> Result<Vec<ElementData>>;
}

// xa11y/src/lib.rs — singleton entry point, alongside screenshot() / input_sim()
pub fn status_items() -> Result<Vec<Element>>;
```

Each entry is a **real platform element**, not a synthesized one: a live UIA
button or `AXMenuBarExtra` with a working handle, real `bounds`, real
`actions`, and a `parent()` that walks back into the tree it actually came
from.

**Role.** Add `Role::StatusItem` (`Role` is `#[non_exhaustive]`; roles need no
`variant_coverage` entry). Both platforms have exactly this concept, which is
the "abstract where platforms agree" case. This **changes** the existing
macOS mapping: `AXMenuBarExtra` moves from `Role::MenuBar` to
`Role::StatusItem`, so `platform-details.mdx`'s role table and any selector
relying on the old mapping change with it. Windows tray icons are UIA buttons
and would otherwise normalize to `Role::Button`, indistinguishable from every
other button on screen.

**Normalized attributes go in `raw`.** `matches_simple` falls back to the
`raw` map for any non-normalized attribute name
(`xa11y-core/src/selector.rs:621`), so selectors work without a new
`ElementData` field — and a new field would force all three providers to
write `None` on every element in every tree for something meaningful on a
handful of nodes:

| Key | Values | Set by |
|---|---|---|
| `status_area` | `"visible"` \| `"overflow"` | Windows. **Omitted** on macOS, which does not report whether an extra is hidden by a crowded menu bar. Absent means "the platform did not say", never "visible". |
| `status_kind` | `"icon"` \| `"overflow_toggle"` | both |
| `status_host` | hosting process image name, e.g. `"explorer.exe"` | both |

```bash
xa11y find 'status_item[status_area="overflow"]' --status
xa11y find 'status_item[name*="Slack"]' --status
```

**Attribution.** `pid` reports the process that **hosts** the element, which
is what `pid` means everywhere else in xa11y: the owning app on macOS,
`explorer.exe` on Windows. This deviates from the issue, which proposes
omitting `pid` on Windows. Omitting it would make the field mean "host,
except sometimes owner, except sometimes nothing"; reporting the host keeps
one meaning and leaves the genuinely unavailable thing — the icon's *owning*
application, which lives in an undocumented Shell protocol — simply absent,
with `platform-details.mdx` saying so.

**Ordering** is left-to-right by `bounds.x`, and is part of the contract, so
`status_items()[0]` is stable across calls rather than dependent on
enumeration order.

**The overflow flyout.** The chevron is a real button, so it is returned as
an item with `status_kind = "overflow_toggle"` and pressed with `press()` — a
genuine Invoke, no simulated verb. Contract for what enumeration returns:

> `status_items()` reflects what the shell currently realizes. On Windows 11
> the icons behind a closed overflow flyout are not in the UIA tree at all;
> press the `overflow_toggle` item, then enumerate again, and they appear
> with `status_area = "overflow"`. **[verify]**

**Linux.**

```rust
Err(Error::Unsupported {
    feature: "status_items: Linux tray icons use the StatusNotifierItem D-Bus \
              protocol, which is a separate subsystem from the AT-SPI protocol \
              xa11y reads. The desktop shell's own panel is an ordinary \
              application — try App::by_name(\"gnome-shell\")."
})
```

Written explicitly in `xa11y-linux`, not inherited from a trait default, so a
future backend cannot forget to answer.

**Unknown Windows layouts.** The UIA tray tree is version-dependent and not a
stable contract. When the discovery walk finds neither the Win7–10 named
regions nor the Win11 XAML taskbar, the call fails rather than returning
`[]`:

```rust
Err(Error::Platform { .. }.diagnose(
    Diagnosis::new()
        .condition("notification-area container in the shell tree")
        .last_observed("taskbar found, no recognized tray container beneath it")
        .scope(bounded_dump_of_taskbar_subtree)))
```

The `scope` dump is what makes an unfamiliar Windows build a bug report
someone can act on instead of a shrug.

### 4.4 Surface C — popups (deferred to phase 3)

Not part of the first cut. The shape, when it lands, should be
`xa11y::popups() -> Result<Vec<Element>>` — currently-open transient
top-level windows — because the same gap swallows every right-click context
menu on Windows, not just tray menus. Bundling it here would grow this change
without making the status area work any better, and on macOS the menu is
already a child of the item that opened it **[verify]**.

Until then, the honest documented answer for a Windows tray context menu is
the `InputSim` composition — never a `show_menu` we cannot really perform:

```python
item = next(i for i in xa11y.status_items() if "Dropbox" in (i.name or ""))
sim = xa11y.input_sim()
sim.right_click(item)   # an Element target resolves to its center; no
                        # accessibility interface exists for this gesture
```

## 5. Why not one synthetic root

The issue proposes `system_menu_bar() -> Element`: one synthetic `MenuBar`
root whose children are the tray icons, the chevron, the flyout, and any
desktop popup. Its payoff is real and worth stating plainly — everything
downstream (locators, auto-wait, `tree`, `dump`, MCP, CLI, both bindings)
would work unchanged, with no new plumbing anywhere.

The costs:

- **The root is not a platform object.** `get_parent` on its children returns
  their real platform parent, so walking down and walking back up disagree.
  `bounds`, `pid`, and `stable_id` are meaningless on the root.
- **Every provider must special-case a synthetic handle** in `get_children`,
  `get_parent`, and the native `find_elements_group` overrides — the
  fast-path walks in `uia.rs` and `ax.rs` take a real platform element. That
  is the same synthesis written three times, in the three files that are
  hardest to test.
- **It merges surfaces with different ownership.** The frontmost app's menu
  bar under the same root as tray icons owned by other processes means one
  subtree whose `pid` changes meaning halfway down.
- **It invents structure**, which `design/README.md` tenet 2 argues against:
  prefer platform-specific escape hatches to a shape the platform does not
  have.

If the rooted ergonomics turn out to matter more than the honesty — a
reasonable call, especially for MCP consumers — the synthesis belongs in
**`xa11y-core`, once**, not in three backends: generalize `Locator`'s root
from `Option<ElementData>` to a multi-root scope. `Locator::resolve_group`
already implements exactly that for the rootless case, enumerating apps and
merging per-app matches
(`xa11y-core/src/locator.rs:259-325`); pointing the same loop at
`status_items()` instead of `list_apps()` is a small change in one file, and
providers keep returning only real elements. That is the recommended
fallback position if `Vec<Element>` proves too thin in practice.

## 6. Surfaces

### CLI

```
xa11y status                        # list status items, one per line, like `apps`
xa11y tree   --status               # one tree per status item
xa11y find   'menu_item' --status
xa11y action --status --selector 'status_item[name*="Slack"]' --action press
xa11y tree   --app Safari --menu-bar
```

`--status` and `--menu-bar` are new targets alongside `--app` / `--pid`, so
`resolve_app` (`xa11y/src/cli.rs:445`) becomes `resolve_roots(&opts) ->
CliResult<Vec<Element>>`: one root for `--app` / `--pid` / `--menu-bar`, N for
`--status`. `tree` prints each root in turn; `find` merges matches in root
order; `action` keeps its existing first-match semantics, which its reference
page already documents.

### MCP

One new tool and two new arguments, mirroring the existing
`apps` → `tree` / `find` / `action` shape:

- `status` — "List system status-area items: macOS menu bar extras, Windows
  notification-area (tray) icons. Each reports `bounds`, `center`, the
  actions the shell advertises, and which tray region it sits in." Bounded
  and truncation-reporting like every other tool result.
- `status: boolean` on `tree` / `find` / `action` — target the status area
  instead of an application.
- `menu_bar: boolean` on `tree` / `find` / `action` — with `app` / `pid`,
  target that application's menu bar.

The `action` tool's exactly-one-match contract applies unchanged, which means
the ambiguity check has to count across all roots, not per root. Descriptions
must state the overflow contract from §4.3 — an agent that cannot see the
hidden icons and is not told to press the chevron will conclude they do not
exist.

### Bindings

| Core | Python | JS |
|---|---|---|
| `App::menu_bar` | `app.menu_bar()` | `app.menuBar()` |
| `Element::locator` | `element.locator(sel)` | `element.locator(sel)` |
| `xa11y::status_items` | `xa11y.status_items()` | `statusItems()` |

All three reach an OS call, so all three go inside `py.allow_threads` with
parsing done first (tenet 5). `status_items` is an umbrella-crate free
function like `screenshot()` / `input_sim()`, so it sits outside the parity
check's type-based rules; `App` and `Element` are `mirrored`, so their new
members are enforced in both bindings on the next
`cargo xtask check-bindings-parity`. `index.d.ts` needs the `App`/`Element`
methods added by hand — the generated `native.d.ts` declaration reaches
nobody (`AGENTS.md`, "Type Declarations").

`strands-xa11y` reads xa11y's Python surface by string; adding members breaks
nothing there, but `check_real_surface.py` is the guard that would catch it
if the `Element` shape shifted.

### Docs

- `reference/platform-details.mdx` — the role-table change for
  `AXMenuBarExtra`, the macOS menu-bar exclusion and its accessor, the
  Windows owner-attribution gap, the `status_*` raw keys.
- `guides/` — a short how-to for driving a status item end to end, including
  the right-click composition and why it is not an action.
- `reference/errors.mdx` — the Linux `Unsupported` text and the unknown-layout
  diagnosis.
- `reference/cli.mdx` and `guides/mcp.mdx` — the new target flags and tool.

## 7. Tests

Integration coverage is the project's bar, and this is the part with no easy
answer: the AccessKit test app cannot host a tray icon or a macOS menu bar
extra, so `cargo xtask test-integ` cannot cover surface B as it stands.
Options, cheapest first:

1. **macOS menu bar (A)** — covered today with no new fixture: every app has
   an `AXMenuBar`, including the existing test app. An integ test asserting
   `app.menu_bar()` resolves and contains menu items is straightforward.
2. **Windows status area (B)** — a new tiny test app that registers a
   `Shell_NotifyIcon` tray icon, run in the `windows-latest` integ cells. This
   is the only way to get a deterministic, named icon on a CI runner.
3. **macOS status area (B)** — a test app that publishes an `NSStatusItem`.
   Same shape as (2) on the `macos-latest` cells.
4. **Linux** — a unit test asserting `Unsupported` with the pointer to the
   shell app in the message.

(2) and (3) are new test apps in `test-apps/`, which is a real chunk of the
work and should be scoped as such rather than discovered late.

## 8. Phasing

| Phase | Content | Why this order |
|---|---|---|
| 1 | `Element::locator()` | Independently useful, unblocks everything else, no platform work. |
| 2 | Surface A: `Provider::menu_bar`, `App::menu_bar`, bindings, CLI `--menu-bar`, docs | Closes the macOS hole; testable on existing fixtures. |
| 3 | Surface B: `Role::StatusItem`, `Provider::status_items`, `xa11y::status_items`, `raw` keys, CLI `--status` / `xa11y status`, MCP `status`, both test apps | The bulk. Depends on the prototype answers below. |
| 4 | Surface C: `xa11y::popups()` | Separate problem, separate value (context menus everywhere). |

## 9. What the prototype has to answer before this is locked

Every **[verify]** above, collected:

1. **Windows** — is the taskbar already reachable as `App::by_name("Taskbar")`
   with the tray icons as descendants? If yes, how much of surface B is
   naming and normalization rather than new discovery?
2. **Windows** — are overflow icons truly absent from the UIA tree while the
   flyout is closed, on both the Win10 named-region layout and the Win11 XAML
   taskbar? This decides whether §4.3's contract is the real one.
3. **Windows** — what does `Invoke` on a tray icon actually do (left-click,
   nothing, or something app-defined), and does the chevron support `Invoke`
   or only `ExpandCollapse`? Tenet 3 rides on this.
4. **macOS** — do menu-bar-only agent apps (`LSUIElement`, no ordinary
   window) surface through `CGWindowListCopyWindowInfo`, and therefore
   through `list_apps`?
5. **macOS** — are status items reachable per-owning-process, through
   `SystemUIServer`, or both, and does `AXPress` on an `AXMenuBarExtra` open
   its menu?
6. **macOS** — when a menu opens, is it a child of the item that opened it,
   or a separate top-level element? This decides whether phase 4 is needed on
   macOS at all.
7. **Both** — how large is a real menu bar subtree in node count? If it is
   small, deleting the macOS filter beats §4.1's accessor and the API gets
   simpler.

Answers to 1, 2, and 7 could each simplify this proposal. Answer 7 could
delete a third of it.
