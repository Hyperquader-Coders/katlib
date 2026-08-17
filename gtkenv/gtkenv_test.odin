package gtkenv

import "core:os"
import "core:strings"
import "core:testing"

// The environment is process-wide and the test runner is multi-threaded, so these run
// in one test rather than three that could interleave on GTK_PATH.
@(test)
test_use_system_modules :: proc(t: ^testing.T) {
	saved, had := os.lookup_env("GTK_PATH", context.temp_allocator)
	defer if had {os.set_env("GTK_PATH", saved)} else {os.unset_env("GTK_PATH")}

	// An existing value is the caller's, and is never overwritten.
	os.set_env("GTK_PATH", "/somewhere/of/my/own")
	testing.expect_value(t, use_system_modules(), "")
	got, _ := os.lookup_env("GTK_PATH", context.temp_allocator)
	testing.expect_value(t, got, "/somewhere/of/my/own")

	// With none set, it picks the distro directory — and actually exports it, which is
	// the whole job.
	os.unset_env("GTK_PATH")
	want := module_dir()
	chosen := use_system_modules()
	testing.expect_value(t, chosen, want)
	if want != "" {
		exported, set := os.lookup_env("GTK_PATH", context.temp_allocator)
		testing.expect(t, set, "GTK_PATH was not exported")
		testing.expect_value(t, exported, want)
	}
}

// module_dir must name a directory that exists, or nothing was gained by pointing GTK at
// it. It is allowed to find none — a machine with no GTK4 installed is a valid state.
@(test)
test_module_dir_exists_when_found :: proc(t: ^testing.T) {
	dir := module_dir()
	if dir == "" {return}
	testing.expect(t, os.exists(dir), "module_dir returned a path that does not exist")
}

// The reason the package exists: a directory with no immodules in it does not solve the
// IME problem. This asserts the *predicate*, not the machine — a build host with no
// ibus installed is not a failure, so it only checks that a positive answer is backed by
// a real .so.
@(test)
test_has_immodules_is_honest :: proc(t: ^testing.T) {
	testing.expect(t, !has_immodules(""), "an empty path cannot carry modules")
	testing.expect(t, !has_immodules("/nonexistent/gtk-4.0"), "a missing path cannot carry modules")
	if dir := module_dir(); dir != "" && has_immodules(dir) {
		fd, err := os.open(strings.concatenate({dir, "/4.0.0/immodules"}, context.temp_allocator))
		testing.expect(t, err == nil, "has_immodules said yes but the directory will not open")
		if err == nil {os.close(fd)}
	}
}
