package x11

// Package x11 is the window-manager talk GTK4 no longer does for you.
//
// GTK4 deliberately dropped window placement, stacking and the taskbar hints —
// `gtk_window_move`, `gtk_window_get_position`, `gdk_monitor_get_workarea`,
// `gtk_window_set_keep_above`, `gtk_window_set_skip_taskbar_hint` — on the grounds that
// they are the window manager's business. That is defensible for an ordinary app and
// useless for one that positions its own panel, so those apps have to speak X11.
//
// Two of them need the same file (kat800 for saved geometry and Motif hints, ambrosia for
// centring and EWMH state), and separate copies diverge to whatever each one happens to
// use. This package is their union.
//
// **Toolkit-free**, per katlib's charter, and that is not an accident: the API takes a
// display and a window id, so the GTK-specific step — turning a `GtkWidget` into those
// two, which is `gdk_x11_display_get_xdisplay` and `gdk_x11_surface_get_xid` and links
// libgtk-4 — stays in the app that has a GTK window to hand. Two externs there against a
// package anything on X11 can use here.
//
// Linux/X11 only. On Wayland none of this applies and none of it should be called.

import "core:c"

XDisplay :: struct {}
XID :: c.ulong

when ODIN_OS == .Linux {
	foreign import xlib "system:X11"
}

@(default_calling_convention = "c")
foreign xlib {
	XMoveWindow :: proc(display: ^XDisplay, w: XID, x: c.int, y: c.int) -> c.int ---
	XTranslateCoordinates :: proc(display: ^XDisplay, src_w: XID, dest_w: XID, src_x: c.int, src_y: c.int, dest_x: ^c.int, dest_y: ^c.int, child: ^XID) -> c.int ---
	XDefaultRootWindow :: proc(display: ^XDisplay) -> XID ---
	XFlush :: proc(display: ^XDisplay) -> c.int ---
	XInternAtom :: proc(display: ^XDisplay, name: cstring, only_if_exists: c.int) -> c.ulong ---
	XChangeProperty :: proc(display: ^XDisplay, w: XID, property: c.ulong, type: c.ulong, format: c.int, mode: c.int, data: [^]u8, nelements: c.int) -> c.int ---
	XDeleteProperty :: proc(display: ^XDisplay, w: XID, property: c.ulong) -> c.int ---
	XGetWindowProperty :: proc(display: ^XDisplay, w: XID, property: c.ulong, long_offset: c.long, long_length: c.long, delete: c.int, req_type: c.ulong, actual_type: ^c.ulong, actual_format: ^c.int, nitems: ^c.ulong, bytes_after: ^c.ulong, prop: ^[^]u8) -> c.int ---
	XFree :: proc(data: rawptr) -> c.int ---
	XSendEvent :: proc(display: ^XDisplay, w: XID, propagate: c.int, event_mask: c.long, event: ^XEvent) -> c.int ---
}

// --- placement --------------------------------------------------------------

// Absolute screen position of an X window.
get_position :: proc(display: ^XDisplay, w: XID) -> (x, y: i32, ok: bool) {
	dx, dy: c.int
	child: XID
	root := XDefaultRootWindow(display)
	if XTranslateCoordinates(display, w, root, 0, 0, &dx, &dy, &child) == 0 {
		return
	}
	return i32(dx), i32(dy), true
}

move :: proc(display: ^XDisplay, w: XID, x, y: i32) {
	XMoveWindow(display, w, c.int(x), c.int(y))
	XFlush(display)
}

XA_CARDINAL: c.ulong : 6

// The current desktop's usable rectangle (_NET_WORKAREA on the root, minus
// panels/docks). ok=false when the WM publishes no work area.
get_workarea :: proc(display: ^XDisplay) -> (x, y, w, h: i32, ok: bool) {
	atom := XInternAtom(display, "_NET_WORKAREA", 1) // only_if_exists
	if atom == 0 {
		return
	}
	actual_type: c.ulong
	actual_format: c.int
	nitems, bytes_after: c.ulong
	prop: [^]u8
	root := XDefaultRootWindow(display)
	if XGetWindowProperty(display, root, atom, 0, 4, 0, XA_CARDINAL, &actual_type, &actual_format, &nitems, &bytes_after, &prop) != 0 {
		return
	}
	if prop == nil {
		return
	}
	defer XFree(prop)
	if actual_format != 32 || nitems < 4 {
		return // format-32 properties come back as one C long per element
	}
	vals := ([^]c.ulong)(prop)
	return i32(vals[0]), i32(vals[1]), i32(vals[2]), i32(vals[3]), true
}

