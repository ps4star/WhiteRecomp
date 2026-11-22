// The sources the launcher carries: launcher/bundle.bin, made by build/bundle.exe (tools/bundle/bundle.odin has the format),
// embedded at compile time. What is in it: the translated code (gen/src/page_*.c, gen/xrc_table.c), the runtime
// (runtime/), its header (include/xrc.h), the Steam achievements helper (tools/steamhelper.exe) and the movie converter
// (tools/bink2mp4.exe; Windows: with the ffmpeg.exe it
// encodes with, tools/ffmpeg.exe, GPL: third_party/ffmpeg_exe). Nothing of the game itself:
// its data comes from the player's own ffxiiiimg.exe and install.
//
// The files are in solid LZMA blocks (a block: files of one folder, up to 32 MB), unpacked by lzma/ (our decoder):
// reading a file unpacks its whole block, so the blocks are unpacked once each, on every core (bundle_extract).
package launcher

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "lzma"

BUNDLE: []u8 = #load("bundle.bin")

Bundle_Entry :: struct {
	path:         string,
	flags, block: u32,
	offset, size: u64,
}
Bundle_Block :: struct {
	size, packed, offset: u64,
}
bundle_entries: [dynamic]Bundle_Entry
bundle_blocks: [dynamic]Bundle_Block

@(private = "file")
le :: proc(b: []u8, o: int, n: int) -> u64 {
	v: u64
	for i in 0 ..< n {v |= u64(b[o + i]) << (8 * uint(i))}
	return v
}

bundle_open :: proc() -> bool {
	b := BUNDLE
	if len(b) < 16 || string(b[:8]) != "FFBUNDL2" {return false}
	nb := int(le(b, 8, 4))
	nf := int(le(b, 12, 4))
	o := 16
	for _ in 0 ..< nb {
		k := Bundle_Block{size = le(b, o, 8), packed = le(b, o + 8, 8), offset = le(b, o + 16, 8)}
		if k.offset + k.packed > u64(len(b)) {return false}
		append(&bundle_blocks, k)
		o += 24
	}
	for _ in 0 ..< nf {
		pl := int(le(b, o, 2))
		e := Bundle_Entry{path = string(b[o + 2:o + 2 + pl])}
		o += 2 + pl
		e.flags = u32(le(b, o, 4))
		e.block = u32(le(b, o + 4, 4))
		e.offset = le(b, o + 8, 8)
		e.size = le(b, o + 16, 8)
		o += 24
		if int(e.block) >= nb || e.offset + e.size > bundle_blocks[e.block].size {return false}
		append(&bundle_entries, e)
	}
	return true
}

bundle_has :: proc(path: string) -> bool {
	for e in bundle_entries {if e.path == path {return true}}
	return false
}

// One block, unpacked (in the allocator).
@(private = "file")
block_read :: proc(bi: u32, allocator := context.allocator) -> (data: []u8, ok: bool) {
	k := bundle_blocks[bi]
	data = make([]u8, int(k.size), allocator)
	if !lzma.decode(BUNDLE[k.offset:k.offset + k.packed], data) {
		delete(data, allocator)
		return nil, false
	}
	return data, true
}

// One file of the bundle, unpacked (in the allocator).
bundle_read :: proc(path: string, allocator := context.allocator) -> (data: []u8, ok: bool) {
	for e in bundle_entries {
		if e.path != path {continue}
		blk := block_read(e.block, context.allocator) or_return
		defer delete(blk)
		return slice.clone(blk[e.offset:e.offset + e.size], allocator), true
	}
	return nil, false
}

