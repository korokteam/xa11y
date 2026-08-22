#!/usr/bin/env python3
"""Two tray icons: one legacy XEmbed (GtkStatusIcon), one StatusNotifierItem
(AyatanaAppIndicator). Lets us see which of the two, if either, shows up in the
panel's AT-SPI tree."""
import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # noqa: E402

# --- legacy XEmbed system tray icon -------------------------------------
legacy = Gtk.StatusIcon()
legacy.set_from_icon_name("dialog-information")
legacy.set_tooltip_text("Legacy XEmbed icon")
legacy.set_title("LegacyXEmbedIcon")
legacy.set_visible(True)

legacy_menu = Gtk.Menu()
for label in ("Legacy Open", "Legacy Quit"):
    item = Gtk.MenuItem(label=label)
    item.show()
    legacy_menu.append(item)
legacy.connect(
    "popup-menu",
    lambda icon, button, time: legacy_menu.popup(None, None, None, None, button, time),
)

# --- StatusNotifierItem via AyatanaAppIndicator -------------------------
try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator

    ind = AppIndicator.Indicator.new(
        "xa11y-probe-sni",
        "dialog-warning",
        AppIndicator.IndicatorCategory.APPLICATION_STATUS,
    )
    ind.set_status(AppIndicator.IndicatorStatus.ACTIVE)
    ind.set_title("SniProbeIcon")
    menu = Gtk.Menu()
    for label in ("SNI Open", "SNI Quit"):
        item = Gtk.MenuItem(label=label)
        item.show()
        menu.append(item)
    ind.set_menu(menu)
    print("SNI indicator created", flush=True)
except Exception as exc:  # noqa: BLE001
    print(f"SNI indicator unavailable: {exc}", flush=True)

print("tray app running", flush=True)
Gtk.main()
