#!/usr/bin/env python3
"""Bridge between this widget and fcitx5's kimpanel UI addon.

The widget is instantiated once per monitor, so several of these bridges run
at once. Only ONE may own org.kde.impanel (fcitx5 matches TriggerProperty by
sender = name owner), so the bridges cooperate:

- every bridge forwards fcitx5's status broadcasts (current IM, Mozc
  composition mode, Rime actions) to its stdout as JSON lines;
- the bridge that owns org.kde.impanel exposes Trigger(s) on
  io.github.kaz.KimpanelBridge /org/kde/impanel and emits TriggerProperty;
- non-owners forward stdin trigger lines to the owner over that method, and
  retry ownership when the name becomes free (owner's monitor/window gone).

Each stdin line is a "/Fcitx/..." property path, e.g.
/Fcitx/mozc-mode-hiragana.

fcitx5 must run with XDG_CURRENT_DESKTOP=KDE:Hyprland so its kimpanel addon
only takes the status area and leaves preedit/candidates to classicui
(see systemd drop-in for omarchy-fcitx5.service).
"""
import json
import sys
import threading
import warnings

warnings.filterwarnings("ignore", category=DeprecationWarning)

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

PANEL_NAME = "org.kde.impanel"
PANEL_PATH = "/org/kde/impanel"
IM_IFACE = "org.kde.kimpanel.inputmethod"
BRIDGE_IFACE = "io.github.kaz.KimpanelBridge"

BRIDGE_XML = f"""
<node>
  <interface name="{BRIDGE_IFACE}">
    <method name="Trigger">
      <arg type="s" direction="in"/>
    </method>
  </interface>
</node>"""

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
loop = GLib.MainLoop()
node_info = Gio.DBusNodeInfo.new_for_xml(BRIDGE_XML)

own_id = 0  # bus_own_name handle; 0 = not requested
reg_id = 0  # registered Trigger object; 0 = not registered
is_owner = False


def emit(member, args=None):
    bus.emit_signal(None, PANEL_PATH, PANEL_NAME, member, args)


def out(event, value):
    print(json.dumps({"e": event, "v": value}), flush=True)


# ---- reading: forward fcitx5's status broadcasts (no ownership needed)

def on_signal(_conn, _sender, _path, _iface, signal, params):
    values = params.unpack()
    if signal == "RegisterProperties":
        for prop in values[0]:
            out("r", prop)
    elif signal == "UpdateProperty":
        out("u", values[0])
    elif signal == "Enable":
        out("n", values[0])


def on_fcitx5_owner(_conn, _sender, _path, _iface, _signal, params):
    _name, _old, new = params.unpack()
    if not new:  # fcitx5's kimpanel side went away (restart/crash)
        out("lost", True)


bus.signal_subscribe(None, IM_IFACE, None, None, None,
                     Gio.DBusSignalFlags.NONE, on_signal)
bus.signal_subscribe(None, "org.freedesktop.DBus", "NameOwnerChanged",
                     "/org/freedesktop/DBus", IM_IFACE,
                     Gio.DBusSignalFlags.NONE, on_fcitx5_owner)


# ---- writing: only the name owner's TriggerProperty matches fcitx5's rule

def on_trigger_call(_conn, _sender, _path, _iface, _method, params, invocation):
    path = params.unpack()[0]
    if isinstance(path, str) and path.startswith("/Fcitx/"):
        emit("TriggerProperty", GLib.Variant("(s)", (path,)))
    invocation.return_value(None)


def on_trigger_reply(conn, result):
    try:
        conn.call_finish(result)
    except GLib.Error:
        pass  # no owner right now; drop


def trigger(path):
    if is_owner:
        emit("TriggerProperty", GLib.Variant("(s)", (path,)))
    else:
        bus.call(PANEL_NAME, PANEL_PATH, BRIDGE_IFACE, "Trigger",
                 GLib.Variant("(s)", (path,)), None,
                 Gio.DBusCallFlags.NONE, -1, None, on_trigger_reply)


# ---- ownership: claim the name; retry when it becomes free

def acquire():
    global own_id
    if own_id:
        return
    own_id = Gio.bus_own_name_on_connection(bus, PANEL_NAME,
                                            Gio.BusNameOwnerFlags.NONE,
                                            on_name_acquired, on_name_lost)


def on_name_acquired(_conn, _name):
    global reg_id, is_owner
    is_owner = True
    if not reg_id:
        reg_id = bus.register_object(PANEL_PATH, node_info.interfaces[0],
                                     on_trigger_call, None, None)
    emit("PanelCreated")
    out("owner", True)


def on_name_lost(_conn, _name):
    global is_owner, reg_id, own_id
    is_owner = False
    if reg_id:
        bus.unregister_object(reg_id)
        reg_id = 0
    own_id = 0  # re-acquire via the NameOwnerChanged watch


def on_name_owner_changed(_conn, _sender, _path, _iface, _signal, params):
    _name, _old, new = params.unpack()
    if not new and not is_owner:
        acquire()


bus.signal_subscribe(None, "org.freedesktop.DBus", "NameOwnerChanged",
                     "/org/freedesktop/DBus", PANEL_NAME,
                     Gio.DBusSignalFlags.NONE, on_name_owner_changed)
acquire()


# ---- stdin: "/Fcitx/..." trigger paths, one per line

def stdin_thread():
    for line in sys.stdin:
        path = line.strip()
        if path.startswith("/Fcitx/"):
            GLib.idle_add(trigger, path)
    GLib.idle_add(loop.quit)  # EOF: parent died


threading.Thread(target=stdin_thread, daemon=True).start()

try:
    loop.run()
finally:
    if own_id:
        Gio.bus_unown_name(own_id)