// Unpacks every file whose path starts with one of prefixes into dir (keeping its path), a block per core. A file that
// is already there with the same contents is left alone (its time stays, so an incremental build keeps its object).
// Returns the number written, or -1 on an error.
bundle_extract :: proc(t: ^Task, dir: string, prefixes: []string) -> int {
	Job :: struct {
		t:        ^Task,
		dir:      string,
		sel:      []Bundle_Entry,
		blocks:   []u32,
		next:     int,
		done:     int,
		written:  int,
		failed:   bool,
		mutex:    sync.Mutex,
		err_path: string,
	}
	sel := make([dynamic]Bundle_Entry, context.temp_allocator)
	blocks := make([dynamic]u32, context.temp_allocator)
	for e in bundle_entries {
		for p in prefixes {
			if strings.has_prefix(e.path, p) {
				append(&sel, e)
				if !slice.contains(blocks[:], e.block) {append(&blocks, e.block)}
				break
			}
		}
	}
	// every folder made here first: the workers creating the same folder at once failed now and then (one of them saw
	// it half made, and its file could not be written)
	{
		context.allocator = context.temp_allocator // (the folder names: filepath.dir allocates)
		made := make(map[string]bool)
		for e in sel {
			d := filepath.dir(pjoin({dir, e.path}))
			if d in made {continue}
			made[d] = true
			_ = os.make_directory_all(d)
		}
	}
	// (the biggest blocks first: the last one to finish is a small one)
	slice.sort_by(blocks[:], proc(a, b: u32) -> bool {return bundle_blocks[a].size > bundle_blocks[b].size})
	job := Job{t = t, dir = dir, sel = sel[:], blocks = blocks[:]}
	worker :: proc(th: ^thread.Thread) {
		j := (^Job)(th.data)
		for !cancelled(j.t) {
			k := sync.atomic_add(&j.next, 1)
			if k >= len(j.blocks) {return}
			bi := j.blocks[k]
			blk, ok := block_read(bi)
			for e in j.sel {
				if e.block != bi {continue}
				if ok {
					data := blk[e.offset:e.offset + e.size]
					dst := pjoin({j.dir, e.path})
					old, rerr := os.read_entire_file(dst, context.allocator)
					same := rerr == nil && len(old) == len(data) && string(old) == string(data)
					delete(old)
					if !same {
						werr := os.write_entire_file(dst, data)
						if werr != nil { 	// (its folder made again, once)
							_ = os.make_directory_all(filepath.dir(dst))
							werr = os.write_entire_file(dst, data)
						}
						if werr != nil {
							ok = false
						} else {
							when ODIN_OS != .Windows {
								if e.flags & 1 != 0 {_ = os.chmod(dst, {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other})}
							}
							sync.atomic_add(&j.written, 1)
						}
					}
				}
				if !ok {
					sync.mutex_lock(&j.mutex)
					j.failed = true
					j.err_path = e.path
					sync.mutex_unlock(&j.mutex)
					break
				}
				d := sync.atomic_add(&j.done, 1) + 1
				set_status(j.t, f32(d) / f32(len(j.sel)) * 0.1, "Unpacking the sources: %d of %d", d, len(j.sel))
				free_all(context.temp_allocator)
			}
			delete(blk)
		}
	}
	threads := make([dynamic]^thread.Thread, context.temp_allocator)
	for _ in 0 ..< max(1, min(len(blocks), os.get_processor_core_count())) {
		th := thread.create(worker)
		th.data = &job
		th.init_context = context
		thread.start(th)
		append(&threads, th)
	}
	for th in threads {thread.join(th); thread.destroy(th)}
	if job.failed {
		logf(t, "Could not unpack %s into %s", job.err_path, dir)
		return -1
	}
	return job.written
}

// Deletes the files under dir/<prefix> (each of prefixes) that the bundle does not have: the sources an older bundle
// unpacked that this one dropped (a Build compiles every page in the folder). Returns how many were deleted.
bundle_prune :: proc(t: ^Task, dir: string, prefixes: []string) -> int {
	context.allocator = context.temp_allocator
	have := make(map[string]bool)
	for e in bundle_entries {have[e.path] = true}
	n := 0
	walk :: proc(t: ^Task, dir, rel: string, have: ^map[string]bool, n: ^int) {
		list, err := os.read_all_directory_by_path(pjoin({dir, rel}), context.temp_allocator)
		if err != nil {return}
		for e in list {
			r := strings.concatenate({rel, e.name})
			if e.type == .Directory {
				walk(t, dir, strings.concatenate({r, "/"}), have, n)
			} else if !(r in have^) {
				if os.remove(e.fullpath) == nil {n^ += 1} else {logf(t, "Could not delete the old source %s", e.fullpath)}
			}
		}
	}
	for p in prefixes {walk(t, dir, p, &have, &n)}
	return n
}

// the bundle's identity: a hash of its bytes, made once (2026-11-22). A game built by another launcher -- an older
// release, before a fix -- is not offered to Run until it is built again (main.odin built_game): players updated the
// launcher, pressed Run, and went on playing their old build and its bugs (the 10-minute "too many voices" stop).
bundle_hash: u64
bundle_identity :: proc() -> u64 {
	if bundle_hash != 0 {return bundle_hash}
	h: u64 = 0xcbf29ce484222325 // (FNV-1a, 4 lanes: ~75 MB in a few tens of ms)
	l: [4]u64 = {h, h ~ 1, h ~ 2, h ~ 3}
	b := BUNDLE
	n := len(b) &~ 3
	for i := 0; i < n; i += 4 {
		l[0] = (l[0] ~ u64(b[i])) * 0x100000001b3
		l[1] = (l[1] ~ u64(b[i + 1])) * 0x100000001b3
		l[2] = (l[2] ~ u64(b[i + 2])) * 0x100000001b3
		l[3] = (l[3] ~ u64(b[i + 3])) * 0x100000001b3
	}
	for i in n ..< len(b) {l[0] = (l[0] ~ u64(b[i])) * 0x100000001b3}
	h = l[0] ~ (l[1] << 1 | l[1] >> 63) ~ (l[2] << 2 | l[2] >> 62) ~ (l[3] << 3 | l[3] >> 61) ~ u64(len(b))
	if h == 0 {h = 1}
	bundle_hash = h
	return h
}
