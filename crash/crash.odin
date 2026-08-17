package crash

// Package crash is the amber suite's crash log: apps here launch from a tray, an
// autostart entry or a desktop menu, so they have no terminal and a fault otherwise
// leaves nothing behind but "it vanished".
//
// Writes `<cache>/<app>/crash.log` — a stamped start header, fatal-signal backtraces,
// and a clean-exit marker. `line` is public so an app that links GLib can hook its log
// writer and put CRITICALs in the same file; that hook stays in the app because each one
// binds GLib differently (odin_gtk:glib, hand-rolled foreign) and some link none at all.
//
// It lives here rather than in amber-lib because it is opinionated and has no upstream
// home: the log's shape, the pid tag and the markers are this suite's conventions, not a
// gap in Odin's `core`. Four apps want it, and separate copies drift apart — see
// README.md.

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

foreign import libc_bt "system:c"

@(default_calling_convention = "c")
foreign libc_bt {
	backtrace :: proc(buffer: [^]rawptr, size: c.int) -> c.int ---
	backtrace_symbols_fd :: proc(buffer: [^]rawptr, size: c.int, fd: c.int) ---
}

// Held open for the handler, which cannot open files.
@(private = "file") crash_fd: posix.FD = -1
@(private = "file") log_path: string

// Every line carries the writing process's pid. One log is shared by every instance — the
// user's session, a dev build, each short-lived CLI run — and their lines interleave, so an
// untagged "clean exit" belongs to no one in particular.
@(private = "file") pid_tag: string

// The handler runs here, so a stack-overflow SIGSEGV still has room to log.
@(private = "file") alt_stack: [128 * 1024]u8

// The handler cannot format, so the fixed head of its line is rendered once at init; the
// numbers are appended by hand at signal time (write_u64).
@(private = "file") sig_head: [64]u8
@(private = "file") sig_head_len: int

// Start time for the elapsed figure on the fatal line. MONOTONIC because "how long had it
// been up" must not be rewritten by an NTP step mid-run.
//
// That figure is the reason for stamping at all. Sequence already orders the lines and one
// instance is already `grep '\[<pid>\]'`, but a `start` followed immediately by a `fatal
// signal` reads the same whether the gap was 12 hours or 200 ms — and those are different
// bugs. Diagnosing one crash meant recovering the time from a core dump and a WAL mtime
// because this file could not say.
@(private = "file") start_mono: posix.time_t

// init opens the log, writes the start header and installs the fatal-signal handlers.
// `app` names both the directory and the header; `version` is whatever the app's build
// stamped in, so the log cannot disagree with the package version.
init :: proc(app: string, version: string) {
	base := os.get_env("XDG_CACHE_HOME", context.temp_allocator)
	if base == "" {
		// Honour XDG first: a hardcoded $HOME/.cache puts the log where nobody is looking
		// when the session sets XDG_CACHE_HOME, which is how one app's log went missing.
		home := os.get_env("HOME", context.temp_allocator)
		if home == "" {return}
		base = fmt.tprintf("%s/.cache", home)
	}
	dir := fmt.tprintf("%s/%s", base, app)
	make_dir_all(dir)

	log_path = fmt.aprintf("%s/crash.log", dir)
	pid_tag = fmt.aprintf("[%d] ", os.get_pid())
	sig_head_len = copy(sig_head[:], fmt.tprintf("%s--- fatal signal ", pid_tag))

	mono: posix.timespec
	posix.clock_gettime(.MONOTONIC, &mono)
	start_mono = mono.tv_sec
	line(fmt.tprintf("--- %s %s start %s ---", app, version, local_now()))

	crash_fd = posix.open(strings.clone_to_cstring(log_path, context.temp_allocator), {.WRONLY, .APPEND})
	install_signal_handlers()
}

clean_exit :: proc() {
	line("--- clean exit ---")
}

// line appends one tagged line. Public so an app's GLib writer hook can share this log.
line :: proc(text: string) {
	if log_path == "" {return}
	f, err := os.open(
		log_path,
		os.O_WRONLY | os.O_CREATE | os.O_APPEND,
		{.Read_User, .Write_User, .Read_Group, .Read_Other},
	)
	if err != nil {return}
	defer os.close(f)
	_, _ = os.write_string(f, pid_tag)
	_, _ = os.write_string(f, text)
	_, _ = os.write_string(f, "\n")
}

