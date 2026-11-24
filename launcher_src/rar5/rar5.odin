// RAR5 reading (the archives WinRAR 5+ writes: "Rar!\x1a\x07\x01\x00"), for mods shipped as .rar (launcher/hd.odin).
//
// list: the archive's file headers. extract: one file, whole, into memory -- the output buffer is also the dictionary
// (no window: a match copies from earlier in the output), the filters (E8, E8E9, ARM, DELTA) applied at the end to
// their ranges (the matches read the unfiltered data, as in unrar, and every match is decoded by then). Follows the
// format of RARLAB's technote and unrar's unpack50.cpp (its decoding, rewritten). Not supported: solid archives,
// encryption, multi-volume archives, RAR 7's larger distances (algorithm version 1) -- list says which. A corrupt
// stream returns false; it never reads or writes out of bounds; the data's CRC32 is checked when the header has one.
package rar5

import "core:hash"
import "core:os"

Entry :: struct {
	name:     string,
	usize:    u64, // unpacked
	psize:    u64, // packed (the data area)
	data_off: i64, // the data area's offset in the archive
	method:   int, // 0 stored, 1..5 compressed
	version:  int, // the algorithm version (0: RAR5)
	dir:      bool,
	solid:    bool,
	split:    bool, // continues in another volume
	crypt:    bool,
	has_crc:  bool,
	crc:      u32,
}

SIGNATURE :: [8]u8{0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x01, 0x00}

// why the last extract failed (for the log)
last_error: string

@(private)
vint :: proc(b: []u8, o: ^int) -> (v: u64, ok: bool) {
	for s: uint = 0; s < 70; s += 7 {
		if o^ >= len(b) {return}
		c := b[o^]
		o^ += 1
		v |= u64(c & 0x7f) << s
		if c & 0x80 == 0 {return v, true}
	}
	return
}

// the archive's files (and folders: dir); ok false if it is not a RAR5 archive, or a header is damaged or encrypted
list :: proc(f: ^os.File, allocator := context.allocator) -> (entries: [dynamic]Entry, ok: bool) {
	size, serr := os.file_size(f)
	if serr != nil || size < 8 {return}
	sig: [8]u8
	if n, err := os.read_at(f, sig[:], 0); err != nil || n != 8 || sig != SIGNATURE {return}
	entries = make([dynamic]Entry, allocator)
	hb := make([dynamic]u8, context.temp_allocator)
	pos: i64 = 8
	for pos < size {
		pre: [7]u8
		n, _ := os.read_at(f, pre[:], pos)
		if n < 5 {return entries, false}
		o := 4
		hsize, hok := vint(pre[:n], &o)
		if !hok || hsize == 0 || hsize > 2 << 20 {return entries, false}
		hstart := pos + i64(o)
		resize(&hb, int(hsize))
		if m, err := os.read_at(f, hb[:], hstart); err != nil || m != int(hsize) {return entries, false}
		h := hb[:]
		if hash.crc32(h, hash.crc32(pre[4:o])) != u32(pre[0]) | u32(pre[1]) << 8 | u32(pre[2]) << 16 | u32(pre[3]) << 24 {return entries, false}
		p := 0
		typ, _ := vint(h, &p)
		flags, _ := vint(h, &p)
		extra, data: u64
		if flags & 1 != 0 {extra, _ = vint(h, &p)}
		if flags & 2 != 0 {data, _ = vint(h, &p)}
		switch typ {
		case 2: // a file
			e: Entry
			ff, _ := vint(h, &p)
			e.usize, _ = vint(h, &p)
			_, _ = vint(h, &p) // attributes
			if ff & 2 != 0 {p += 4} // (mtime)
			if ff & 4 != 0 {
				if p + 4 > len(h) {return entries, false}
				e.has_crc = true
				e.crc = u32(h[p]) | u32(h[p + 1]) << 8 | u32(h[p + 2]) << 16 | u32(h[p + 3]) << 24
				p += 4
			}
			ci, _ := vint(h, &p)
			_, _ = vint(h, &p) // host OS
			nl, _ := vint(h, &p)
			if p + int(nl) > len(h) {return entries, false}
			e.name = string(h[p:p + int(nl)])
			e.name = clone_name(e.name, allocator)
			e.dir = ff & 1 != 0
			e.version = int(ci & 0x3f)
			e.solid = ci & 0x40 != 0
			e.method = int((ci >> 7) & 7)
			e.psize = data
			e.data_off = hstart + i64(hsize)
			e.split = flags & 0x18 != 0
			if extra > 0 && extra <= hsize { // (the extra area: records; type 1 = encryption)
				q := int(hsize - extra)
				for q < len(h) {
					rs, rok := vint(h, &q)
					if !rok {break}
					r0 := q
					rt, _ := vint(h, &q)
					if rt == 1 {e.crypt = true}
					q = r0 + int(rs)
				}
			}
			append(&entries, e)
		case 4: return entries, false // (the headers encrypted)
		case 5: return entries, true // (the end)
		}
		pos = hstart + i64(hsize) + i64(data)
	}
	return entries, true
}

