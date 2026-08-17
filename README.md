# katlib

Shared utilities for the kat-family apps (kat800 and its siblings) — the reusable
code that is *not* a gap in Odin's `core` and so does **not** belong in
[Amber LIB](https://github.com/Hyperquader-Coders/amber-lib). Opinionated,
app-flavoured helpers (display formatting, kat conventions) that two or more kat
projects want in common.

## katlib vs Amber LIB

|          | Amber LIB                                    | katlib                                          |
| -------- | --------------------------------------------- | ----------------------------------------------- |
| Charter  | gaps in Odin's `core`, mirroring Go's stdlib  | reusable across kat apps, no stdlib analogue    |
| Deps     | `base`/`core` only                            | `base`/`core` only (toolkit-free)               |
| Upstream | written to be contributed to Odin             | never — kat-specific                            |
| Example  | `amber:afs` path expansion                    | path-display truncation, X11 window placement   |

The sorting rule:

- Has a Go/stdlib analogue and you'd PR it to Odin → **Amber LIB**.
- Reusable across your apps but opinionated with no upstream home → **katlib**.
- One app, one use → leave it in that app until a second consumer appears.

## Using katlib

Odin has no package manager, so consume it as a collection. Clone it as a sibling
of your project and point the compiler at it:

```sh
odin build . -collection:kat=/path/to/katlib
```

…or in a Makefile:

```make
KATLIB ?= ../katlib
COLLECTIONS += -collection:kat=$(KATLIB)
```

Then import packages by name:

```odin
import text "kat:text"
```

For editor / language-server resolution, add it to your project's `ols.json`:

```json
{ "collections": [{ "name": "kat", "path": "../katlib" }] }
```

## Packages

| Package | What it does |
| --- | --- |
| `kat:text` | path shortening for display |
| `kat:crash` | the suite's crash log — `<cache>/<app>/crash.log` |
| `kat:gtkenv` | the environment a bundled GTK4 needs, set before `gtk_init` |
| `kat:x11` | the window-manager talk GTK4 dropped — placement, EWMH state, hints |

Add a package as a directory at the repo root (`<pkg>/<pkg>.odin` +
`<pkg>/<pkg>_test.odin`, with a package-level doc comment), then add its name to
`PACKAGES` in the Makefile.

### `kat:text`

| proc | behaviour |
|---|---|
| `truncate_path(path, max_len, allocator) -> string` | Shortens a `/`-separated path to fit `max_len` bytes for display, keeping as many trailing segments as fit and folding the hidden ancestors into a leading `…/`. A path that already fits is returned unchanged. When even the trailing segment overflows it is returned bare, without the `…/`, so the caller's widget can ellipsize it. |

**The allocator default is `context.temp_allocator`, not `context.allocator`** —
the exception to the house rule, because the caller is a widget setting a label
that is copied immediately. A result that must outlive the next temp reset needs
an explicit allocator, and the caller frees it.

### `kat:crash`

Every app here launches from a tray, an autostart entry or a desktop menu, so none
has a terminal and a fault otherwise leaves nothing behind but "it vanished".

```odin
import crash "kat:crash"

crash.init("myapp", VERSION)   // start header, signal handlers
defer crash.clean_exit()
crash.line("something worth recording")
```

| proc | behaviour |
|---|---|
| `init(app, version)` | Opens `<cache>/<app>/crash.log`, writes the start header and installs the fatal-signal handlers. `app` names both the directory and the header; `version` is whatever the build stamped in, so the log cannot disagree with the package version. |
| `clean_exit()` | Writes the clean-exit marker. |
| `line(text)` | Appends one pid-tagged line. Public so an app's GLib writer hook can share this log. |

Writes a stamped start header, fatal-signal backtraces (signal number, elapsed
seconds and epoch) and a clean-exit marker, every line tagged with the writing pid.
The handler runs on an alternate stack so a stack-overflow SIGSEGV still logs, and
formats nothing — it is async-signal-safe throughout.

Build with **`-rdynamic`** or every backtrace frame is a bare address instead of a
proc name.

**The GLib writer hook stays in the app**, not here: it is what captures GLib
CRITICALs into the same file, and each app binds GLib differently (`odin_gtk:glib`,
hand-rolled `foreign`) while some link none at all. The app's hook calls
`crash.line`, which is why that proc is public — and it is what keeps this package
toolkit-free.

Four apps want this, and separate copies drift: one loses the pid tag and hardcodes
`$HOME/.cache`, putting its log where nobody looks when the session sets
`XDG_CACHE_HOME`; another has no timestamps. One copy is the reason it lives here.

### `kat:gtkenv`

```odin
import gtkenv "kat:gtkenv"

gtkenv.use_system_modules()   // BEFORE gtk.init()
```

| proc | behaviour |
|---|---|
| `use_system_modules() -> string` | Points `GTK_PATH` at the distro's GTK4 module directory and returns the one it chose — `""` when none exists or the caller had already set `GTK_PATH`. Log the return to record which directory an app actually got. |
| `module_dir() -> string` | The directory `use_system_modules` would pick, without touching the environment. Split out so a caller can report it, and so the choice is testable without mutating the process. |
| `has_immodules(dir) -> bool` | Whether `dir` carries input-method modules. A module directory that exists but is empty buys nothing, and a bundled prefix has exactly that shape. |

The amber apps ship a **bundled GTK** (`amber-gtk4`) rather than the distro's, because
kat800 needs 4.16 for VTE and one GTK across the suite beats two. A bundle built for size
carries no input-method modules — its `lib/gtk-4.0` holds a print backend and nothing
else, where Mint's holds `immodules/libim-ibus.so` — so unless GTK is told where the
system's modules are, **IME input silently stops working**. No dialog, no error: a line
in a crash log, and a user who cannot type Japanese.

`GTK_PATH` is prepended to GTK's own search path rather than replacing it, so the call is
additive and needs no am-I-bundled test — a check that can be wrong is worse than a call
that is always right. An existing `GTK_PATH` is never overwritten.

It is here rather than in each app for the reason `kat:crash` is: two apps linking the
same bundle need the same fix, and the copy that drifts is the one whose IME breaks.

### `kat:x11`

```odin
import x11 "kat:x11"

x11.move(display, xid, 100, 100)
x11.set_wm_state(display, xid, "_NET_WM_STATE_ABOVE", true)
```

| proc | behaviour |
|---|---|
| `get_position(display, w) -> (x, y, ok)` | Absolute screen position of a window. |
| `move(display, w, x, y)` | Moves the window and flushes. |
| `get_workarea(display) -> (x, y, w, h, ok)` | The desktop's usable rectangle (`_NET_WORKAREA` on the root, minus panels and docks). `ok=false` when the WM publishes no work area. |
| `set_wm_state(display, w, name, on)` | Adds or removes one `_NET_WM_STATE` atom, e.g. `_NET_WM_STATE_ABOVE`. A mapped window must *ask* the WM with a ClientMessage rather than writing the property itself, which is why this keeps working while the window is on screen — a send, not a set. |
| `set_cardinal(display, w, name, value, present)` | Sets or removes a single 32-bit `CARDINAL` property. kat800 drives the XApp taskbar-progress hints with this. |
| `set_all_wm_functions(display, w)` | Re-asserts full Motif WM functions. Cinnamon strips the close button from a window whose app also has a status icon, which those apps do not want. |

Linux/X11 only. On Wayland none of this applies and none of it should be called.

GTK4 deliberately dropped window placement, stacking and the taskbar hints — they are the
window manager's business — which is right for an ordinary app and useless for one that
positions its own panel. kat800 and ambrosia both need it, and each carried only its own
half: Motif hints and the XApp progress cardinal on one side, EWMH state and the work area
on the other. This package is their union.

**It stays toolkit-free**, which the API shape is what makes possible: it takes a display
and a window id, so the one GTK-specific step — turning a `GtkWidget` into those two, via
`gdk_x11_display_get_xdisplay` and `gdk_x11_surface_get_xid`, which links libgtk-4 —
stays in each app as a two-extern `bindings/gdkx`. Two lines there buys a package anything
on X11 can use.

## Design rules

- **Toolkit-free.** No GTK/libadwaita/app-state deps — keep every package
  importable by any kat app and unit-testable headless. Logic *adjacent* to the
  UI (formatting a string a widget will show) is fine; calling into the toolkit
  is not.
- **Odin idiom**, same as Amber LIB: `snake_case`, explicit
  `allocator := context.allocator` parameters, tuple returns. Returned strings
  use the caller's allocator; intermediates go through `context.temp_allocator`.
- **Earn the slot.** Promote here only when a second consumer (or a second helper
  of the same kind) appears — not speculatively.

## Roadmap

The prioritized backlog lives in [MoSCoW.md](MoSCoW.md); the bar for adding a
package is the one above — a second consumer, not a hunch.

## Development

```sh
make check   # type-check every package
make test    # run core:testing suites
make doc     # odin doc for every package
make lint    # shellcheck any shell scripts (skipped if shellcheck is absent)
```

`make check` and `make test` also run in CI on every push and pull request
(`.github/workflows/ci.yml`), against the toolchain from
`Hyperquader-Coders/setup-amber-odin`.

## License

BSD-3-Clause. See [LICENSE](LICENSE).
