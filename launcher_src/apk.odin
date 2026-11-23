// The Android build's output (the Cross-Compile tab's Android ARM64, cross.odin): WhiteRecomp.apk, written here --
// no Android SDK, no Java -- and a README.txt.
//
// The APK is a zip of
//   AndroidManifest.xml, resources.arsc, res/   compiled once with Android's own tool (tools/android_sysroot.sh) and carried
//                                         in the bundle (cross/android_arm64/apk/)
//   assets/WhiteRecomp.cfg                the Options tab's game options (the app reads it: src/runtime/xrc_android.c)
//   lib/arm64-v8a/libmain.so              the game
// every entry stored (not compressed: the game is mostly code and data that compress little), 4-byte aligned and the
// library on a 16 KB boundary (an extra field of zipalign's kind), then signed with APK Signature Scheme v2 (what
// Android 7 and later check; the app needs Android 10): ECDSA P-256 with SHA-256 over the zip's 1 MB chunks.
// The key is the player's own, made at their first Android build and kept in the data dir (android_key.bin) with its
// self-signed certificate (android_cert.der): Android installs an update of an app only when it is signed by the same
// one, so the same pair signs every build. (Lose them, and the next build installs only after the old app is removed.)
package launcher

import "core:crypto"
import "core:crypto/ecdsa"
import "core:crypto/sha2"
import "core:encoding/asn1"
import "core:fmt"
import hc "core:hash"
import "core:os"
import "core:strings"
import dt "core:time"

@(private = "file")
APK_ALGO_ECDSA_SHA256 :: u32(0x0201)
@(private = "file")
APK_V2_ID :: u32(0x7109871a)

@(private = "file")
put_u16 :: proc(b: ^[dynamic]u8, v: u16) {append(b, u8(v), u8(v >> 8))}
@(private = "file")
put_u32 :: proc(b: ^[dynamic]u8, v: u32) {append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))}
@(private = "file")
put_u64 :: proc(b: ^[dynamic]u8, v: u64) {put_u32(b, u32(v)); put_u32(b, u32(v >> 32))}
// a length-prefixed (u32) block
@(private = "file")
put_lp :: proc(b: ^[dynamic]u8, data: []u8) {put_u32(b, u32(len(data))); append(b, ..data)}

