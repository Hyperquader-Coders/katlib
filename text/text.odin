// Package text is part of katlib — reusable, toolkit-free helpers shared across
// the kat-family apps. Display/formatting utilities with no Odin `core` or Go
// stdlib analogue (so they don't belong in Amber LIB); core-only so they stay
// unit-testable headless. See ../README.md.
package text

import "core:fmt"
import "core:strings"

// truncate_path shortens a "/"-separated path to fit max_len bytes for display:
// it keeps as many trailing segments as fit and folds the hidden ancestors into
// a leading "…/". When the whole path fits it is returned unchanged; when even
// the trailing segment overflows, that segment is returned bare (no "…/") so the
// caller's widget can ellipsize it. The result is allocated with `allocator`.
truncate_path :: proc(path: string, max_len: int, allocator := context.temp_allocator) -> string {
	if len(path) <= max_len {
		return strings.clone(path, allocator)
	}
	segs := strings.split(path, "/", context.temp_allocator)
	out := ""
	#reverse for seg in segs {
		if seg == "" {
			continue
		}
		candidate := fmt.tprintf("%s/%s", seg, out) if out != "" else seg
		if len(candidate) + 2 > max_len {
			// Even the trailing segment overflows: return it bare so the caller
			// (or its widget) can ellipsize, rather than a name-less "…/".
			if out == "" {
				return strings.clone(seg, allocator)
			}
			break
		}
		out = candidate
	}
	return fmt.aprintf("…/%s", out, allocator = allocator)
}