@(private)
clone_name :: proc(s: string, allocator := context.allocator) -> string {
	b := make([]u8, len(s), allocator)
	copy(b, s)
	for &c in b {if c == '\\' {c = '/'}}
	return string(b)
}

// ---------------------------------------------------------------------------------------------- decoding

@(private)
NC :: 306
@(private)
DC :: 64
@(private)
LDC :: 16
@(private)
RC :: 44
@(private)
BC :: 20
@(private)
QUICK :: 10

@(private)
Dec :: struct {
	max:        int,
	len:        [16]u32, // DecodeLen: left-aligned upper limits
	pos:        [16]u32, // DecodePos
	quick_len:  [1 << QUICK]u8,
	quick_num:  [1 << QUICK]u16,
	num:        [NC]u16,
}

@(private)
Bits :: struct {
	b:   []u8, // (padded: 16 zero bytes past the data)
	n:   int, // the data's length
	a:   int, // byte
	bit: uint, // bit in it (0..7)
}

@(private)
get16 :: #force_inline proc(r: ^Bits) -> u32 {
	a := r.a
	v := u32(r.b[a]) << 16 | u32(r.b[a + 1]) << 8 | u32(r.b[a + 2])
	return (v >> (8 - r.bit)) & 0xffff
}
@(private)
get32 :: #force_inline proc(r: ^Bits) -> u32 {
	a := r.a
	v := u32(r.b[a]) << 24 | u32(r.b[a + 1]) << 16 | u32(r.b[a + 2]) << 8 | u32(r.b[a + 3])
	v <<= r.bit
	v |= u32(r.b[a + 4]) >> (8 - r.bit)
	return v
}
@(private)
skip :: #force_inline proc(r: ^Bits, n: uint) {
	t := r.bit + n
	r.a += int(t >> 3)
	r.bit = t & 7
}

@(private)
make_dec :: proc(d: ^Dec, lengths: []u8) {
	count: [16]u32
	d.max = len(lengths)
	for l in lengths {count[l & 15] += 1}
	count[0] = 0
	d.len[0] = 0
	d.pos[0] = 0
	upper: u32 = 0
	for i in 1 ..< 16 {
		upper += count[i]
		d.len[i] = upper << (16 - uint(i))
		upper *= 2
		d.pos[i] = d.pos[i - 1] + count[i - 1]
	}
	cp := d.pos
	for l, s in lengths {
		c := l & 15
		if c != 0 {
			at := cp[c]
			if int(at) < NC {d.num[at] = u16(s)}
			cp[c] += 1
		}
	}
	cur: u32 = 1
	for code in 0 ..< u32(1 << QUICK) {
		field := code << (16 - QUICK)
		for cur < 16 && field >= d.len[cur] {cur += 1}
		d.quick_len[code] = u8(cur)
		if cur < 16 {
			dist := (field - d.len[cur - 1]) >> (16 - cur)
			p := d.pos[cur] + dist
			d.quick_num[code] = int(p) < d.max ? d.num[p] : 0
		} else {
			d.quick_num[code] = 0
		}
	}
}

