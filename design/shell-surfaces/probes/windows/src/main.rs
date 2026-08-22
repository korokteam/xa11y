// Shell-surface accessibility probe: dumps the UIA tree for OS-owned shell UI
// (taskbar, tray, flyouts, desktop) with the detail xa11y's ElementData drops.
use std::collections::HashMap;
use windows::core::*;
use windows::Win32::Foundation::*;
use windows::Win32::System::Com::*;
use windows::Win32::System::Threading::*;
use windows::Win32::UI::Accessibility::*;
use windows::Win32::UI::HiDpi::*;
use windows::Win32::UI::WindowsAndMessaging::*;

fn ctl_name(id: i32) -> &'static str {
    match id {
        50000 => "Button",
        50001 => "Calendar",
        50002 => "CheckBox",
        50003 => "ComboBox",
        50004 => "Edit",
        50005 => "Hyperlink",
        50006 => "Image",
        50007 => "ListItem",
        50008 => "List",
        50009 => "Menu",
        50010 => "MenuBar",
        50011 => "MenuItem",
        50012 => "ProgressBar",
        50013 => "RadioButton",
        50014 => "ScrollBar",
        50015 => "Slider",
        50016 => "Spinner",
        50017 => "StatusBar",
        50018 => "Tab",
        50019 => "TabItem",
        50020 => "Text",
        50021 => "ToolBar",
        50022 => "ToolTip",
        50023 => "Tree",
        50024 => "TreeItem",
        50025 => "Custom",
        50026 => "Group",
        50027 => "Thumb",
        50028 => "DataGrid",
        50029 => "DataItem",
        50030 => "Document",
        50031 => "SplitButton",
        50032 => "Window",
        50033 => "Pane",
        50034 => "Header",
        50035 => "HeaderItem",
        50036 => "Table",
        50037 => "TitleBar",
        50038 => "Separator",
        50039 => "SemanticZoom",
        50040 => "AppBar",
        _ => "?",
    }
}

const PATTERNS: &[(i32, &str)] = &[
    (30027, "Dock"),
    (30028, "ExpandCollapse"),
    (30029, "GridItem"),
    (30030, "Grid"),
    (30031, "Invoke"),
    (30032, "MultipleView"),
    (30033, "RangeValue"),
    (30034, "Scroll"),
    (30035, "ScrollItem"),
    (30036, "SelectionItem"),
    (30037, "Selection"),
    (30038, "Table"),
    (30039, "TableItem"),
    (30040, "Text"),
    (30041, "Toggle"),
    (30042, "Transform"),
    (30043, "Value"),
    (30044, "Window"),
    (30090, "LegacyIAccessible"),
    (30108, "ItemContainer"),
    (30109, "VirtualizedItem"),
    (30110, "SynchronizedInput"),
    (30112, "ObjectModel"),
    (30118, "Annotation"),
    (30127, "Styles"),
    (30128, "Spreadsheet"),
    (30132, "SpreadsheetItem"),
    (30136, "TextChild"),
    (30137, "Drag"),
    (30141, "DropTarget"),
    (30149, "TextEdit"),
    (30151, "CustomNavigation"),
];

fn proc_name(pid: u32) -> String {
    unsafe {
        let Ok(h) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else {
            return "?".into();
        };
        let mut buf = [0u16; 512];
        let mut n = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(h, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut n);
        let _ = CloseHandle(h);
        if ok.is_err() || n == 0 {
            "?".into()
        } else {
            let full = String::from_utf16_lossy(&buf[..n as usize]);
            full.rsplit('\\').next().unwrap_or(&full).to_string()
        }
    }
}

struct Probe {
    a: IUIAutomation,
    walker: IUIAutomationTreeWalker,
    pids: HashMap<u32, String>,
}

impl Probe {
    fn new(raw: bool) -> Result<Self> {
        unsafe {
            let a: IUIAutomation = CoCreateInstance(&CUIAutomation8, None, CLSCTX_ALL)?;
            let walker = if raw {
                a.RawViewWalker()?
            } else {
                a.ControlViewWalker()?
            };
            Ok(Probe {
                a,
                walker,
                pids: HashMap::new(),
            })
        }
    }

    fn pname(&mut self, pid: u32) -> String {
        self.pids
            .entry(pid)
            .or_insert_with(|| proc_name(pid))
            .clone()
    }

