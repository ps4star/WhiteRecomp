// "As AppImage": the built Linux game as one file, WhiteRecomp-<arch>.AppImage, instead of the plain program.
// An AppImage is the AppImage runtime (third_party/appimage: a static loader for the target's CPU, carried in the
// bundle's appimage/) with a squashfs image appended. Its root is an AppDir:
//   AppRun                    starts the game (a shell script, written below)
//   whiterecomp.desktop       name and icon for desktops
//   whiterecomp.png, .DirIcon the icon (appimage_icon.png)
//   usr/bin/WhiteRecomp       the game, and its WhiteRecomp.cfg beside it (read by the runtime: xrc_rt.c load_cfg)
// The image is made by mksquashfs (squashfs-tools) when this computer has it (compressed: zstd, else gzip), else by
// the writer below (squashfs 4.0, nothing compressed: works on every computer, the file is ~3x larger).
// Home tab (Linux launchers): the game for this computer, Run starts the AppImage; its .cfg has this computer's paths.
// Cross-Compile tab (Linux targets): a portable one -- AppRun points the game at FINAL FANTASY XIII/ and the saves at
// cdrive/ beside the .AppImage (the image itself is read-only).
package launcher

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

APPIMAGE_ICON :: #load("appimage_icon.png")

// whether a Build makes an AppImage: the Home tab's switch (Linux launchers), the Cross-Compile tab's (Linux targets)
appimage_on :: proc(spec: Build_Spec = {}) -> bool {
	if x := spec.cross; x != nil {return !x.android && settings.cross_appimage}
	return ODIN_OS == .Linux && settings.appimage
}

// the runtime's CPU name: the target's (aarch64-linux-gnu -> aarch64), else this computer's
appimage_arch :: proc(spec: Build_Spec = {}) -> string {
	if x := spec.cross; x != nil {
		arch, _, _ := strings.partition(x.triple, "-")
		return arch
	}
	return ODIN_ARCH == .arm64 ? "aarch64" : "x86_64"
}

appimage_file :: proc(arch: string) -> string {return fmt.tprintf("%s-%s.AppImage", GAME_NAME, arch)}

// AppRun. portable: the game's install, saves and pipeline cache beside the .AppImage (a cross build); else the .cfg's
// paths (this computer's). Either way the environment wins, and it runs in the .AppImage's folder (the Vulkan
// pipeline cache, vk_pipelines.bin, is written to the current folder).
@(private = "file")
apprun_text :: proc(portable: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "#!/bin/sh\n# WhiteRecomp's AppImage: written by the WhiteRecomp launcher.\n")
	strings.write_string(&b, "HERE=\"$(dirname \"$(readlink -f \"$0\")\")\"\n")
	strings.write_string(&b, "OUT=\"$(dirname \"${APPIMAGE:-$HERE/x}\")\"\n")
	if portable {
		strings.write_string(&b, `# the game's install, its saves (cdrive) and its pipeline cache: beside the .AppImage (the environment wins)
: "${XRC_GAME_DIR:=$OUT/FINAL FANTASY XIII}"
: "${XRC_EXE:=$XRC_GAME_DIR/white_data/prog/win/bin/ffxiiiimg.exe}"
: "${XRC_CDRIVE:=$OUT/cdrive}"
export XRC_GAME_DIR XRC_EXE XRC_CDRIVE
if [ ! -f "$XRC_EXE" ]; then
	echo "WhiteRecomp: the game is not at $XRC_GAME_DIR" >&2
	echo "Copy your \"FINAL FANTASY XIII\" folder (the one with white_data in it) next to the AppImage, or set XRC_GAME_DIR." >&2
	exit 1
fi
mkdir -p "$XRC_CDRIVE"
`)
	}
	strings.write_string(&b, "cd \"$OUT\" || exit 1\n")
	fmt.sbprintf(&b, "exec \"$HERE/usr/bin/%s\" \"$@\"\n", GAME_NAME)
	return strings.to_string(b)
}

@(private = "file")
DESKTOP :: "[Desktop Entry]\nType=Application\nName=WhiteRecomp\nComment=FINAL FANTASY XIII, recompiled\nExec=WhiteRecomp\nIcon=whiterecomp\nTerminal=false\nCategories=Game;\n"

App_File :: struct {
	path: string, // '/' separated, from the image's root
	data: []u8,
	exec: bool,
}

