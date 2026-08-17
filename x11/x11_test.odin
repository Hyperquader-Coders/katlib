package x11

// These tests never open a display: they run headless, in CI, with no X server.
// What they check instead is the part that cannot be checked at runtime anywhere
// else — the ABI. XEvent mirrors Xlib's XClientMessageEvent field for field, and
// XSendEvent reads the whole object, so a field in the wrong place is a silent
// misread by the X server rather than a compile error.

import "core:c"
import "core:testing"

// Xlib's XClientMessageEvent, in order:
//
//	int            type;
//	unsigned long  serial;
//	Bool           send_event;      // int
//	Display       *display;
//	Window         window;          // XID
//	Atom           message_type;    // unsigned long
//	int            format;
//	union { char b[20]; short s[10]; long l[5]; } data;
//
// The union is 5 longs wide, and the padding after it carries XEvent out to the
// full union-of-all-events width that XSendEvent expects to read.
@(test)
test_xevent_layout :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(XEvent), 24 * size_of(c.long))

	// Field order. Each offset is the previous field's end, rounded up to its own
	// alignment — an inserted or reordered field breaks exactly one of these.
	testing.expect_value(t, offset_of(XEvent, type), 0)
	testing.expect_value(t, offset_of(XEvent, serial), size_of(c.long))
	testing.expect_value(t, offset_of(XEvent, send_event), 2 * size_of(c.long))
	testing.expect_value(t, offset_of(XEvent, display), 3 * size_of(c.long))
	testing.expect_value(t, offset_of(XEvent, window), 4 * size_of(c.long))
	testing.expect_value(t, offset_of(XEvent, message_type), 5 * size_of(c.long))
	testing.expect_value(t, offset_of(XEvent, format), 6 * size_of(c.long))
	testing.expect_value(t, offset_of(XEvent, data), 7 * size_of(c.long))

	// The five data longs must fit inside the object, before the padding.
	testing.expect(
		t,
		offset_of(XEvent, data) + 5 * size_of(c.long) <= size_of(XEvent),
		"data[5] overruns XEvent",
	)
}

// XID is Xlib's Window/Atom/Drawable handle. Getting its width wrong truncates
// every window id passed across the boundary.
@(test)
test_xid_width :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(XID), size_of(c.ulong))
}

// Wire constants, fixed by EWMH and Xlib. They are values a server compares
// against, so a typo here is a request the WM ignores rather than an error.
@(test)
test_protocol_constants :: proc(t: ^testing.T) {
	testing.expect_value(t, CLIENT_MESSAGE, 33) // Xlib ClientMessage
	testing.expect_value(t, NET_WM_STATE_REMOVE, 0) // EWMH _NET_WM_STATE_REMOVE
	testing.expect_value(t, NET_WM_STATE_ADD, 1) // EWMH _NET_WM_STATE_ADD
	testing.expect_value(t, SUBSTRUCTURE_NOTIFY_MASK, c.long(1) << 19)
	testing.expect_value(t, SUBSTRUCTURE_REDIRECT_MASK, c.long(1) << 20)
	testing.expect_value(t, XA_CARDINAL, 6) // Xlib predefined atom
	testing.expect_value(t, MWM_HINTS_FUNCTIONS, 1)
	testing.expect_value(t, MWM_FUNC_ALL, 1)
}