// Local wall-clock for the start header only: strftime/localtime_r are NOT
// async-signal-safe, so the fatal path uses raw epoch seconds instead. %Z names the zone so
// a BST line cannot be misread as UTC when the log is read back in winter.
@(private = "file")
local_now :: proc() -> string {
	rt: posix.timespec
	posix.clock_gettime(.REALTIME, &rt)
	t := rt.tv_sec
	tmv: posix.tm
	if posix.localtime_r(&t, &tmv) == nil {return "time?"}
	buf: [64]u8
	n := posix.strftime(raw_data(buf[:]), len(buf), "%Y-%m-%d %H:%M:%S %Z", &tmv)
	if n == 0 {return "time?"}
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

// Decimal digits into `buf`, returning the length written. Async-signal-safe: contextless,
// no allocation, no fmt — the fatal handler's only way to put a number in the file.
@(private)
write_u64 :: proc "contextless" (buf: []u8, v: u64) -> int {
	if v == 0 {
		buf[0] = '0'
		return 1
	}
	rev: [20]u8
	n := 0
	for x := v; x > 0; x /= 10 {
		rev[n] = u8('0' + x % 10)
		n += 1
	}
	for i in 0 ..< n {buf[i] = rev[n - 1 - i]}
	return n
}

@(private = "file")
make_dir_all :: proc(path: string) {
	if path == "" || os.exists(path) {return}
	if idx := strings.last_index_byte(path, '/'); idx > 0 {make_dir_all(path[:idx])}
	os.make_directory(path)
}

@(private = "file")
install_signal_handlers :: proc() {
	ss: posix.stack_t
	ss.ss_sp = raw_data(alt_stack[:])
	ss.ss_size = len(alt_stack)
	posix.sigaltstack(&ss, nil)

	act: posix.sigaction_t
	act.sa_handler = on_fatal_signal
	// RESETHAND so the re-raise below gets the default action and the process really dies,
	// leaving a core dump behind.
	act.sa_flags = {.ONSTACK, .RESETHAND}
	posix.sigaction(.SIGSEGV, &act, nil)
	posix.sigaction(.SIGABRT, &act, nil)
	posix.sigaction(.SIGBUS, &act, nil)
	posix.sigaction(.SIGFPE, &act, nil)
}

// Async-signal-safe only: raw write(2), clock_gettime (both on the POSIX async-safe list)
// and backtrace_symbols_fd. No allocation, no fmt, no localtime.
@(private = "file")
on_fatal_signal :: proc "c" (sig: posix.Signal) {
	if crash_fd >= 0 {
		// "fatal signal 11 after 43220s (epoch 1786621820)": the number separates a SIGSEGV
		// from an abort on a GLib assertion, the elapsed figure says whether this was a
		// long run or a startup failure, and the epoch pins it against other logs.
		buf: [160]u8
		n := copy(buf[:], sig_head[:sig_head_len])
		n += write_u64(buf[n:], u64(int(sig)))

		mono, rt: posix.timespec
		posix.clock_gettime(.MONOTONIC, &mono)
		posix.clock_gettime(.REALTIME, &rt)
		n += copy(buf[n:], " after ")
		n += write_u64(buf[n:], u64(mono.tv_sec - start_mono))
		n += copy(buf[n:], "s (epoch ")
		n += write_u64(buf[n:], u64(rt.tv_sec))
		// The frames below go out untagged — backtrace_symbols_fd writes them itself and is
		// the only async-safe way to do it. They follow this line.
		n += copy(buf[n:], "), backtrace: ---\n")
		posix.write(crash_fd, raw_data(buf[:]), c.size_t(n))

		frames: [64]rawptr
		backtrace_symbols_fd(&frames[0], backtrace(&frames[0], 64), c.int(crash_fd))
	}
	posix.raise(sig) // RESETHAND restored the default action, so this really dies
}
