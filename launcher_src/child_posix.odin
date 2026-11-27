#+build linux, darwin
// Starting programs on Linux and macOS (core:os's processes, stdout and stderr into one pipe), and elevated runs:
// pkexec on Linux (polkit's own password prompt), osascript "with administrator privileges" on macOS.
package launcher

import "core:os"
import "core:strings"

Child :: struct {
	p: os.Process,
}
Child_Pipe :: ^os.File

child_start :: proc(cmd: []string, dir: string) -> (c: Child, r: Child_Pipe, ok: bool) {
	rd, wr, err := os.pipe()
	if err != nil {return}
	p, perr := os.process_start({command = cmd, working_dir = dir, stdout = wr, stderr = wr})
	os.close(wr)
	if perr != nil {
		os.close(rd)
		return
	}
	return Child{p}, rd, true
}

child_read :: proc(r: Child_Pipe, buf: []u8) -> int {
	n, err := os.read(r, buf)
	if err != nil {return 0}
	return n
}

child_wait :: proc(c: Child, r: Child_Pipe) -> int {
	os.close(r)
	st, err := os.process_wait(c.p)
	if err != nil {return -1}
	return st.exit_code
}

// a command whose output goes to a file (out_path), not a pipe: the command's own end is waited for, not the end of its
// output. (A Wine program's output pipe is inherited by the processes Wine starts in the background -- wineserver,
// services.exe, winedevice... -- which keep it open until wineserver ends, ~3 s after the program: run() waited that
// long for every program, and Wine then started all over again for the next one. The HD Project's zones run the mod's
// tools three times per block, hundreds of blocks per zone: half an hour and more per zone, issue #25.) The output,
// when wanted, is read from the file afterwards; the file is removed.
run_to_file :: proc(t: ^Task, cmd: []string, dir, out_path: string, capture: ^strings.Builder = nil) -> (code: int, started: bool) {
	_ = os.remove(out_path) // (a new file: one still held by an earlier program's leftovers is left to them)
	f, ferr := os.open(out_path, {.Write, .Create, .Trunc})
	if ferr != nil {return -1, false}
	p, perr := os.process_start({command = cmd, working_dir = dir, stdout = f, stderr = f})
	os.close(f)
	if perr != nil {_ = os.remove(out_path); return -1, false}
	c := Child{p}
	task_add_child(t, c)
	st, werr := os.process_wait(p)
	task_remove_child(t, c)
	code = werr != nil ? -1 : st.exit_code
	if capture != nil {
		if data, rerr := os.read_entire_file(out_path, context.temp_allocator); rerr == nil {
			s, _ := strings.replace_all(string(data), "\r", "", context.temp_allocator)
			strings.write_string(capture, s)
			if len(s) > 0 && s[len(s) - 1] != '\n' {strings.write_byte(capture, '\n')}
		}
	}
	_ = os.remove(out_path)
	return code, true
}

child_kill :: proc(c: Child) {
	_ = os.process_kill(c.p)
}

// a command as one shell line (for osascript's "do shell script")
sh_quote :: proc(cmd: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for a, i in cmd {
		if i > 0 {strings.write_byte(&b, ' ')}
		strings.write_byte(&b, '\'')
		for c in a {
			if c == '\'' {strings.write_string(&b, `'\''`)} else {strings.write_rune(&b, c)}
		}
		strings.write_byte(&b, '\'')
	}
	return strings.to_string(b)
}

run_elevated :: proc(t: ^Task, cmd: []string) -> (code: int, started: bool) {
	logf(t, "Asking for administrator permission to run: %s", sh_quote(cmd))
	when ODIN_OS == .Darwin {
		line := sh_quote(cmd)
		esc, _ := strings.replace_all(line, `\`, `\\`, context.temp_allocator)
		esc, _ = strings.replace_all(esc, `"`, `\"`, context.temp_allocator)
		script := strings.concatenate({`do shell script "`, esc, `" with administrator privileges`}, context.temp_allocator)
		return run(t, {"/usr/bin/osascript", "-e", script})
	} else {
		pk := find_program("pkexec")
		if pk == "" {
			log_line(t, "pkexec (polkit) is not installed, so the launcher cannot ask for administrator permission. Run this yourself:")
			logf(t, "  sudo %s", sh_quote(cmd))
			return -1, false
		}
		args := make([dynamic]string, context.temp_allocator)
		append(&args, pk)
		append(&args, ..cmd)
		code, started = run(t, args[:])
		if started && (code == 126 || code == 127) {log_line(t, "Administrator permission was not given.")}
		return
	}
}

quiet_child_errors :: proc() {}
child_failure :: proc(code: int) -> string {return ""}