// the signing key and its certificate: the data dir's, or a new pair (written there)
@(private = "file")
apk_key :: proc(t: ^Task, priv: ^ecdsa.Private_Key) -> (cert: []u8, ok: bool) {
	key_path, cert_path := data_path("android_key.bin"), data_path("android_cert.der")
	kb, kerr := os.read_entire_file(key_path, context.temp_allocator)
	cb, cerr := os.read_entire_file(cert_path, context.temp_allocator)
	if kerr == nil && cerr == nil && len(kb) == 32 && len(cb) > 0 && ecdsa.private_key_set_bytes(priv, .SECP256R1, kb) {
		return cb, true
	}
	if !crypto.HAS_RAND_BYTES || !ecdsa.private_key_generate(priv, .SECP256R1) {
		log_line(t, "Cannot make the APK's signing key (no random numbers from the system).")
		return nil, false
	}
	pub: ecdsa.Public_Key
	ecdsa.public_key_set_priv(&pub, priv)
	pk: [65]u8
	ecdsa.public_key_bytes(&pub, pk[:])
	// the self-signed X.509 certificate: CN=WhiteRecomp, valid 2026-2049, its serial from the public key
	OID_ECDSA_SHA256 := []u8{0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02}
	OID_EC_PUBKEY := []u8{0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01}
	OID_P256 := []u8{0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07}
	OID_CN := []u8{0x55, 0x04, 0x03}
	serial: [8]u8
	{
		h: [32]u8
		c: sha2.Context_256
		sha2.init_256(&c)
		sha2.update(&c, pk[:])
		sha2.final(&c, h[:])
		copy(serial[:], h[:8])
		serial[0] &= 0x7f
		serial[0] |= 0x01
	}
	cn_attr := [2]asn1.Value{asn1.object_identifier(OID_CN), asn1.primitive(asn1.universal(.UTF8_String), transmute([]u8)string("WhiteRecomp"))}
	cn_seq := [1]asn1.Value{asn1.sequence(cn_attr[:])}
	rdn := [1]asn1.Value{asn1.set(cn_seq[:])}
	name := asn1.sequence(rdn[:])
	algo_kids := [1]asn1.Value{asn1.object_identifier(OID_ECDSA_SHA256)}
	algo := asn1.sequence(algo_kids[:])
	nb, _ := dt.components_to_time(2026, 1, 1, 0, 0, 0)
	na, _ := dt.components_to_time(2049, 12, 31, 23, 59, 59)
	validity_kids := [2]asn1.Value{asn1.time(nb), asn1.time(na)}
	spki_algo_kids := [2]asn1.Value{asn1.object_identifier(OID_EC_PUBKEY), asn1.object_identifier(OID_P256)}
	spki_kids := [2]asn1.Value{asn1.sequence(spki_algo_kids[:]), asn1.bit_string_octets(pk[:])}
	spki := asn1.sequence(spki_kids[:])
	version := [1]asn1.Value{asn1.integer_unsigned([]u8{2})}
	tbs_kids := [7]asn1.Value {
		asn1.context_explicit(0, version[:]),
		asn1.integer_unsigned(serial[:]),
		algo,
		name,
		asn1.sequence(validity_kids[:]),
		name,
		spki,
	}
	tbs, terr := asn1.marshal(asn1.sequence(tbs_kids[:]), context.temp_allocator)
	if terr != .None {log_line(t, "Cannot make the APK's certificate."); return nil, false}
	sig, sok := ecdsa.sign_asn1(priv, .SHA256, tbs, context.temp_allocator)
	if !sok {log_line(t, "Cannot sign the APK's certificate."); return nil, false}
	cert_kids := [3]asn1.Value{asn1.raw(tbs), algo, asn1.bit_string_octets(sig)}
	der, derr := asn1.marshal(asn1.sequence(cert_kids[:]), context.temp_allocator)
	if derr != .None {log_line(t, "Cannot make the APK's certificate."); return nil, false}
	kb2: [32]u8
	ecdsa.private_key_bytes(priv, kb2[:])
	if os.write_entire_file(key_path, kb2[:]) != nil || os.write_entire_file(cert_path, der) != nil {
		logf(t, "Cannot keep the APK's signing key in %s.", key_path)
		return nil, false
	}
	logf(t, "A new signing key for your APKs: %s (keep it: an update installs over the app only when signed by the same key)", key_path)
	return der, true
}

@(private = "file")
Zip_Entry :: struct {
	name:   string,
	data:   []u8,
	align:  int,
	crc:    u32,
	offset: int,
}

// the zip of the entries (stored, aligned): its bytes, and where its central directory starts
@(private = "file")
zip_stored :: proc(entries: []Zip_Entry) -> (out: [dynamic]u8, cd_off: int) {
	total := 0
	for e in entries {total += len(e.data) + 30 + len(e.name) + 16384 + 64}
	out = make([dynamic]u8, 0, total + 4096, context.temp_allocator)
	for &e in entries {
		e.crc = hc.crc32(e.data)
		e.offset = len(out)
		// the extra field pads the data to its alignment (zipalign's: id 0xd935, the alignment, then zeros)
		start := len(out) + 30 + len(e.name)
		pad := 6
		for (start + pad) % e.align != 0 {pad += 1}
		put_u32(&out, 0x04034b50)
		put_u16(&out, 10) // (version needed: stored)
		put_u16(&out, 0) // (flags)
		put_u16(&out, 0) // (stored)
		put_u16(&out, 0) // (time)
		put_u16(&out, 0x21) // (date: 1980-01-01)
		put_u32(&out, e.crc)
		put_u32(&out, u32(len(e.data)))
		put_u32(&out, u32(len(e.data)))
		put_u16(&out, u16(len(e.name)))
		put_u16(&out, u16(pad))
		append(&out, ..transmute([]u8)e.name)
		put_u16(&out, 0xd935)
		put_u16(&out, u16(pad - 4))
		put_u16(&out, u16(e.align))
		for _ in 6 ..< pad {append(&out, 0)}
		append(&out, ..e.data)
	}
	cd_off = len(out)
	for e in entries {
		put_u32(&out, 0x02014b50)
		put_u16(&out, 20) // (made by)
		put_u16(&out, 10)
		put_u16(&out, 0)
		put_u16(&out, 0)
		put_u16(&out, 0)
		put_u16(&out, 0x21)
		put_u32(&out, e.crc)
		put_u32(&out, u32(len(e.data)))
		put_u32(&out, u32(len(e.data)))
		put_u16(&out, u16(len(e.name)))
		put_u16(&out, 0) // (extra)
		put_u16(&out, 0) // (comment)
		put_u16(&out, 0) // (disk)
		put_u16(&out, 0) // (internal attributes)
		put_u32(&out, 0) // (external attributes)
		put_u32(&out, u32(e.offset))
		append(&out, ..transmute([]u8)e.name)
	}
	cd_size := len(out) - cd_off
	put_u32(&out, 0x06054b50)
	put_u16(&out, 0)
	put_u16(&out, 0)
	put_u16(&out, u16(len(entries)))
	put_u16(&out, u16(len(entries)))
	put_u32(&out, u32(cd_size))
	put_u32(&out, u32(cd_off))
	put_u16(&out, 0)
	return
}