// Packs the linked game (exe) and its .cfg text into out (the .AppImage, replaced only when it is complete).
appimage_pack :: proc(t: ^Task, out, exe, cfg: string, arch: string, portable: bool) -> bool {
	set_status(t, 0.97, "Packing the AppImage")
	if bundle_extract(t, data_dir, {"appimage/"}) < 0 {return false}
	rt, rerr := os.read_entire_file(data_path("appimage", fmt.tprintf("runtime-%s", arch)), context.allocator)
	if rerr != nil {
		logf(t, "This launcher carries no AppImage runtime for %s.", arch)
		return false
	}
	defer delete(rt)
	game, gerr := os.read_entire_file(exe, context.allocator)
	if gerr != nil {
		logf(t, "Cannot read %s.", exe)
		return false
	}
	defer delete(game)
	files := make([dynamic]App_File, context.temp_allocator)
	append(&files,
		App_File{"AppRun", transmute([]u8)apprun_text(portable), true},
		App_File{"whiterecomp.desktop", transmute([]u8)string(DESKTOP), false},
		App_File{"whiterecomp.png", APPIMAGE_ICON, false},
		App_File{".DirIcon", APPIMAGE_ICON, false},
		App_File{fmt.tprintf("usr/bin/%s", GAME_NAME), game, true},
		App_File{fmt.tprintf("usr/bin/%s.cfg", GAME_NAME), transmute([]u8)cfg, false},
	)
	// (ARM64: Steam's x86-64 helper beside the game -- where the game looks for it: src/runtime/host_steam.c)
	if arch == "aarch64" {
		if h, hok := bundle_read(STEAMHELPER_LINUX, context.temp_allocator); hok {append(&files, App_File{"usr/bin/steamhelper_linux_x64", h, true})}
	}
	img, how, ok := squashfs_mksquashfs(t, files[:])
	if !ok {
		img = squashfs_write(files[:])
		how = "not compressed: install squashfs-tools (mksquashfs) for a smaller file"
	}
	defer delete(img)
	tmp := strings.concatenate({out, ".tmp"}, context.temp_allocator)
	f, ferr := os.open(tmp, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
	if ferr != nil {
		logf(t, "Cannot write %s.", tmp)
		return false
	}
	_, e1 := os.write(f, rt)
	_, e2 := os.write(f, img)
	os.close(f)
	if e1 != nil || e2 != nil {
		_ = os.remove(tmp)
		logf(t, "Cannot write %s.", tmp)
		return false
	}
	when ODIN_OS != .Windows {_ = os.chmod(tmp, {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other})}
	_ = os.remove(out)
	if os.rename(tmp, out) != nil {
		logf(t, "Cannot write %s.", out)
		return false
	}
	logf(t, "AppImage: %s (%.0f MB, %s)", out, f64(len(rt) + len(img)) / 1e6, how)
	return true
}

// ---------------------------------------------------------------------------------------------- mksquashfs
// The AppDir staged in the data folder, packed by this computer's mksquashfs (zstd, else gzip for an old one). ok
// false when there is none or it fails: the writer below makes the image then.
@(private = "file")
squashfs_mksquashfs :: proc(t: ^Task, files: []App_File) -> (img: []u8, how: string, ok: bool) {
	when ODIN_OS == .Windows {return nil, "", false}
	mk := find_program("mksquashfs")
	if mk == "" {return nil, "", false}
	stage := data_path("appimage", "AppDir")
	sqfs := data_path("appimage", "image.sqfs")
	_ = os.remove_all(stage)
	defer _ = os.remove_all(stage)
	defer _ = os.remove(sqfs)
	for fl in files {
		p := pjoin({stage, fl.path})
		if dir := p[:strings.last_index_byte(p, '/')]; dir != "" {_ = os.make_directory_all(dir)}
		if os.write_entire_file(p, fl.data) != nil {return nil, "", false}
		mode: os.Permissions = {.Read_User, .Write_User, .Read_Group, .Read_Other}
		if fl.exec {mode += {.Execute_User, .Execute_Group, .Execute_Other}}
		_ = os.chmod(p, mode)
	}
	for comp in ([]string{"zstd", "gzip"}) {
		_ = os.remove(sqfs)
		code, started := run(t, {mk, stage, sqfs, "-root-owned", "-noappend", "-no-progress", "-comp", comp, "-b", "1M"}, mode = .Quiet)
		if !started {return nil, "", false}
		if code != 0 {continue}
		d, err := os.read_entire_file(sqfs, context.allocator)
		if err != nil {return nil, "", false}
		return d, fmt.tprintf("%s, packed by mksquashfs", comp), true
	}
	return nil, "", false
}

// ---------------------------------------------------------------------------------------------- squashfs writer
// A squashfs 4.0 image of files (and the directories their paths make), every block stored uncompressed: the
// superblock flags say so (data, inodes, ids), every data block's size has the "uncompressed" bit (1 << 24), every
// metadata block's header 0x8000. No fragments (a file's last, short block is a block of its own), no xattrs, no
// export table; all owned by root (one id: 0). Layout: superblock, the files' data, the inode table, the directory
// table, the id table (one metadata block) and its index (one u64).
// Inodes are numbered in the order they are written: a directory's children (subdirectories depth first) before the
// directory, the root last. An inode reference is (metadata block start << 16) | offset in the block; uncompressed
// blocks hold 8192 bytes each behind a 2-byte header, so a position in the table maps to its block directly.
@(private = "file")
SQ_BLOCK :: 128 * 1024

@(private = "file")
Sq_Node :: struct {
	name:   string,
	file:   int, // index into files, -1 for a directory
	kids:   [dynamic]int,
	ino:    u32,
	ref:    u64, // its inode's reference
	nsub:   u32, // subdirectories
	blocks: u32, // its data's start (a file)
}

@(private = "file")
sq_meta_pos :: proc(k: int) -> (block: u32, offset: u16) {return u32(k / 8192 * 8194), u16(k % 8192)}

@(private = "file")
put_u16 :: proc(b: ^[dynamic]u8, v: u16) {append(b, u8(v), u8(v >> 8))}
@(private = "file")
put_u32 :: proc(b: ^[dynamic]u8, v: u32) {append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))}
@(private = "file")
put_u64 :: proc(b: ^[dynamic]u8, v: u64) {put_u32(b, u32(v)); put_u32(b, u32(v >> 32))}