@(private)
decode :: #force_inline proc(r: ^Bits, d: ^Dec) -> int {
	field := get16(r) & 0xfffe
	if field < d.len[QUICK] {
		code := field >> (16 - QUICK)
		skip(r, uint(d.quick_len[code]))
		return int(d.quick_num[code])
	}
	bits: u32 = 15
	for i in u32(QUICK + 1) ..< 15 {if field < d.len[i] {bits = i; break}}
	skip(r, uint(bits))
	dist := (field - d.len[bits - 1]) >> (16 - bits)
	p := d.pos[bits] + dist
	if int(p) >= d.max {p = 0}
	return int(d.num[p])
}

@(private)
Tables :: struct {
	ld:  Dec,
	dd:  Dec,
	ldd: Dec,
	rd:  Dec,
	bd:  Dec,
}

@(private)
read_tables :: proc(r: ^Bits, t: ^Tables) -> bool {
	bl: [BC]u8
	for i := 0; i < BC; i += 1 {
		if r.a > r.n {return false} // (a small last block: its table may end in the data's last bytes; the padding covers the reads)
		l := u8(get16(r) >> 12)
		skip(r, 4)
		if l == 15 {
			z := u8(get16(r) >> 12)
			skip(r, 4)
			if z == 0 {
				bl[i] = 15
			} else {
				z += 2
				for z > 0 && i < BC {bl[i] = 0; i += 1; z -= 1}
				i -= 1
			}
		} else {
			bl[i] = l
		}
	}
	make_dec(&t.bd, bl[:])
	table: [NC + DC + LDC + RC]u8
	for i := 0; i < len(table); {
		if r.a > r.n {return false}
		num := decode(r, &t.bd)
		if num < 16 {
			table[i] = u8(num)
			i += 1
		} else if num < 18 {
			n: u32
			if num == 16 {n = (get16(r) >> 13) + 3; skip(r, 3)} else {n = (get16(r) >> 9) + 11; skip(r, 7)}
			if i == 0 {return false}
			for n > 0 && i < len(table) {table[i] = table[i - 1]; i += 1; n -= 1}
		} else {
			n: u32
			if num == 18 {n = (get16(r) >> 13) + 3; skip(r, 3)} else {n = (get16(r) >> 9) + 11; skip(r, 7)}
			for n > 0 && i < len(table) {table[i] = 0; i += 1; n -= 1}
		}
	}
	make_dec(&t.ld, table[0:NC])
	make_dec(&t.dd, table[NC:NC + DC])
	make_dec(&t.ldd, table[NC + DC:NC + DC + LDC])
	make_dec(&t.rd, table[NC + DC + LDC:])
	return true
}

@(private)
Block :: struct {
	start, size: int, // (bytes, from start)
	bit_size:    uint, // the valid bits of its last byte
	last:        bool,
	table:       bool,
}

@(private)
read_block_header :: proc(r: ^Bits, h: ^Block) -> bool {
	skip(r, (8 - r.bit) & 7)
	if r.a + 2 > r.n {return false}
	flags := u8(get16(r) >> 8)
	skip(r, 8)
	nb := int((flags >> 3) & 3) + 1
	if nb == 4 {return false}
	saved := u8(get16(r) >> 8)
	skip(r, 8)
	size := 0
	for i in 0 ..< nb {size += int(get16(r) >> 8) << uint(i * 8); skip(r, 8)}
	if u8(0x5a ~ flags ~ u8(size) ~ u8(size >> 8) ~ u8(size >> 16)) != saved {return false}
	h.start = r.a
	h.size = size
	h.bit_size = uint(flags & 7) + 1
	h.last = flags & 0x40 != 0
	h.table = flags & 0x80 != 0
	return h.start + h.size <= r.n
}