// --- EWMH window state ------------------------------------------------------

@(private) SUBSTRUCTURE_NOTIFY_MASK: c.long : 1 << 19
@(private) SUBSTRUCTURE_REDIRECT_MASK: c.long : 1 << 20
@(private) CLIENT_MESSAGE: c.int : 33
@(private) NET_WM_STATE_REMOVE: c.long : 0
@(private) NET_WM_STATE_ADD: c.long : 1

// XEvent is a union of every event type; only the ClientMessage arm is written
// here, padded to the union's full width because XSendEvent reads the whole
// object. The assertion is the guard: get the padding wrong and the build fails
// instead of Xlib reading past the end of a stack value.
XEvent :: struct {
	type:         c.int,
	serial:       c.ulong,
	send_event:   c.int,
	display:      ^XDisplay,
	window:       XID,
	message_type: c.ulong,
	format:       c.int,
	data:         [5]c.long,
	_pad:         [12]c.long,
}
#assert(size_of(XEvent) == 24 * size_of(c.long))

// set_wm_state adds or removes one _NET_WM_STATE atom, e.g.
// "_NET_WM_STATE_ABOVE" or "_NET_WM_STATE_SKIP_TASKBAR".
//
// A window that is already mapped must *ask* the window manager with a ClientMessage
// rather than writing the property itself, which is why this keeps working while the
// window is on screen — and why it is a send, not a set.
set_wm_state :: proc(display: ^XDisplay, w: XID, name: cstring, on: bool) {
	state := XInternAtom(display, "_NET_WM_STATE", 0)
	which := XInternAtom(display, name, 0)
	if state == 0 || which == 0 {return}

	ev := XEvent {
		type         = CLIENT_MESSAGE,
		display      = display,
		window       = w,
		message_type = state,
		format       = 32,
	}
	ev.data[0] = on ? NET_WM_STATE_ADD : NET_WM_STATE_REMOVE
	ev.data[1] = c.long(which)
	// data[2] is a second atom (unused); data[3] is the source indication, where
	// 1 means a normal application — what EWMH expects from us.
	ev.data[3] = 1

	root := XDefaultRootWindow(display)
	XSendEvent(display, root, 0, SUBSTRUCTURE_NOTIFY_MASK | SUBSTRUCTURE_REDIRECT_MASK, &ev)
	XFlush(display)
}

// --- window properties ------------------------------------------------------

// Set or remove a single 32-bit CARDINAL window property (format-32 properties carry
// their elements as longs). kat800 drives the XApp taskbar-progress hints with this.
set_cardinal :: proc(display: ^XDisplay, w: XID, name: cstring, value: u32, present: bool) {
	atom := XInternAtom(display, name, 0)
	if present {
		v := c.ulong(value)
		XChangeProperty(display, w, atom, XA_CARDINAL, 32, 0, ([^]u8)(&v), 1)
	} else {
		XDeleteProperty(display, w, atom)
	}
	XFlush(display)
}

// --- Motif hints ------------------------------------------------------------

// Re-assert full Motif WM functions. Cinnamon strips the close button from windows
// belonging to an app that also has a status icon, which is not what those apps want.
MWM_HINTS_FUNCTIONS :: 1 << 0
MWM_FUNC_ALL :: 1 << 0

set_all_wm_functions :: proc(display: ^XDisplay, w: XID) {
	hints := [5]c.ulong{MWM_HINTS_FUNCTIONS, MWM_FUNC_ALL, 0, 0, 0}
	atom := XInternAtom(display, "_MOTIF_WM_HINTS", 0)
	XChangeProperty(display, w, atom, atom, 32, 0, ([^]u8)(&hints[0]), 5) // 0 = PropModeReplace
	XFlush(display)
}
