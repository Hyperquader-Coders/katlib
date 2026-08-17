package crash

import "core:testing"

// write_u64 is the only formatting the fatal handler can do, and it is hand-rolled because
// fmt is not async-signal-safe. A wrong digit order or a dropped zero would corrupt every
// crash line silently, so the cases that bite — 0, a single digit, a trailing zero, and the
// u64 maximum — are pinned here.
@(test)
test_write_u64 :: proc(t: ^testing.T) {
	cases := []struct {
		v:    u64,
		want: string,
	} {
		{0, "0"},
		{7, "7"},
		{10, "10"},
		{100, "100"},
		{43220, "43220"},
		{1786621820, "1786621820"},
		{18446744073709551615, "18446744073709551615"},
	}
	for cs in cases {
		buf: [20]u8
		n := write_u64(buf[:], cs.v)
		got := string(buf[:n])
		testing.expectf(t, got == cs.want, "write_u64(%d) = %q, want %q", cs.v, got, cs.want)
	}
}