@(private)
Filter :: struct {
	start, length: int,
	type:          int, // 0 DELTA, 1 E8, 2 E8E9, 3 ARM
	channels:      int,
}

@(private)
filter_data :: proc(r: ^Bits) -> int {
	n := int(get16(r) >> 14) + 1
	skip(r, 2)
	v := 0
	for i in 0 ..< n {v += int(get16(r) >> 8) << uint(i * 8); skip(r, 8)}
	return v
}

@(private)
slot_len :: #force_inline proc(r: ^Bits, slot: int) -> int {
	if slot < 8 {return 2 + slot}
	lbits := uint(slot / 4 - 1)
	l := 2 + ((4 | (slot & 3)) << lbits)
	l += int(get16(r) >> (16 - lbits))
	skip(r, lbits)
	return l
}

// one file, whole (e from list, f the archive it came from); ok false if unsupported, corrupt or the CRC32 differs
extract :: proc(f: ^os.File, e: Entry, allocator := context.allocator) -> (out: []u8, ok: bool) {
	last_error = ""
	if e.dir || e.crypt || e.split || e.solid || e.version != 0 || e.usize > 1 << 31 || e.psize > 1 << 31 {last_error = "unsupported (encrypted, solid, split or RAR 7)"; return}
	packed := make([]u8, int(e.psize) + 16) // (16 zero bytes: the bit reader reads ahead, a symbol at most 8 bytes) -- (the heap: an import extracts thousands)
	defer delete(packed)
	if n, err := os.read_at(f, packed[:e.psize], e.data_off); err != nil || u64(n) != e.psize {return}
	out = make([]u8, int(e.usize), allocator)
	if e.method == 0 {
		copy(out, packed[:e.psize])
	} else if !unpack(packed, int(e.psize), out) {
		if last_error == "" {last_error = "corrupt data"}
		delete(out, allocator)
		return nil, false
	}
	if e.has_crc && hash.crc32(out) != e.crc {
		last_error = "CRC32 mismatch"
		delete(out, allocator)
		return nil, false
	}
	return out, true
}