// APK Signature Scheme v2's content digest: SHA-256 over 1 MB chunks of the entries, the central directory and the
// end record (its central directory offset the signing block's, which is where the central directory starts now)
@(private = "file")
apk_digest :: proc(zip: []u8, cd_off: int) -> (d: [32]u8) {
	sections := [3][]u8{zip[:cd_off], zip[cd_off:len(zip) - 22], zip[len(zip) - 22:]}
	digests := make([dynamic]u8, context.temp_allocator)
	n := 0
	for sec in sections {
		for at := 0; at < len(sec); at += 1 << 20 {
			chunk := sec[at:min(at + (1 << 20), len(sec))]
			c: sha2.Context_256
			sha2.init_256(&c)
			hdr := [dynamic]u8{}
			defer delete(hdr)
			append(&hdr, 0xa5)
			put_u32(&hdr, u32(len(chunk)))
			sha2.update(&c, hdr[:])
			sha2.update(&c, chunk)
			h: [32]u8
			sha2.final(&c, h[:])
			append(&digests, ..h[:])
			n += 1
		}
	}
	c: sha2.Context_256
	sha2.init_256(&c)
	hdr := [dynamic]u8{}
	defer delete(hdr)
	append(&hdr, 0x5a)
	put_u32(&hdr, u32(n))
	sha2.update(&c, hdr[:])
	sha2.update(&c, digests[:])
	sha2.final(&c, d[:])
	return
}