    fn line(&mut self, el: &IUIAutomationElement, depth: usize) -> String {
        unsafe {
            let name = el.CurrentName().map(|s| s.to_string()).unwrap_or_default();
            let class = el
                .CurrentClassName()
                .map(|s| s.to_string())
                .unwrap_or_default();
            let aid = el
                .CurrentAutomationId()
                .map(|s| s.to_string())
                .unwrap_or_default();
            let fw = el
                .CurrentFrameworkId()
                .map(|s| s.to_string())
                .unwrap_or_default();
            let ct = el.CurrentControlType().map(|c| c.0).unwrap_or(0);
            let pid = el.CurrentProcessId().unwrap_or(0) as u32;
            let r = el.CurrentBoundingRectangle().unwrap_or_default();
            let off = el.CurrentIsOffscreen().map(|b| b.as_bool()).unwrap_or(false);
            let kbd = el
                .CurrentIsKeyboardFocusable()
                .map(|b| b.as_bool())
                .unwrap_or(false);
            let mut pats = Vec::new();
            for (id, pname) in PATTERNS {
                if let Ok(v) = el.GetCurrentPropertyValue(UIA_PROPERTY_ID(*id)) {
                    if bool::try_from(&v).unwrap_or(false) {
                        pats.push(*pname);
                    }
                }
            }
            let mut legacy = String::new();
            if let Ok(p) = el.GetCurrentPatternAs::<IUIAutomationLegacyIAccessiblePattern>(
                UIA_LegacyIAccessiblePatternId,
            ) {
                let role = p.CurrentRole().unwrap_or(0);
                let da = p
                    .CurrentDefaultAction()
                    .map(|s| s.to_string())
                    .unwrap_or_default();
                let val = p.CurrentValue().map(|s| s.to_string()).unwrap_or_default();
                let st = p.CurrentState().unwrap_or(0);
                legacy =
                    format!(" legacy{{role={role},state=0x{st:x},action={da:?},value={val:?}}}");
            }
            let mut extra = String::new();
            if pats.contains(&"ExpandCollapse") {
                if let Ok(p) = el.GetCurrentPatternAs::<IUIAutomationExpandCollapsePattern>(
                    UIA_ExpandCollapsePatternId,
                ) {
                    extra += &format!(" exp={:?}", p.CurrentExpandCollapseState().map(|s| s.0));
                }
            }
            if pats.contains(&"Toggle") {
                if let Ok(p) =
                    el.GetCurrentPatternAs::<IUIAutomationTogglePattern>(UIA_TogglePatternId)
                {
                    extra += &format!(" toggle={:?}", p.CurrentToggleState().map(|s| s.0));
                }
            }
            if pats.contains(&"Value") {
                if let Ok(p) =
                    el.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId)
                {
                    let v = p.CurrentValue().map(|s| s.to_string()).unwrap_or_default();
                    if !v.is_empty() {
                        extra += &format!(" value={v:?}");
                    }
                }
            }
            let help = el
                .CurrentHelpText()
                .map(|s| s.to_string())
                .unwrap_or_default();
            if !help.is_empty() {
                extra += &format!(" help={help:?}");
            }
            let pn = self.pname(pid);
            format!(
                "{}{} {:?} class={:?} aid={:?} fw={} pid={}({}) rect=[{},{} {}x{}]{} kbd={} pats=[{}]{}{}",
                "  ".repeat(depth),
                ctl_name(ct),
                name,
                class,
                aid,
                fw,
                pid,
                pn,
                r.left,
                r.top,
                r.right - r.left,
                r.bottom - r.top,
                if off { " OFFSCREEN" } else { "" },
                kbd,
                pats.join(","),
                legacy,
                extra
            )
        }
    }

    fn dump(&mut self, el: &IUIAutomationElement, depth: usize, max: usize, out: &mut Vec<String>) {
        out.push(self.line(el, depth));
        if depth >= max {
            return;
        }
        unsafe {
            let mut child = self.walker.GetFirstChildElement(el).ok();
            let mut count = 0;
            while let Some(c) = child {
                self.dump(&c, depth + 1, max, out);
                count += 1;
                if count > 400 {
                    out.push(format!("{}... (truncated)", "  ".repeat(depth + 1)));
                    break;
                }
                child = self.walker.GetNextSiblingElement(&c).ok();
            }
        }
    }
}

type WinInfo = (HWND, String, String, u32, bool, RECT);