@(private)
unpack :: proc(packed: []u8, n: int, out: []u8) -> bool {
	r := Bits{b = packed, n = n}
	t := new(Tables)
	defer free(t)
	filters := make([dynamic]Filter)
	defer delete(filters)
	blk: Block
	if !read_block_header(&r, &blk) {last_error = "bad first block header"; return false}
	if !blk.table || !read_tables(&r, t) {last_error = "bad first tables"; return false}
	have_tables := true
	old: [4]int
	last_len := 0
	o := 0
	for o < len(out) {
		// past the block's end: the next block (or the end of the file)
		for r.a > blk.start + blk.size - 1 || (r.a == blk.start + blk.size - 1 && r.bit >= blk.bit_size) {
			if blk.last {break}
			if !read_block_header(&r, &blk) {last_error = "bad block header"; return false}
			if blk.table {
				if !read_tables(&r, t) {last_error = "bad tables"; return false}
				have_tables = true
			}
		}
		if blk.last && (r.a > blk.start + blk.size - 1 || (r.a == blk.start + blk.size - 1 && r.bit >= blk.bit_size)) {break}
		if r.a > r.n || !have_tables {last_error = "read past the data"; return false}
		slot := decode(&r, &t.ld)
		if slot < 256 {
			out[o] = u8(slot)
			o += 1
			continue
		}
		length, dist := 0, 0
		if slot >= 262 {
			length = slot_len(&r, slot - 262)
			ds := decode(&r, &t.dd)
			dbits: uint = 0
			if ds < 4 {
				dist = 1 + ds
			} else {
				dbits = uint(ds / 2 - 1)
				dist = 1 + ((2 | (ds & 1)) << dbits)
			}
			if dbits > 0 {
				if dbits >= 4 {
					if dbits > 4 {
						dist += int(get32(&r) >> (36 - dbits)) << 4
						skip(&r, dbits - 4)
					}
					dist += decode(&r, &t.ldd)
				} else {
					dist += int(get16(&r) >> (16 - dbits))
					skip(&r, dbits)
				}
			}
			if dist > 0x100 {length += 1}
			if dist > 0x2000 {length += 1}
			if dist > 0x40000 {length += 1}
			old[3] = old[2]; old[2] = old[1]; old[1] = old[0]; old[0] = dist
			last_len = length
		} else if slot == 256 {
			flt: Filter
			flt.start = filter_data(&r)
			flt.length = filter_data(&r)
			flt.type = int(get16(&r) >> 13)
			skip(&r, 3)
			if flt.type == 0 {flt.channels = int(get16(&r) >> 11) + 1; skip(&r, 5)}
			flt.start += o
			if flt.type <= 3 && flt.length <= 0x400000 {append(&filters, flt)}
			continue
		} else if slot == 257 {
			if last_len == 0 {continue}
			length = last_len
			dist = old[0]
		} else {
			k := slot - 258
			dist = old[k]
			for i := k; i > 0; i -= 1 {old[i] = old[i - 1]}
			old[0] = dist
			length = slot_len(&r, decode(&r, &t.rd))
			last_len = length
		}
		if dist <= 0 || dist > o {last_error = "distance before the start"; return false}
		end := min(o + length, len(out))
		for o < end {out[o] = out[o - dist]; o += 1}
	}
	if o != len(out) {last_error = "data ended early"; return false}
	for flt in filters {
		if flt.start < 0 || flt.start + flt.length > len(out) {last_error = "filter out of range"; return false}
		apply_filter(out[flt.start:flt.start + flt.length], flt)
	}
	return true
}

@(private)
apply_filter :: proc(d: []u8, flt: Filter) {
	switch flt.type {
	case 0: // DELTA: the channels stored one after another, each byte the difference from the one before
		tmp := make([]u8, len(d))
		defer delete(tmp)
		src := 0
		for ch in 0 ..< flt.channels {
			prev: u8 = 0
			for p := ch; p < len(d); p += flt.channels {
				prev -= d[src]
				tmp[p] = prev
				src += 1
			}
		}
		copy(d, tmp)
	case 1, 2: // E8, E8E9: x86 call (and jmp) targets back from absolute
		FILE_SIZE :: 0x1000000
		cmp2: u8 = flt.type == 2 ? 0xe9 : 0xe8
		for cur := 0; cur + 4 < len(d); {
			c := d[cur]
			cur += 1
			if c == 0xe8 || c == cmp2 {
				off := u32((cur + flt.start) % FILE_SIZE)
				addr := u32(d[cur]) | u32(d[cur + 1]) << 8 | u32(d[cur + 2]) << 16 | u32(d[cur + 3]) << 24
				nv := addr
				put := false
				if addr & 0x80000000 != 0 {
					if (addr + off) & 0x80000000 == 0 {nv = addr + FILE_SIZE; put = true}
				} else if (addr - FILE_SIZE) & 0x80000000 != 0 {
					nv = addr - off; put = true
				}
				if put {d[cur] = u8(nv); d[cur + 1] = u8(nv >> 8); d[cur + 2] = u8(nv >> 16); d[cur + 3] = u8(nv >> 24)}
				cur += 4
			}
		}
	case 3: // ARM: BL targets back from absolute
		for cur := 0; cur + 3 < len(d); cur += 4 {
			if d[cur + 3] == 0xeb {
				off := u32(d[cur]) | u32(d[cur + 1]) << 8 | u32(d[cur + 2]) << 16
				off -= u32((flt.start + cur) / 4)
				d[cur] = u8(off); d[cur + 1] = u8(off >> 8); d[cur + 2] = u8(off >> 16)
			}
		}
	}
}