// the signed APK of the entries, at path
@(private = "file")
apk_write :: proc(t: ^Task, path: string, entries: []Zip_Entry) -> bool {
	priv: ecdsa.Private_Key
	cert, ok := apk_key(t, &priv)
	if !ok {return false}
	pub: ecdsa.Public_Key
	ecdsa.public_key_set_priv(&pub, &priv)
	pk: [65]u8
	ecdsa.public_key_bytes(&pub, pk[:])
	OID_EC_PUBKEY := []u8{0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01}
	OID_P256 := []u8{0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07}
	spki_algo_kids := [2]asn1.Value{asn1.object_identifier(OID_EC_PUBKEY), asn1.object_identifier(OID_P256)}
	spki_kids := [2]asn1.Value{asn1.sequence(spki_algo_kids[:]), asn1.bit_string_octets(pk[:])}
	spki, serr := asn1.marshal(asn1.sequence(spki_kids[:]), context.temp_allocator)
	if serr != .None {return false}

	zip, cd_off := zip_stored(entries)
	digest := apk_digest(zip[:], cd_off)

	// the signer: signed data (the digest, the certificate, no attributes), its signature, the public key
	signed := make([dynamic]u8, context.temp_allocator)
	{
		one := make([dynamic]u8, context.temp_allocator)
		put_u32(&one, APK_ALGO_ECDSA_SHA256)
		put_lp(&one, digest[:])
		ds := make([dynamic]u8, context.temp_allocator)
		put_lp(&ds, one[:])
		put_lp(&signed, ds[:])
		cs := make([dynamic]u8, context.temp_allocator)
		put_lp(&cs, cert)
		put_lp(&signed, cs[:])
		put_u32(&signed, 0) // (no additional attributes)
	}
	sig, sok := ecdsa.sign_asn1(&priv, .SHA256, signed[:], context.temp_allocator)
	if !sok {log_line(t, "Cannot sign the APK."); return false}
	signer := make([dynamic]u8, context.temp_allocator)
	put_lp(&signer, signed[:])
	{
		one := make([dynamic]u8, context.temp_allocator)
		put_u32(&one, APK_ALGO_ECDSA_SHA256)
		put_lp(&one, sig)
		sigs := make([dynamic]u8, context.temp_allocator)
		put_lp(&sigs, one[:])
		put_lp(&signer, sigs[:])
	}
	put_lp(&signer, spki)
	signers := make([dynamic]u8, context.temp_allocator)
	put_lp(&signers, signer[:])
	value := make([dynamic]u8, context.temp_allocator)
	put_lp(&value, signers[:])

	// the APK Signing Block, between the entries and the central directory
	block := make([dynamic]u8, context.temp_allocator)
	pair_len := u64(4 + len(value))
	size := u64(8 + pair_len + 8 + 16) // (the block's size, its first size field left out)
	put_u64(&block, size)
	put_u64(&block, pair_len)
	put_u32(&block, APK_V2_ID)
	append(&block, ..value[:])
	put_u64(&block, size)
	append(&block, ..transmute([]u8)string("APK Sig Block 42"))

	out := make([dynamic]u8, 0, len(zip) + len(block), context.temp_allocator)
	append(&out, ..zip[:cd_off])
	append(&out, ..block[:])
	append(&out, ..zip[cd_off:])
	// (the end record's central directory offset: past the block now)
	new_cd := u32(cd_off + len(block))
	eocd := len(out) - 22
	out[eocd + 16], out[eocd + 17], out[eocd + 18], out[eocd + 19] = u8(new_cd), u8(new_cd >> 8), u8(new_cd >> 16), u8(new_cd >> 24)
	if err := os.write_entire_file(path, out[:]); err != nil {logf(t, "Cannot write %s.", path); return false}
	return true
}

// every file under dir, as zip entries named prefix/... (the APK's res/: the files its resource table names)
@(private = "file")
apk_add_dir :: proc(list: ^[dynamic]Zip_Entry, dir, prefix: string) {
	ents, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {return}
	for e in ents {
		name := strings.concatenate({prefix, "/", e.name}, context.temp_allocator)
		if e.type == .Directory {apk_add_dir(list, e.fullpath, name); continue}
		if data, rerr := os.read_entire_file(e.fullpath, context.temp_allocator); rerr == nil {append(list, Zip_Entry{name = name, data = data, align = 4})}
	}
}