fn hwnds() -> Vec<WinInfo> {
    unsafe extern "system" fn cb(h: HWND, lp: LPARAM) -> BOOL {
        unsafe {
            let v = &mut *(lp.0 as *mut Vec<WinInfo>);
            let mut cls = [0u16; 256];
            let n = GetClassNameW(h, &mut cls);
            let cls = String::from_utf16_lossy(&cls[..n as usize]);
            let mut t = [0u16; 512];
            let n2 = GetWindowTextW(h, &mut t);
            let title = String::from_utf16_lossy(&t[..n2 as usize]);
            let mut pid = 0u32;
            let _ = GetWindowThreadProcessId(h, Some(&mut pid));
            let vis = IsWindowVisible(h).as_bool();
            let mut r = RECT::default();
            let _ = GetWindowRect(h, &mut r);
            v.push((h, cls, title, pid, vis, r));
            true.into()
        }
    }
    let mut v: Vec<WinInfo> = Vec::new();
    unsafe {
        let _ = EnumWindows(Some(cb), LPARAM(&mut v as *mut _ as isize));
    }
    v
}

fn main() -> Result<()> {
    unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        CoInitializeEx(None, COINIT_MULTITHREADED).ok()?;
    }
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cmd = args.first().map(|s| s.as_str()).unwrap_or("help");
    let raw = args.iter().any(|a| a == "--raw");
    let depth: usize = args
        .iter()
        .position(|a| a == "--depth")
        .and_then(|i| args.get(i + 1))
        .and_then(|s| s.parse().ok())
        .unwrap_or(6);

    match cmd {
        "hwnds" => {
            let mut v = hwnds();
            v.sort_by(|a, b| a.1.cmp(&b.1));
            for (h, cls, title, pid, vis, r) in v {
                if !vis && !args.iter().any(|a| a == "--all") {
                    continue;
                }
                println!(
                    "hwnd=0x{:x} vis={} class={:<40} pid={:>6}({:<20}) rect=[{},{} {}x{}] title={:?}",
                    h.0 as usize,
                    vis as u8,
                    cls,
                    pid,
                    proc_name(pid),
                    r.left,
                    r.top,
                    r.right - r.left,
                    r.bottom - r.top,
                    title
                );
            }
        }
        "fg" => unsafe {
            let h = GetForegroundWindow();
            let mut cls = [0u16; 256];
            let n = GetClassNameW(h, &mut cls);
            let mut t = [0u16; 512];
            let n2 = GetWindowTextW(h, &mut t);
            let mut pid = 0u32;
            let _ = GetWindowThreadProcessId(h, Some(&mut pid));
            println!(
                "foreground hwnd=0x{:x} class={} pid={}({}) title={:?}",
                h.0 as usize,
                String::from_utf16_lossy(&cls[..n as usize]),
                pid,
                proc_name(pid),
                String::from_utf16_lossy(&t[..n2 as usize])
            );
        },
        "roots" => {
            let mut p = Probe::new(raw)?;
            let root = unsafe { p.a.GetRootElement()? };
            let mut out = Vec::new();
            p.dump(&root, 0, 1, &mut out);
            for l in out {
                println!("{l}");
            }
        }
        "rootchild" => {
            // rootchild <name-substring> [--depth N] — dump a desktop-root child by name
            let want = args.get(1).cloned().unwrap_or_default();
            let mut p = Probe::new(raw)?;
            let root = unsafe { p.a.GetRootElement()? };
            unsafe {
                let mut child = p.walker.GetFirstChildElement(&root).ok();
                while let Some(c) = child {
                    let name = c.CurrentName().map(|s| s.to_string()).unwrap_or_default();
                    let cls = c.CurrentClassName().map(|s| s.to_string()).unwrap_or_default();
                    if name.to_lowercase().contains(&want.to_lowercase())
                        || cls.to_lowercase().contains(&want.to_lowercase())
                    {
                        let mut out = Vec::new();
                        p.dump(&c, 0, depth, &mut out);
                        for l in out {
                            println!("{l}");
                        }
                        println!();
                    }
                    child = p.walker.GetNextSiblingElement(&c).ok();
                }
            }
        }
        "class" => {
            let want = args.get(1).cloned().unwrap_or_default();
            let mut p = Probe::new(raw)?;
            for (h, cls, _t, _pid, vis, _r) in hwnds() {
                if cls == want && (vis || args.iter().any(|a| a == "--all")) {
                    println!("### HWND 0x{:x} class={cls}", h.0 as usize);
                    let el = unsafe { p.a.ElementFromHandle(h)? };
                    let mut out = Vec::new();
                    p.dump(&el, 0, depth, &mut out);
                    for l in out {
                        println!("{l}");
                    }
                }
            }
        }
        "hwnd" => {
            let h = args
                .get(1)
                .map(|s| usize::from_str_radix(s.trim_start_matches("0x"), 16).unwrap_or(0))
                .unwrap_or(0);
            let mut p = Probe::new(raw)?;
            let el = unsafe { p.a.ElementFromHandle(HWND(h as *mut _))? };
            let mut out = Vec::new();
            p.dump(&el, 0, depth, &mut out);
            for l in out {
                println!("{l}");
            }
        }
        "focus" => {
            let mut p = Probe::new(raw)?;
            let el = unsafe { p.a.GetFocusedElement()? };
            let mut out = Vec::new();
            p.dump(&el, 0, 0, &mut out);
            for l in out {
                println!("{l}");
            }
            let mut cur = el;
            let mut d = 0;
            unsafe {
                while let Ok(parent) = p.walker.GetParentElement(&cur) {
                    d += 1;
                    let l = p.line(&parent, 0);
                    println!("  ^{d} {l}");
                    cur = parent;
                    if d > 20 {
                        break;
                    }
                }
            }
        }
        "point" => {
            let x: i32 = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(0);
            let y: i32 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(0);
            let mut p = Probe::new(raw)?;
            let el = unsafe { p.a.ElementFromPoint(POINT { x, y })? };
            let mut out = Vec::new();
            p.dump(&el, 0, 0, &mut out);
            for l in out {
                println!("{l}");
            }
            let mut cur = el;
            let mut d = 0;
            unsafe {
                while let Ok(parent) = p.walker.GetParentElement(&cur) {
                    d += 1;
                    let l = p.line(&parent, 0);
                    println!("  ^{d} {l}");
                    cur = parent;
                    if d > 20 {
                        break;
                    }
                }
            }
        }
        "post" => {
            // post <hwnd> <keydown-vk-hex>  — PostMessage a key to dismiss stray menus
            let h = args
                .get(1)
                .map(|s| usize::from_str_radix(s.trim_start_matches("0x"), 16).unwrap_or(0))
                .unwrap_or(0);
            let vk = args
                .get(2)
                .and_then(|s| u32::from_str_radix(s.trim_start_matches("0x"), 16).ok())
                .unwrap_or(0x1B);
            unsafe {
                let hw = HWND(h as *mut _);
                if args.iter().any(|a| a == "--wmclose") {
                    let a = PostMessageW(Some(hw), WM_CLOSE, WPARAM(0), LPARAM(0));
                    println!("post WM_CLOSE -> {a:?}");
                } else {
                    let a = PostMessageW(Some(hw), WM_KEYDOWN, WPARAM(vk as usize), LPARAM(0));
                    let b = PostMessageW(Some(hw), WM_KEYUP, WPARAM(vk as usize), LPARAM(0));
                    println!("post WM_KEYDOWN/UP vk=0x{vk:x} -> {a:?} {b:?}");
                }
            }
        }
        "act" => {
            // act <hwnd> <name-substring> <invoke|toggle|ctx|expand|focus>
            let h = args
                .get(1)
                .map(|s| usize::from_str_radix(s.trim_start_matches("0x"), 16).unwrap_or(0))
                .unwrap_or(0);
            let want = args.get(2).cloned().unwrap_or_default();
            let verb = args.get(3).cloned().unwrap_or_else(|| "invoke".into());
            let mut p = Probe::new(true)?;
            let el = unsafe { p.a.ElementFromHandle(HWND(h as *mut _))? };
            let cond = unsafe { p.a.CreateTrueCondition()? };
            let all = unsafe { el.FindAll(TreeScope_Subtree, &cond)? };
            let n = unsafe { all.Length()? };
            let mut hit = false;
            for i in 0..n {
                let c = unsafe { all.GetElement(i)? };
                let name = unsafe { c.CurrentName() }
                    .map(|s| s.to_string())
                    .unwrap_or_default();
                let cls = unsafe { c.CurrentClassName() }
                    .map(|s| s.to_string())
                    .unwrap_or_default();
                let hay = if let Some(cw) = want.strip_prefix("class:") {
                    if !cls.to_lowercase().contains(&cw.to_lowercase()) {
                        continue;
                    }
                    true
                } else {
                    !want.is_empty() && name.to_lowercase().contains(&want.to_lowercase())
                };
                if !hay {
                    continue;
                }
                hit = true;
                let l = p.line(&c, 0);
                println!("target: {l}");
                unsafe {
                    match verb.as_str() {
                        "invoke" => match c
                            .GetCurrentPatternAs::<IUIAutomationInvokePattern>(UIA_InvokePatternId)
                        {
                            Ok(ip) => println!("Invoke -> {:?}", ip.Invoke()),
                            Err(e) => println!("no Invoke pattern: {e}"),
                        },
                        "toggle" => match c
                            .GetCurrentPatternAs::<IUIAutomationTogglePattern>(UIA_TogglePatternId)
                        {
                            Ok(tp) => println!("Toggle -> {:?}", tp.Toggle()),
                            Err(e) => println!("no Toggle pattern: {e}"),
                        },
                        "expand" => match c.GetCurrentPatternAs::<IUIAutomationExpandCollapsePattern>(
                            UIA_ExpandCollapsePatternId,
                        ) {
                            Ok(ep) => println!("Expand -> {:?}", ep.Expand()),
                            Err(e) => println!("no ExpandCollapse pattern: {e}"),
                        },
                        "focus" => println!("SetFocus -> {:?}", c.SetFocus()),
                        "collapse" => match c.GetCurrentPatternAs::<IUIAutomationExpandCollapsePattern>(
                            UIA_ExpandCollapsePatternId,
                        ) {
                            Ok(ep) => println!("Collapse -> {:?}", ep.Collapse()),
                            Err(e) => println!("no ExpandCollapse pattern: {e}"),
                        },
                        "close" => match c
                            .GetCurrentPatternAs::<IUIAutomationWindowPattern>(UIA_WindowPatternId)
                        {
                            Ok(wp) => println!("Window.Close -> {:?}", wp.Close()),
                            Err(e) => println!("no Window pattern: {e}"),
                        },
                        "legacy" => match c
                            .GetCurrentPatternAs::<IUIAutomationLegacyIAccessiblePattern>(
                                UIA_LegacyIAccessiblePatternId,
                            ) {
                            Ok(lp) => println!("DoDefaultAction -> {:?}", lp.DoDefaultAction()),
                            Err(e) => println!("no Legacy pattern: {e}"),
                        },
                        "ctx" => match c.cast::<IUIAutomationElement3>() {
                            Ok(e3) => println!("ShowContextMenu -> {:?}", e3.ShowContextMenu()),
                            Err(e) => println!("no IUIAutomationElement3: {e}"),
                        },
                        other => println!("unknown verb {other}"),
                    }
                }
                break;
            }
            if !hit {
                println!("no element matching {want:?} in subtree");
            }
        }
        "invoke" => {
            let h = args
                .get(1)
                .map(|s| usize::from_str_radix(s.trim_start_matches("0x"), 16).unwrap_or(0))
                .unwrap_or(0);
            let want = args.get(2).cloned().unwrap_or_default();
            let mut p = Probe::new(raw)?;
            let el = unsafe { p.a.ElementFromHandle(HWND(h as *mut _))? };
            let cond = unsafe { p.a.CreateTrueCondition()? };
            let all = unsafe { el.FindAll(TreeScope_Subtree, &cond)? };
            let n = unsafe { all.Length()? };
            for i in 0..n {
                let c = unsafe { all.GetElement(i)? };
                let name = unsafe { c.CurrentName() }
                    .map(|s| s.to_string())
                    .unwrap_or_default();
                if !want.is_empty() && name.to_lowercase().contains(&want.to_lowercase()) {
                    let l = p.line(&c, 0);
                    println!("invoking: {l}");
                    match unsafe {
                        c.GetCurrentPatternAs::<IUIAutomationInvokePattern>(UIA_InvokePatternId)
                    } {
                        Ok(ip) => println!("Invoke -> {:?}", unsafe { ip.Invoke() }),
                        Err(e) => println!("no Invoke pattern: {e}"),
                    }
                    break;
                }
            }
        }
        _ => {
            eprintln!("usage: shell-probe [hwnds|roots|class NAME|hwnd 0xH|focus|point X Y|invoke 0xH NAME] [--raw] [--depth N] [--all]");
        }
    }
    Ok(())
}