// a metadata table: its bytes in uncompressed blocks of up to 8192
@(private = "file")
sq_put_meta :: proc(out: ^[dynamic]u8, table: []u8) {
	for i := 0; i < len(table); i += 8192 {
		n := min(8192, len(table) - i)
		put_u16(out, u16(n) | 0x8000)
		append(out, ..table[i:i + n])
	}
}

squashfs_write :: proc(files: []App_File) -> []u8 {
	nodes := make([dynamic]Sq_Node, context.temp_allocator)
	append(&nodes, Sq_Node{file = -1}) // (the root)
	child :: proc(nodes: ^[dynamic]Sq_Node, dir: int, name: string, file: int) -> int {
		for k in nodes[dir].kids {if nodes[k].name == name {return k}}
		append(nodes, Sq_Node{name = name, file = file})
		append(&nodes[dir].kids, len(nodes) - 1)
		return len(nodes) - 1
	}
	for fl, i in files {
		parts := strings.split(fl.path, "/", context.temp_allocator)
		d := 0
		for p, j in parts {d = child(&nodes, d, p, j == len(parts) - 1 ? i : -1)}
	}
	Ctx :: struct {
		nodes:             ^[dynamic]Sq_Node,
		files:             []App_File,
		out, inodes, dirs: [dynamic]u8,
		next, mtime:       u32,
	}
	c := Ctx{nodes = &nodes, files = files, mtime = u32(time.time_to_unix(time.now()))}
	c.out = make([dynamic]u8, 96, context.allocator) // (the superblock, filled in last)
	c.inodes = make([dynamic]u8, context.temp_allocator)
	c.dirs = make([dynamic]u8, context.temp_allocator)
	// sort every directory's entries by name (squashfs looks names up in order)
	for &n in nodes {
		kids := n.kids[:]
		for i in 1 ..< len(kids) {
			for j := i; j > 0 && nodes[kids[j]].name < nodes[kids[j - 1]].name; j -= 1 {kids[j], kids[j - 1] = kids[j - 1], kids[j]}
		}
	}
	// inode numbers in writing order (children first), and the files' data
	number :: proc(c: ^Ctx, d: int) {
		for k in c.nodes[d].kids {
			if c.nodes[k].file < 0 {
				number(c, k)
				c.nodes[d].nsub += 1
			} else {
				c.next += 1
				c.nodes[k].ino = c.next
				c.nodes[k].blocks = u32(len(c.out))
				append(&c.out, ..c.files[c.nodes[k].file].data)
			}
		}
		c.next += 1
		c.nodes[d].ino = c.next
	}
	number(&c, 0)
	count := c.next
	// the inodes and directory listings
	inode_header :: proc(c: ^Ctx, kind: u16, perm: u16, ino: u32) {
		put_u16(&c.inodes, kind)
		put_u16(&c.inodes, perm)
		put_u16(&c.inodes, 0) // uid: ids[0]
		put_u16(&c.inodes, 0) // gid
		put_u32(&c.inodes, c.mtime)
		put_u32(&c.inodes, ino)
	}
	write_dir :: proc(c: ^Ctx, d: int, parent: u32) {
		for k in c.nodes[d].kids {
			n := &c.nodes[k]
			if n.file < 0 {
				write_dir(c, k, c.nodes[d].ino)
				continue
			}
			blk, off := sq_meta_pos(len(c.inodes))
			n.ref = u64(blk) << 16 | u64(off)
			fl := c.files[n.file]
			inode_header(c, 2, fl.exec ? 0o755 : 0o644, n.ino) // (basic file)
			put_u32(&c.inodes, n.blocks)
			put_u32(&c.inodes, 0xffffffff) // no fragment
			put_u32(&c.inodes, 0)
			put_u32(&c.inodes, u32(len(fl.data)))
			for i := 0; i < len(fl.data); i += SQ_BLOCK {put_u32(&c.inodes, u32(min(SQ_BLOCK, len(fl.data) - i)) | 1 << 24)}
		}
		// the listing: runs of entries whose inodes share a metadata block (at most 256 each)
		start := len(c.dirs)
		kids := c.nodes[d].kids[:]
		for i := 0; i < len(kids); {
			first := &c.nodes[kids[i]]
			j := i
			for j < len(kids) && j - i < 256 && c.nodes[kids[j]].ref >> 16 == first.ref >> 16 && abs(i64(c.nodes[kids[j]].ino) - i64(first.ino)) < 32767 {j += 1}
			put_u32(&c.dirs, u32(j - i - 1))
			put_u32(&c.dirs, u32(first.ref >> 16))
			put_u32(&c.dirs, first.ino)
			for k in kids[i:j] {
				n := c.nodes[k]
				put_u16(&c.dirs, u16(n.ref & 0xffff))
				put_u16(&c.dirs, u16(i16(i64(n.ino) - i64(first.ino))))
				put_u16(&c.dirs, n.file < 0 ? 1 : 2)
				put_u16(&c.dirs, u16(len(n.name) - 1))
				append(&c.dirs, ..transmute([]u8)n.name)
			}
			i = j
		}
		dblk, doff := sq_meta_pos(start)
		blk, off := sq_meta_pos(len(c.inodes))
		c.nodes[d].ref = u64(blk) << 16 | u64(off)
		inode_header(c, 1, 0o755, c.nodes[d].ino) // (basic directory)
		put_u32(&c.inodes, dblk)
		put_u32(&c.inodes, 2 + c.nodes[d].nsub)
		put_u16(&c.inodes, u16(len(c.dirs) - start + 3))
		put_u16(&c.inodes, doff)
		put_u32(&c.inodes, parent)
	}
	write_dir(&c, 0, count + 1) // (the root's parent: the inode count + 1)
	inode_start := u64(len(c.out))
	sq_put_meta(&c.out, c.inodes[:])
	dir_start := u64(len(c.out))
	sq_put_meta(&c.out, c.dirs[:])
	ids_block := u64(len(c.out))
	put_u16(&c.out, 4 | 0x8000)
	put_u32(&c.out, 0) // (the one id: root)
	id_start := u64(len(c.out))
	put_u64(&c.out, ids_block)
	used := u64(len(c.out))
	for len(c.out) % 4096 != 0 {append(&c.out, 0)}
	// the superblock
	sb := make([dynamic]u8, context.temp_allocator)
	put_u32(&sb, 0x73717368) // "hsqs"
	put_u32(&sb, count)
	put_u32(&sb, c.mtime)
	put_u32(&sb, SQ_BLOCK)
	put_u32(&sb, 0) // fragments
	put_u16(&sb, 1) // compression: gzip (none is used)
	put_u16(&sb, 17) // log2 of the block size
	put_u16(&sb, 0x0001 | 0x0002 | 0x0008 | 0x0010 | 0x0200 | 0x0800) // uncompressed inodes, data, fragments, ids; no fragments, no xattrs
	put_u16(&sb, 1) // ids
	put_u16(&sb, 4)
	put_u16(&sb, 0)
	put_u64(&sb, c.nodes[0].ref)
	put_u64(&sb, used)
	put_u64(&sb, id_start)
	put_u64(&sb, 0xffffffffffffffff) // xattr id table: none
	put_u64(&sb, inode_start)
	put_u64(&sb, dir_start)
	put_u64(&sb, 0xffffffffffffffff) // fragment table: none
	put_u64(&sb, 0xffffffffffffffff) // export table: none
	copy(c.out[:96], sb[:])
	return c.out[:]
}