// the Android Build's output: dir/WhiteRecomp.apk (from lib, the linked libmain.so) and dir/README.txt
android_write_output :: proc(t: ^Task, x: ^Cross_Target, dir, lib: string) -> bool {
	src := data_path("cross", x.key, "apk")
	manifest, merr := os.read_entire_file(pjoin({src, "AndroidManifest.xml"}, context.temp_allocator), context.temp_allocator)
	arsc, aerr := os.read_entire_file(pjoin({src, "resources.arsc"}, context.temp_allocator), context.temp_allocator)
	so, lerr := os.read_entire_file(lib, context.allocator)
	defer delete(so)
	if merr != nil || aerr != nil {logf(t, "This launcher carries no APK files for %s (%s).", x.name, src); return false}
	if lerr != nil {logf(t, "Cannot read %s.", lib); return false}
	cfg := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&cfg, "# WhiteRecomp's settings for %s, written by the launcher's Cross-Compile Build.\n", x.name)
	fmt.sbprintf(&cfg, "# (An ff13.cfg in the app's own folder on the device, Android/data/com.whiterecomp.ff13/files, overrides it.)\n")
	cfg_game_lines(&cfg, Build_Spec{cross = x})
	list := make([dynamic]Zip_Entry, context.temp_allocator)
	append(&list, Zip_Entry{name = "AndroidManifest.xml", data = manifest, align = 4}, Zip_Entry{name = "resources.arsc", data = arsc, align = 4})
	apk_add_dir(&list, pjoin({src, "res"}, context.temp_allocator), "res") // (the launcher icon: compiled with the table)
	append(&list, Zip_Entry{name = "assets/WhiteRecomp.cfg", data = cfg.buf[:], align = 4}, Zip_Entry{name = "lib/arm64-v8a/libmain.so", data = so, align = 16384})
	entries := list[:]
	set_status(t, 0.96, "Writing the APK")
	apk := pjoin({dir, cross_out_file(x)}, context.temp_allocator)
	if !apk_write(t, apk, entries) {return false}

	r := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&r, "WhiteRecomp for Android (ARM64)\n")
	fmt.sbprintf(&r, "===============================\n\n")
	fmt.sbprintf(&r, "Built by the WhiteRecomp launcher's Cross-Compile tab (CPU: %s). Needs Android 10 or newer on a 64-bit ARM\n", cross_cpu(x))
	fmt.sbprintf(&r, "device with Vulkan graphics. It has on-screen touch controls (A, B, 0 = pause, 1 = select / skip, and an\n")
	fmt.sbprintf(&r, "analog stick wherever a finger goes down: left half to move, right half for the camera); a game controller,\n")
	fmt.sbprintf(&r, "or a keyboard and mouse, work too. Cutscenes play through Android's own video decoder once they are\n")
	fmt.sbprintf(&r, "converted on a PC (Convert Movies: the .mp4 files go with the game folder).\n\n")
	fmt.sbprintf(&r, "1. Install %s on the device: copy it there and open it (allow installing apps from that source when\n", cross_out_file(x))
	fmt.sbprintf(&r, "   Android asks), or from a computer with adb:   adb install -r %s\n", cross_out_file(x))
	fmt.sbprintf(&r, "   A new build installs over the old one (it is signed with the same key: the launcher keeps it).\n\n")
	fmt.sbprintf(&r, "2. Copy your FINAL FANTASY XIII folder (the one with white_data in it) to the device's internal storage,\n")
	fmt.sbprintf(&r, "   named \"FINAL FANTASY XIII\" (so: Internal storage/FINAL FANTASY XIII/white_data/...), or to the top of a\n")
	fmt.sbprintf(&r, "   microSD card (SD card/FINAL FANTASY XIII/white_data/...): the game looks on every card and USB drive too.\n")
	fmt.sbprintf(&r, "   Without the movies it is about 19 GB (run Convert Movies and Discard Movies on the PC first: that keeps\n")
	fmt.sbprintf(&r, "   the converted cutscenes and makes the original movie files tiny). Somewhere else: write the folder's\n")
	fmt.sbprintf(&r, "   full path into Android/data/com.whiterecomp.ff13/files/game_dir.txt (e.g. /storage/1234-ABCD/Games/FINAL FANTASY XIII).\n\n")
	fmt.sbprintf(&r, "3. Start WhiteRecomp. The first time it asks for access to your files (on Android 11 and later: \"Allow access to\n")
	fmt.sbprintf(&r, "   manage all files\" -- turn it on, then go back to the app). It then finds the game and starts.\n")
	fmt.sbprintf(&r, "   (Or, without that permission: put the game folder in Android/data/com.whiterecomp.ff13/files/ instead,\n")
	fmt.sbprintf(&r, "   e.g. adb push \"FINAL FANTASY XIII\" /sdcard/Android/data/com.whiterecomp.ff13/files/ after starting it once.)\n\n")
	fmt.sbprintf(&r, "Saves, the game's log (ff13.log) and its shader cache are in Android/data/com.whiterecomp.ff13/files/.\n")
	fmt.sbprintf(&r, "If it does not start, that log says why: adb pull /sdcard/Android/data/com.whiterecomp.ff13/files/ff13.log\n")
	return os.write_entire_file(pjoin({dir, "README.txt"}, context.temp_allocator), r.buf[:]) == nil
}
