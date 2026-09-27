#!/usr/bin/env python3
# Minimal WebKitGTK 6 (GTK4) fullscreen kiosk, for the browser memory comparison only.
import sys, gi
gi.require_version("Gtk", "4.0"); gi.require_version("WebKit", "6.0")
from gi.repository import Gtk, WebKit
def on_activate(app):
    w = Gtk.ApplicationWindow(application=app); v = WebKit.WebView()
    v.load_uri(sys.argv[1]); w.set_child(v); w.fullscreen(); w.present()
app = Gtk.Application(application_id="org.tsx.webkitkiosk"); app.connect("activate", on_activate)
app.run(None)
