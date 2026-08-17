package text

import "core:testing"

@(test)
test_truncate_path_fits :: proc(t: ^testing.T) {
	// Whole path within budget — returned unchanged.
	got := truncate_path("/home/user/proj", 64, context.temp_allocator)
	testing.expect_value(t, got, "/home/user/proj")
}

@(test)
test_truncate_path_folds :: proc(t: ^testing.T) {
	// Overflows 10 bytes: keep the trailing segment, fold ancestors into "…/".
	got := truncate_path("/home/user/proj", 10, context.temp_allocator)
	testing.expect_value(t, got, "…/proj")
}

@(test)
test_truncate_path_long_segment_bare :: proc(t: ^testing.T) {
	// Trailing segment alone overflows: returned bare (no "…/") for the caller's
	// widget to ellipsize.
	got := truncate_path("/home/verylongsegmentname", 10, context.temp_allocator)
	testing.expect_value(t, got, "verylongsegmentname")
}
