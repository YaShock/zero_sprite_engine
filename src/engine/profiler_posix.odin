#+build !windows
package engine

import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

// Resident memory in bytes, from /proc/self/statm (Linux; 0 elsewhere).
@(private)
read_rss :: proc() -> int {
	data, err := os.read_entire_file("/proc/self/statm", context.temp_allocator)
	if err != nil {
		return 0
	}
	fields := strings.fields(string(data), context.temp_allocator)
	if len(fields) < 2 {
		return 0
	}
	pages := strconv.parse_int(fields[1]) or_else 0
	return pages * int(posix.sysconf(._PAGE_SIZE))
}

// User + system CPU time of the process in clock ticks, from /proc/self/stat.
@(private)
read_cpu_ticks :: proc() -> int {
	data, err := os.read_entire_file("/proc/self/stat", context.temp_allocator)
	if err != nil {
		return 0
	}
	s := string(data)
	// Fields after the command name, which is parenthesized and may contain spaces.
	fields := strings.fields(s[strings.last_index_byte(s, ')') + 1:], context.temp_allocator)
	if len(fields) < 13 {
		return 0
	}
	return (strconv.parse_int(fields[11]) or_else 0) + (strconv.parse_int(fields[12]) or_else 0)
}

@(private)
cpu_ticks_per_second :: proc() -> int {
	return int(posix.sysconf(._CLK_TCK))
}
