package launcher

import win "core:sys/windows"

// the bytes free for this user on the disk that holds path (ok false: not known)
disk_free :: proc(path: string) -> (bytes: u64, ok: bool) {
	avail, total, free: win.ULARGE_INTEGER
	if !win.GetDiskFreeSpaceExW(win.utf8_to_wstring(path, context.temp_allocator), &avail, &total, &free) {return 0, false}
	return u64(avail), true
}
