#+build linux, darwin
package launcher

import "core:strings"
import "core:sys/posix"

// the bytes free for this user on the disk that holds path (ok false: not known)
disk_free :: proc(path: string) -> (bytes: u64, ok: bool) {
	st: posix.statvfs_t
	if posix.statvfs(strings.clone_to_cstring(path, context.temp_allocator), &st) != .OK {return 0, false}
	return u64(st.f_bavail) * u64(st.f_frsize), true
}
