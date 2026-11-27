package launcher

import "core:os"
import "core:sys/linux"

// what was written to out so far pushed to the disk (hd.odin: a slow disk otherwise gathers gigabytes of unwritten
// pages in RAM until the kernel stalls every writer)
flush_to_disk :: proc(out: ^os.File) {_ = linux.fdatasync(linux.Fd(os.fd(out)))}
