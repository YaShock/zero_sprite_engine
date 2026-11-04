package engine

import win "core:sys/windows"

// Resident memory (working set) in bytes.
@(private)
read_rss :: proc() -> int {
	counters: win.PROCESS_MEMORY_COUNTERS
	if !win.GetProcessMemoryInfo(win.GetCurrentProcess(), &counters, size_of(counters)) {
		return 0
	}
	return int(counters.WorkingSetSize)
}

// User + kernel CPU time of the process in 100 ns ticks.
@(private)
read_cpu_ticks :: proc() -> int {
	creation, exit, kernel, user: win.FILETIME
	if !win.GetProcessTimes(win.GetCurrentProcess(), &creation, &exit, &kernel, &user) {
		return 0
	}
	ticks :: proc(t: win.FILETIME) -> int {
		return int(u64(t.dwHighDateTime) << 32 | u64(t.dwLowDateTime))
	}
	return ticks(kernel) + ticks(user)
}

@(private)
cpu_ticks_per_second :: proc() -> int {
	return 10_000_000
}
