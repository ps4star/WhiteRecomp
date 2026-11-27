#+build !linux
package launcher

import "core:os"

// (Linux only: hd_flush_linux.odin)
flush_to_disk :: proc(_: ^os.File) {}
