package platform

import "base:runtime"
import "core:slice"
import "core:strings"
import win32 "core:sys/windows"
import input "../../iv_input"

// ---------------------------------------------------------------------------
// The Windows part of platform: a Win32 window, its message loop, and the translation of keys and mouse into the
// `input` package's names.
//
// Window flags: .No_Decorations keeps WS_THICKFRAME but drops the caption, and WM_NCCALCSIZE makes the client area the whole window; WM_NCHITTEST then
// answers with the resize handles and with the program's own idea of its title bar (set_hit_test), so dragging, snapping, a double click to maximize and
// the system menu on a right click all work as they do with a title bar of Windows' own.
//
// Known limits (to do): while the user drags the title bar or the edge of the window Windows runs its own message loop,
// so the program's frames stall until the mouse is released (the fix is a timer that calls back into the program). IME
// composition is not handled (WM_CHAR only). No clipboard, no cursor shapes yet.
// ---------------------------------------------------------------------------

_Native :: struct {
	hwnd:             win32.HWND,
	hinstance:        win32.HINSTANCE,
	allocator:        runtime.Allocator,
	saved_style:      win32.LONG_PTR, // the style before fullscreen
	saved_placement:  win32.WINDOWPLACEMENT,
	high_surrogate:   u16, // the first half of a character outside the BMP, waiting for the second
	pending_maximize: bool, // created hidden with .Maximized: set_visible(true) shows it maximized
	background:       win32.HBRUSH, // Window_Desc.background, until stop_background
}

@(private)
CLASS_NAME :: "IvSystemWindow"

// How close to the edge of a window without decorations the pointer is a resize handle, in pixels at 96 dpi.
@(private)
RESIZE_BORDER :: 5

@(private)
class_registered: bool

@(private)
perf_frequency: win32.LARGE_INTEGER

// XInput pads: a missing pad is looked for again only now and then (asking for one that is not there is slow).
@(private)
pad_next_scan: [input.MAX_PADS]f64

// ---- the API -----------------------------------------------------------------------------------------------

// Makes a window. The memory is `allocator`'s: destroy_window must be called with the same one in context (or pass the
// same). Returns false if Windows refuses.
create_window :: proc(desc: Window_Desc, allocator := context.allocator) -> (w: ^Window, ok: bool) {
	if !ensure_class() {
		return nil, false
	}
	w = new(Window, allocator)
	w.allocator = allocator
	w.input = make([dynamic]Input_Event, allocator)
	if !make_hwnd(w, desc, nil) {
		delete(w.input)
		free(w, allocator)
		return nil, false
	}
	return w, true
}

destroy_window :: proc(w: ^Window) {
	if w == nil {
		return
	}
	destroy_hwnd(w)
	allocator := w.allocator
	delete(w.input)
	free(w, allocator)
}

// Destroys the operating system's window and makes a new one with the same title, size, place and state; the `^Window`
// stays the same. For a graphics API that has tied the old window to itself and cannot be changed (see
// ren.Factory.fresh_window). Anything the old window had (a swapchain, a context) is gone and must be made again.
recreate_window :: proc(w: ^Window) -> bool {
	desc := w.desc
	desc.width, desc.height = w.size.x, w.size.y
	desc.flags -= {.Fullscreen}
	if w.maximized {
		desc.flags += {.Maximized}
	} else {
		desc.flags -= {.Maximized}
	}
	if win32.IsWindowVisible(w.hwnd) { // it was shown since it was made: the new one is too
		desc.flags -= {.Hidden}
	}
	was_fullscreen := w.fullscreen
	pos: Maybe([2]int)
	if !was_fullscreen && !w.maximized {
		r: win32.RECT
		if win32.GetWindowRect(w.hwnd, &r) {
			pos = [2]int{int(r.left), int(r.top)}
		}
	}
	destroy_hwnd(w)
	clear(&w.input)
	w.fullscreen = false
	if !make_hwnd(w, desc, pos) {
		return false
	}
	if was_fullscreen {
		set_fullscreen(w, true)
	}
	return true
}

// Handles every message of the operating system that is waiting (for all windows of this thread) and returns what
// happened to `w` since the last call. Its keys and mouse are queued for feed_input.
poll :: proc(w: ^Window) -> Window_Events {
	msg: win32.MSG
	for win32.PeekMessageW(&msg, nil, 0, 0, win32.PM_REMOVE) {
		win32.TranslateMessage(&msg) // keys make WM_CHAR here
		win32.DispatchMessageW(&msg)
	}
	events := w.events
	w.events = {}
	return events
}

// Sleeps until a message arrives for this thread or `timeout` seconds have passed (< 0: no limit), whichever is first; then poll. Returns at once
// when there is input that feed_input has not taken yet, or a message already waiting.
wait_events :: proc(w: ^Window, timeout: f64) {
	if len(w.input) > 0 || w.events != {} {
		return
	}
	ms := win32.INFINITE if timeout < 0 else win32.DWORD(min(timeout * 1000 + 0.5, 1e9))
	if ms == 0 {
		return
	}
	MsgWaitForMultipleObjectsEx(0, nil, ms, win32.QS_ALLINPUT, MWMO_INPUTAVAILABLE)
}

@(private = "file")
MWMO_INPUTAVAILABLE :: 0x0004 // (also wake for messages that are in the queue already, not only for new ones)

foreign import user32_wait "system:User32.lib"

@(private = "file", default_calling_convention = "system")
foreign user32_wait {
	MsgWaitForMultipleObjectsEx :: proc(nCount: win32.DWORD, pHandles: [^]win32.HANDLE, dwMilliseconds: win32.DWORD, dwWakeMask: win32.DWORD, dwFlags: win32.DWORD) -> win32.DWORD ---
}

// The program draws the window itself now (its first frame is on the screen): the background of Window_Desc is not painted any more.
stop_background :: proc(w: ^Window) {
	if w.background != nil {
		win32.DeleteObject(win32.HGDIOBJ(w.background))
		w.background = nil
	}
}

set_title :: proc(w: ^Window, title: string) {
	w.desc.title = title // not copied: keep it alive (a literal is fine)
	win32.SetWindowTextW(w.hwnd, win32.utf8_to_wstring(title))
}

// Borderless fullscreen on the monitor the window is on, and back.
set_fullscreen :: proc(w: ^Window, on: bool) {
	if on == w.fullscreen || w.hwnd == nil {
		return
	}
	if on {
		w.saved_style = win32.GetWindowLongPtrW(w.hwnd, win32.GWL_STYLE)
		w.saved_placement.length = size_of(win32.WINDOWPLACEMENT)
		win32.GetWindowPlacement(w.hwnd, &w.saved_placement)
		mi := win32.MONITORINFO {
			cbSize = size_of(win32.MONITORINFO),
		}
		win32.GetMonitorInfoW(win32.MonitorFromWindow(w.hwnd, .MONITOR_DEFAULTTONEAREST), &mi)
		style := (w.saved_style &~ win32.LONG_PTR(win32.WS_OVERLAPPEDWINDOW)) | win32.LONG_PTR(win32.WS_POPUP | win32.WS_VISIBLE)
		win32.SetWindowLongPtrW(w.hwnd, win32.GWL_STYLE, style)
		r := mi.rcMonitor
		win32.SetWindowPos(w.hwnd, win32.HWND_TOP, r.left, r.top, r.right - r.left, r.bottom - r.top, win32.SWP_NOOWNERZORDER | win32.SWP_FRAMECHANGED)
	} else {
		win32.SetWindowLongPtrW(w.hwnd, win32.GWL_STYLE, w.saved_style)
		win32.SetWindowPlacement(w.hwnd, &w.saved_placement)
		win32.SetWindowPos(w.hwnd, nil, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_NOOWNERZORDER | win32.SWP_FRAMECHANGED)
	}
	w.fullscreen = on
	w.decorated = !on && .No_Decorations not_in w.desc.flags
}

// Asks for a new size of the client area, in pixels (ignored in fullscreen). The window system decides: w.size and the
// .Resized event say what the window became.
set_size :: proc(w: ^Window, width, height: int) {
	if w.fullscreen || w.hwnd == nil {
		return
	}
	dpi := win32.GetDpiForWindow(w.hwnd)
	cx, cy := outer_size(w.desc.flags, window_style(w.desc.flags), max(width, 1), max(height, 1), dpi)
	win32.SetWindowPos(w.hwnd, nil, 0, 0, cx, cy, win32.SWP_NOMOVE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE)
}

// Shows or removes the system's title bar and border (the .No_Decorations flag). The client area keeps its size. A program that removes them draws its own
// title bar and says where it is with set_hit_test.
set_decorated :: proc(w: ^Window, on: bool) {
	if on {
		w.desc.flags -= {.No_Decorations}
	} else {
		w.desc.flags += {.No_Decorations}
	}
	apply_style(w)
}

// Lets the user resize the window, or not (the .Fixed_Size flag; a fixed window has no maximize either).
set_resizable :: proc(w: ^Window, on: bool) {
	if on {
		w.desc.flags -= {.Fixed_Size}
	} else {
		w.desc.flags += {.Fixed_Size}
	}
	apply_style(w)
}

// Keeps the window above the others, or not (the .Always_On_Top flag).
set_always_on_top :: proc(w: ^Window, on: bool) {
	if on {
		w.desc.flags += {.Always_On_Top}
	} else {
		w.desc.flags -= {.Always_On_Top}
	}
	if w.hwnd != nil {
		win32.SetWindowPos(w.hwnd, win32.HWND_TOPMOST if on else win32.HWND_NOTOPMOST, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE)
	}
}

// Lets the user move the window by the mouse button that is down now, as if the title bar were held (for a custom title
// bar: call it when the button goes down on it).
begin_move :: proc(w: ^Window) {
	win32.ReleaseCapture()
	win32.SendMessageW(w.hwnd, win32.WM_NCLBUTTONDOWN, win32.HTCAPTION, 0)
}

// Lets the user resize the window from an edge or corner by the mouse button that is down now (for a window without a
// frame of its own).
begin_resize :: proc(w: ^Window, edge: Resize_Edge) {
	hit: win32.WPARAM
	switch edge {
	case .Left:
		hit = win32.HTLEFT
	case .Right:
		hit = win32.HTRIGHT
	case .Top:
		hit = win32.HTTOP
	case .Bottom:
		hit = win32.HTBOTTOM
	case .Top_Left:
		hit = win32.HTTOPLEFT
	case .Top_Right:
		hit = win32.HTTOPRIGHT
	case .Bottom_Left:
		hit = win32.HTBOTTOMLEFT
	case .Bottom_Right:
		hit = win32.HTBOTTOMRIGHT
	}
	win32.ReleaseCapture()
	win32.SendMessageW(w.hwnd, win32.WM_NCLBUTTONDOWN, hit, 0)
}

// Shows or hides the window.
set_visible :: proc(w: ^Window, visible: bool) {
	if visible && w.pending_maximize { // made hidden with .Maximized: the first showing is the maximized one
		w.pending_maximize = false
		win32.ShowWindow(w.hwnd, win32.SW_SHOWMAXIMIZED)
		return
	}
	win32.ShowWindow(w.hwnd, win32.SW_SHOW if visible else win32.SW_HIDE)
}

// w.maximized and the .Resized event follow when the window system has done it (poll).
maximize :: proc(w: ^Window) {
	win32.ShowWindow(w.hwnd, win32.SW_MAXIMIZE)
}

// Back from maximized or minimized to the size and place before.
restore :: proc(w: ^Window) {
	win32.ShowWindow(w.hwnd, win32.SW_RESTORE)
}

// Into the task bar.
minimize :: proc(w: ^Window) {
	win32.ShowWindow(w.hwnd, win32.SW_MINIMIZE)
}

// ---- the mouse cursor ----

@(private)
cursor_handle :: proc(w: ^Window) -> win32.HCURSOR {
	if w.cursor_hidden {
		return nil
	}
	id: cstring
	switch w.cursor_shape {
	case .Default:
		id = win32.IDC_ARROW
	case .Hand:
		id = win32.IDC_HAND
	case .Text:
		id = win32.IDC_IBEAM
	case .Crosshair:
		id = win32.IDC_CROSS
	case .Resize_Horizontal:
		id = win32.IDC_SIZEWE
	}
	return win32.LoadCursorW(nil, transmute(cstring16)id)
}

// Windows asks for the cursor whenever the mouse moves over the window; this also applies a change at once.
@(private)
apply_cursor :: proc(w: ^Window) {
	if w.mouse_inside {
		win32.SetCursor(cursor_handle(w))
	}
}

set_cursor_visible :: proc(w: ^Window, visible: bool) {
	w.cursor_hidden = !visible
	apply_cursor(w)
}

set_cursor_shape :: proc(w: ^Window, shape: Cursor_Shape) {
	w.cursor_shape = shape
	apply_cursor(w)
}

// Moves the mouse cursor to a point of the client area (in pixels). false if the system does not allow it.
set_mouse_position :: proc(w: ^Window, x, y: int) -> bool {
	p := win32.POINT{i32(x), i32(y)}
	win32.ClientToScreen(w.hwnd, &p)
	return bool(win32.SetCursorPos(p.x, p.y))
}

// ---- the clipboard ----

// The text on the clipboard (the caller owns the string), or false if there is none.
clipboard_text :: proc(w: ^Window, allocator := context.allocator) -> (text: string, ok: bool) {
	if !win32.OpenClipboard(w.hwnd) {
		return "", false
	}
	defer win32.CloseClipboard()
	handle := win32.GetClipboardData(win32.CF_UNICODETEXT)
	if handle == nil {
		return "", false
	}
	locked := win32.GlobalLock(win32.HGLOBAL(handle))
	if locked == nil {
		return "", false
	}
	defer win32.GlobalUnlock(win32.HGLOBAL(handle))
	s, err := win32.wstring_to_utf8(cstring16(locked), -1, allocator)
	return s, err == nil
}

set_clipboard_text :: proc(w: ^Window, text: string) -> bool {
	units := win32.utf8_to_utf16(text, context.temp_allocator)
	bytes := (len(units) + 1) * size_of(u16)
	memory := win32.HGLOBAL(win32.GlobalAlloc(win32.GMEM_MOVEABLE, win32.SIZE_T(bytes)))
	if memory == nil {
		return false
	}
	locked := win32.GlobalLock(memory)
	if locked == nil {
		win32.GlobalFree(memory)
		return false
	}
	destination := ([^]u16)(locked)
	copy(destination[:len(units)], units)
	destination[len(units)] = 0
	win32.GlobalUnlock(memory)

	if !win32.OpenClipboard(w.hwnd) {
		win32.GlobalFree(memory)
		return false
	}
	defer win32.CloseClipboard()
	win32.EmptyClipboard()
	if win32.SetClipboardData(win32.CF_UNICODETEXT, win32.HANDLE(memory)) == nil {
		win32.GlobalFree(memory)
		return false
	}
	return true // (the clipboard owns the memory now)
}

// ---- the file dialogs ----
// Windows' own Explorer windows (IFileOpenDialog / IFileSaveDialog, through COM): the full file browser, with the navigation pane, the address bar, search
// and the "new folder" button, not the old small dialogs.

// A zero-terminated UTF-16 copy of `s` in the temporary allocator; `backslashes` turns '/' into '\' (a path the shell is to parse).
@(private = "file")
wide_z :: proc(s: string, backslashes := false) -> cstring16 {
	units := win32.utf8_to_utf16(s, context.temp_allocator)
	buf := make([]u16, len(units) + 1, context.temp_allocator)
	copy(buf, units)
	if backslashes {
		for &u in buf {
			if u == '/' {
				u = '\\'
			}
		}
	}
	return cstring16(raw_data(buf))
}

// Lets go of a COM object. (A procedure of its own: `defer x->Release()` does not compile to good code.)
@(private = "file")
com_release :: proc(object: rawptr) {
	u := cast(^win32.IUnknown)object
	u->Release()
}

// Shows a file dialog and returns the path the user chose. `save`: the Save dialog (it asks before replacing a file); otherwise the Open dialog asking
// for a folder. `dir` is the folder it opens in ("" lets Windows choose), `suggested` the name it starts with (Save only).
@(private = "file")
file_dialog :: proc(w: ^Window, save: bool, title, suggested, dir: string, allocator: runtime.Allocator, program := false, filter_name := "", filter_spec := "") -> (path: string, ok: bool) {
	win32.CoInitializeEx(nil, .APARTMENTTHREADED) // (the dialogs are COM objects; a second call, or one in another mode, is harmless)

	obj: rawptr
	clsid := win32.CLSID_FileSaveDialog if save else win32.CLSID_FileOpenDialog
	iid := win32.IID_IFileSaveDialog if save else win32.IID_IFileOpenDialog
	if win32.FAILED(win32.CoCreateInstance(clsid, nil, win32.CLSCTX_INPROC_SERVER, iid, &obj)) || obj == nil {
		return "", false
	}
	fd := cast(^win32.IFileDialog)obj // (the save and the open dialogs are both a file dialog first)
	defer com_release(obj)

	opts: win32.FILEOPENDIALOGOPTIONS
	fd->GetOptions(&opts)
	opts |= win32.FOS_FORCEFILESYSTEM | win32.FOS_PATHMUSTEXIST
	if save {
		opts |= win32.FOS_OVERWRITEPROMPT
	} else if program || filter_spec != "" {
		opts |= win32.FOS_FILEMUSTEXIST
	} else {
		opts |= win32.FOS_PICKFOLDERS
	}
	fd->SetOptions(opts)
	fd->SetTitle(wide_z(title))

	if save {
		types := [2]win32.COMDLG_FILTERSPEC{{wide_z("All files"), wide_z("*.*")}, {wide_z("Odin source"), wide_z("*.odin")}}
		fd->SetFileTypes(u32(len(types)), &types[0])
		fd->SetFileTypeIndex(1)
		if suggested != "" {
			fd->SetFileName(wide_z(suggested))
		}
	} else if filter_spec != "" {
		types := [2]win32.COMDLG_FILTERSPEC{{wide_z(filter_name), wide_z(filter_spec)}, {wide_z("All files"), wide_z("*.*")}}
		fd->SetFileTypes(u32(len(types)), &types[0])
		fd->SetFileTypeIndex(1)
	} else if program {
		types := [2]win32.COMDLG_FILTERSPEC{{wide_z("Programs"), wide_z("*.exe;*.com;*.bat;*.cmd")}, {wide_z("All files"), wide_z("*.*")}}
		fd->SetFileTypes(u32(len(types)), &types[0])
		fd->SetFileTypeIndex(1)
	}
	if dir != "" {
		folder: rawptr
		if win32.SUCCEEDED(win32.SHCreateItemFromParsingName(wide_z(dir, true), nil, win32.IID_IShellItem, &folder)) && folder != nil {
			fd->SetFolder(cast(^win32.IShellItem)folder)
			com_release(folder)
		}
	}

	if win32.FAILED((cast(^win32.IModalWindow)fd)->Show(w.hwnd)) { // (cancelled, or closed)
		return "", false
	}
	item: ^win32.IShellItem
	if win32.FAILED(fd->GetResult(&item)) || item == nil {
		return "", false
	}
	defer com_release(item)
	name: win32.LPWSTR
	if win32.FAILED(item->GetDisplayName(.FILESYSPATH, &name)) || name == nil {
		return "", false
	}
	defer win32.CoTaskMemFree(name)
	s, err := win32.wstring_to_utf8(cstring16(rawptr(name)), -1, allocator)
	return s, err == nil && len(s) > 0
}

// Asks the user for a folder, in an Explorer window (it blocks until the window is closed). Returns the folder's full path (the caller owns the string),
// or false if it was cancelled.
pick_folder :: proc(w: ^Window, title: string, allocator := context.allocator) -> (path: string, ok: bool) {
	return file_dialog(w, false, title, "", "", allocator)
}

// Asks the user where to save a file, in an Explorer window (it blocks until the window is closed). `suggested` is the name it starts with ("" for none),
// `dir` the folder it opens in ("" lets Windows choose). It asks before replacing a file that is there. Returns the full path (the caller owns the
// string), or false if it was cancelled.
pick_save_file :: proc(w: ^Window, title, suggested, dir: string, allocator := context.allocator) -> (path: string, ok: bool) {
	return file_dialog(w, true, title, suggested, dir, allocator)
}

// Asks whether to save unsaved changes, in the system's message box with Yes / No / Cancel (it blocks until it is answered). `ok` is false when there
// is no such box (it is always there on Windows).
ask_save_changes :: proc(w: ^Window, title, text: string) -> (answer: Save_Answer, ok: bool) {
	owner: win32.HWND = w.hwnd if w != nil else nil
	r := win32.MessageBoxW(owner, win32.utf8_to_wstring(text), win32.utf8_to_wstring(title), win32.MB_YESNOCANCEL | win32.MB_ICONWARNING)
	switch r {
	case win32.IDYES:
		return .Save, true
	case win32.IDNO:
		return .Discard, true
	}
	return .Cancel, true
}

// Asks the user for a file to open, in an Explorer window (it blocks until the window is closed): the files matching `filter_spec`
// ("*.zip", "*.png;*.jpg") listed first, under `filter_name`. `dir` is the folder it opens in ("" lets Windows choose). Returns the
// file's full path (the caller owns the string), or false if it was cancelled.
pick_open_file :: proc(w: ^Window, title, dir, filter_name, filter_spec: string, allocator := context.allocator) -> (path: string, ok: bool) {
	return file_dialog(w, false, title, "", dir, allocator, filter_name = filter_name, filter_spec = filter_spec)
}

// Asks the user for a program, in an Explorer window (it blocks until the window is closed): programs (.exe, .com, .bat, .cmd) are listed first.
// `dir` is the folder it opens in ("" lets Windows choose). Returns the program's full path (the caller owns the string), or false if it was cancelled.
pick_program :: proc(w: ^Window, title, dir: string, allocator := context.allocator) -> (path: string, ok: bool) {
	return file_dialog(w, false, title, "", dir, allocator, program = true)
}

foreign import shell32_ext "system:Shell32.lib"

@(private = "file")
@(default_calling_convention = "system")
foreign shell32_ext {
	ILCreateFromPathW :: proc(path: win32.LPCWSTR) -> rawptr ---
	ILFree :: proc(pidl: rawptr) ---
	SHOpenFolderAndSelectItems :: proc(folder: rawptr, count: u32, items: ^rawptr, flags: u32) -> win32.HRESULT ---
}

// Shows `path` in the system's file manager, the one Windows opens folders with (Explorer, or what has taken its place): a folder is opened; a file's
// folder is opened with the file selected.
show_in_file_manager :: proc(path: string, is_dir: bool) -> bool {
	native, _ := strings.replace_all(path, "/", "\\", context.temp_allocator)
	if is_dir {
		// (no verb: the folder's default one, which a replacement for Explorer registers)
		r := win32.ShellExecuteW(nil, nil, win32.utf8_to_wstring(native), nil, nil, win32.SW_SHOWNORMAL)
		return uintptr(rawptr(r)) > 32
	}
	win32.CoInitializeEx(nil, .APARTMENTTHREADED)
	pidl := ILCreateFromPathW(win32.utf8_to_wstring(native))
	if pidl == nil {
		return false
	}
	defer ILFree(pidl)
	return win32.SUCCEEDED(SHOpenFolderAndSelectItems(pidl, 0, nil, 0))
}

// Starts `program` with the command line `args` (each argument quoted as it needs to be), and does not wait for it.
run_program :: proc(program, args: string) -> bool {
	native, _ := strings.replace_all(program, "/", "\\", context.temp_allocator)
	r := win32.ShellExecuteW(nil, win32.utf8_to_wstring("open"), win32.utf8_to_wstring(native), win32.utf8_to_wstring(args), nil, win32.SW_SHOWNORMAL)
	return uintptr(rawptr(r)) > 32
}

// A question with Yes and No (the system's message box, a warning). ok is false when there is no box to ask with.
ask_yes_no :: proc(w: ^Window, title, text: string) -> (yes: bool, ok: bool) {
	owner: win32.HWND = w.hwnd if w != nil else nil
	r := win32.MessageBoxW(owner, win32.utf8_to_wstring(text), win32.utf8_to_wstring(title), win32.MB_YESNO | win32.MB_ICONWARNING | win32.MB_DEFBUTTON2)
	return r == win32.IDYES, true
}

// Moves a file or a folder (with what is in it) to the Recycle Bin, where it can be restored from. No dialog of the system's is shown.
move_to_trash :: proc(path: string) -> bool {
	// pFrom is a list of paths, each ended by a NUL, the list by another; with backslashes
	native, _ := strings.replace_all(path, "/", "\\", context.temp_allocator)
	wide := win32.utf8_to_utf16(native, context.temp_allocator)
	from := make([]u16, len(wide) + 2, context.temp_allocator)
	copy(from, wide)
	op := win32.SHFILEOPSTRUCTW {
		wFunc  = win32.FO_DELETE,
		pFrom  = cstring16(raw_data(from)),
		fFlags = win32.FOF_ALLOWUNDO | win32.FOF_NOCONFIRMATION | win32.FOF_SILENT | win32.FOF_NOERRORUI,
	}
	return win32.SHFileOperationW(&op) == 0 && !op.fAnyOperationsAborted
}

// ---- the system's fonts ----
// What is installed is asked of GDI (EnumFontFamiliesExW), and a family's bytes come from GDI too (GetFontData on the font it picks for that name), so
// a program needs no font files of its own and no paths into C:\Windows\Fonts.

foreign import gdi32 "system:Gdi32.lib"

@(private = "file")
@(default_calling_convention = "system")
foreign gdi32 {
	GetFontData :: proc(hdc: win32.HDC, table: u32, offset: u32, buffer: rawptr, size: u32) -> u32 ---
	GetTextFaceW :: proc(hdc: win32.HDC, count: i32, name: [^]u16) -> i32 ---
}

@(private = "file")
GDI_ERROR :: 0xFFFFFFFF
@(private = "file")
TTCF_TAG :: 0x66637474 // 'ttcf' as GetFontData wants a tag: the whole collection file
@(private = "file")
TRUETYPE_FONTTYPE :: 0x4
@(private = "file")
FIXED_PITCH :: 1

@(private = "file")
Font_Enum :: struct {
	out:  ^[dynamic]Font_Family,
	seen: ^map[string]bool,
	ctx:  runtime.Context,
}

@(private = "file")
font_enum_proc :: proc "system" (lf: ^win32.ENUMLOGFONTW, tm: ^win32.NEWTEXTMETRICW, font_type: win32.DWORD, param: win32.LPARAM) -> win32.INT {
	fe := cast(^Font_Enum)rawptr(uintptr(param))
	context = fe.ctx
	if font_type & TRUETYPE_FONTTYPE == 0 { // (bitmap and vector fonts cannot be drawn by a TrueType rasterizer)
		return 1
	}
	face := lf.elfLogFont.lfFaceName
	if face[0] == '@' { // the same family set for vertical writing
		return 1
	}
	name, err := win32.wstring_to_utf8(cstring16(raw_data(face[:])), -1, fe.out.allocator)
	if err != nil || name == "" || name in fe.seen^ {
		return 1
	}
	fe.seen^[name] = true
	append(fe.out, Font_Family{name = name, monospace = lf.elfLogFont.lfPitchAndFamily & 3 == FIXED_PITCH})
	return 1
}

// The font families installed on the system that can be drawn (TrueType and OpenType), by name, each once. The caller owns the slice and the names.
list_font_families :: proc(allocator := context.allocator) -> []Font_Family {
	out := make([dynamic]Font_Family, allocator)
	seen := make(map[string]bool, allocator = context.temp_allocator)
	fe := Font_Enum{&out, &seen, context}
	dc := win32.CreateCompatibleDC(nil)
	if dc == nil {
		return out[:]
	}
	defer win32.DeleteDC(dc)
	lf := win32.LOGFONTW{lfCharSet = win32.DEFAULT_CHARSET} // (every family, in every script)
	win32.EnumFontFamiliesExW(dc, &lf, cast(win32.FONTENUMPROCW)font_enum_proc, win32.LPARAM(uintptr(&fe)), 0)
	slice.sort_by(out[:], proc(a, b: Font_Family) -> bool {return a.name < b.name})
	return out[:]
}

// The bytes of a family's regular (or bold) face, as the system has it, for a TrueType rasterizer. false if the family is not installed (Windows would
// quietly give another font for the name: that is checked) or its data cannot be read. A face that lives in a collection (.ttc) comes as the whole
// collection, whose first face is used.
font_data :: proc(family: string, bold := false, allocator := context.allocator) -> (data: []u8, ok: bool) {
	if family == "" || len(family) >= win32.LF_FACESIZE {
		return nil, false
	}
	lf := win32.LOGFONTW {
		lfHeight  = -64,
		lfWeight  = 700 if bold else 400,
		lfCharSet = win32.DEFAULT_CHARSET,
	}
	units := win32.utf8_to_utf16(family, context.temp_allocator)
	copy(lf.lfFaceName[:win32.LF_FACESIZE - 1], units)

	font := win32.CreateFontIndirectW(&lf)
	if font == nil {
		return nil, false
	}
	defer win32.DeleteObject(win32.HGDIOBJ(font))
	dc := win32.CreateCompatibleDC(nil)
	if dc == nil {
		return nil, false
	}
	defer win32.DeleteDC(dc)
	old := win32.SelectObject(dc, win32.HGDIOBJ(font))
	defer win32.SelectObject(dc, old)

	// the font GDI chose must be the one asked for (otherwise it is a stand-in)
	got: [win32.LF_FACESIZE]u16
	n := GetTextFaceW(dc, i32(len(got)), raw_data(got[:]))
	if n <= 0 {
		return nil, false
	}
	chosen, err := win32.wstring_to_utf8(cstring16(raw_data(got[:])), -1, context.temp_allocator)
	if err != nil || !ascii_equal_fold(chosen, family) {
		return nil, false
	}

	table: u32 = TTCF_TAG // a collection first: then the offsets inside are right
	size := GetFontData(dc, table, 0, nil, 0)
	if size == GDI_ERROR || size == 0 {
		table = 0
		size = GetFontData(dc, table, 0, nil, 0)
	}
	if size == GDI_ERROR || size == 0 {
		return nil, false
	}
	buf := make([]u8, int(size), allocator)
	if GetFontData(dc, table, 0, raw_data(buf), size) != size {
		delete(buf, allocator)
		return nil, false
	}
	return buf, true
}

@(private = "file")
ascii_equal_fold :: proc(a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		x, y := a[i], b[i]
		if x >= 'A' && x <= 'Z' {
			x += 32
		}
		if y >= 'A' && y <= 'Z' {
			y += 32
		}
		if x != y {
			return false
		}
	}
	return true
}

// ---- gamepads (XInput) ----

read_gamepads :: proc(pads: ^[input.MAX_PADS]Pad_State) {
	now := time_seconds()
	for i in 0 ..< input.MAX_PADS {
		if now < pad_next_scan[i] {
			continue
		}
		state: win32.XINPUT_STATE
		if win32.XInputGetState(win32.XUSER(i), &state) != .SUCCESS {
			pad_next_scan[i] = now + 1 // not there: look again in a second
			continue
		}
		p := &pads[i]
		p.connected = true
		g := state.Gamepad
		b := g.wButtons
		p.buttons[.Face_Down] = .A in b
		p.buttons[.Face_Right] = .B in b
		p.buttons[.Face_Left] = .X in b
		p.buttons[.Face_Up] = .Y in b
		p.buttons[.Dpad_Up] = .DPAD_UP in b
		p.buttons[.Dpad_Down] = .DPAD_DOWN in b
		p.buttons[.Dpad_Left] = .DPAD_LEFT in b
		p.buttons[.Dpad_Right] = .DPAD_RIGHT in b
		p.buttons[.Left_Shoulder] = .LEFT_SHOULDER in b
		p.buttons[.Right_Shoulder] = .RIGHT_SHOULDER in b
		p.buttons[.Back] = .BACK in b
		p.buttons[.Start] = .START in b
		p.buttons[.Left_Stick] = .LEFT_THUMB in b
		p.buttons[.Right_Stick] = .RIGHT_THUMB in b
		stick :: proc "contextless" (v: win32.SHORT) -> f32 {
			return max(f32(v) / 32767, -1)
		}
		p.axes[.Left_X] = stick(g.sThumbLX)
		p.axes[.Left_Y] = -stick(g.sThumbLY) // up is negative, as on the screen
		p.axes[.Right_X] = stick(g.sThumbRX)
		p.axes[.Right_Y] = -stick(g.sThumbRY)
		p.axes[.Left_Trigger] = f32(g.bLeftTrigger) / 255
		p.axes[.Right_Trigger] = f32(g.bRightTrigger) / 255
		p.buttons[.Left_Trigger] = p.axes[.Left_Trigger] > 0.5
		p.buttons[.Right_Trigger] = p.axes[.Right_Trigger] > 0.5
	}
}

// For whoever draws into the window: the HWND and the HINSTANCE.
native_handle :: proc(w: ^Window) -> Native_Handle {
	return {window = rawptr(w.hwnd), display = rawptr(w.hinstance)}
}

// Seconds since some fixed point (a high resolution clock): for timing frames.
time_seconds :: proc() -> f64 {
	if perf_frequency == 0 {
		win32.QueryPerformanceFrequency(&perf_frequency)
	}
	counter: win32.LARGE_INTEGER
	win32.QueryPerformanceCounter(&counter)
	return f64(counter) / f64(perf_frequency)
}

// ---- making the window -----------------------------------------------------------------------------------

@(private)
ensure_class :: proc() -> bool {
	if class_registered {
		return true
	}
	// physical pixels everywhere, and the window is told when it moves to a monitor with another scale
	win32.SetProcessDpiAwarenessContext(win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
	wc := win32.WNDCLASSEXW {
		cbSize        = size_of(win32.WNDCLASSEXW),
		style         = win32.CS_HREDRAW | win32.CS_VREDRAW | win32.CS_OWNDC,
		lpfnWndProc   = wnd_proc,
		hInstance     = win32.HINSTANCE(win32.GetModuleHandleW(nil)),
		hCursor       = win32.LoadCursorW(nil, transmute(cstring16)win32.IDC_ARROW),
		lpszClassName = win32.utf8_to_wstring(CLASS_NAME),
	}
	if win32.RegisterClassExW(&wc) == 0 {
		return false
	}
	class_registered = true
	return true
}

// The window style the flags ask for. Without decorations the caption is dropped but the thick frame stays: Windows then still resizes, snaps and
// maximizes the window, and wnd_proc (WM_NCCALCSIZE) makes the client area cover all of it so that nothing of the frame shows.
@(private)
window_style :: proc(flags: Window_Flags) -> win32.DWORD {
	style := win32.DWORD(win32.WS_OVERLAPPEDWINDOW)
	if .No_Decorations in flags {
		style &~= win32.DWORD(win32.WS_CAPTION)
	}
	if .Fixed_Size in flags {
		style &~= win32.DWORD(win32.WS_THICKFRAME | win32.WS_MAXIMIZEBOX)
	}
	return style
}

// The size of the whole window for a client area of width x height. `dpi` 0: at the system's scale. Without decorations there is no frame to add.
@(private)
outer_size :: proc(flags: Window_Flags, style: win32.DWORD, width, height: int, dpi: u32) -> (cx, cy: i32) {
	frame := win32.RECT{0, 0, i32(width), i32(height)}
	if .No_Decorations not_in flags {
		if dpi == 0 {
			win32.AdjustWindowRectEx(&frame, style, false, 0)
		} else {
			win32.AdjustWindowRectExForDpi(&frame, style, false, 0, dpi)
		}
	}
	return frame.right - frame.left, frame.bottom - frame.top
}

// Puts the style (and the decorations) that w.desc.flags ask for on a window that exists, keeping the client area's size.
@(private)
apply_style :: proc(w: ^Window) {
	if w.hwnd == nil {
		return
	}
	flags := w.desc.flags
	w.decorated = .No_Decorations not_in flags && !w.fullscreen
	style := window_style(flags)
	keep := win32.LONG_PTR(win32.WS_VISIBLE | win32.WS_MAXIMIZE | win32.WS_MINIMIZE) // state, not look
	if w.fullscreen { // the window has no frame now: what it gets back is saved
		w.saved_style = (w.saved_style & keep) | win32.LONG_PTR(style)
		return
	}
	current := win32.GetWindowLongPtrW(w.hwnd, win32.GWL_STYLE)
	win32.SetWindowLongPtrW(w.hwnd, win32.GWL_STYLE, (current & keep) | win32.LONG_PTR(style))
	changed :: win32.SWP_NOMOVE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE | win32.SWP_FRAMECHANGED
	if win32.IsZoomed(w.hwnd) {
		win32.SetWindowPos(w.hwnd, nil, 0, 0, 0, 0, changed | win32.SWP_NOSIZE)
	} else {
		cx, cy := outer_size(flags, style, w.size.x, w.size.y, max(win32.GetDpiForWindow(w.hwnd), 96))
		win32.SetWindowPos(w.hwnd, nil, 0, 0, cx, cy, changed)
	}
}

@(private)
make_hwnd :: proc(w: ^Window, desc: Window_Desc, pos: Maybe([2]int)) -> bool {
	w.desc = desc
	w.hinstance = win32.HINSTANCE(win32.GetModuleHandleW(nil))
	style := window_style(desc.flags)
	ex_style := win32.DWORD(win32.WS_EX_TOPMOST) if .Always_On_Top in desc.flags else 0

	// the outer size for the client size asked, at the system's scale (corrected below when the monitor differs)
	cx, cy := outer_size(desc.flags, style, max(desc.width, 1), max(desc.height, 1), 0)

	x, y := win32.CW_USEDEFAULT, win32.CW_USEDEFAULT
	if p, has := pos.?; has {
		x, y = i32(p.x), i32(p.y)
	}
	w.hwnd = win32.CreateWindowExW(
		ex_style,
		win32.utf8_to_wstring(CLASS_NAME),
		win32.utf8_to_wstring(desc.title),
		style,
		x,
		y,
		cx,
		cy,
		nil,
		nil,
		w.hinstance,
		rawptr(w),
	)
	if w.hwnd == nil {
		return false
	}

	// now that the monitor is known: the right outer size for its scale
	dpi := win32.GetDpiForWindow(w.hwnd)
	w.dpi_scale = f32(dpi) / 96
	cx, cy = outer_size(desc.flags, style, max(desc.width, 1), max(desc.height, 1), dpi)
	win32.SetWindowPos(w.hwnd, nil, 0, 0, cx, cy, win32.SWP_NOMOVE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE)

	client: win32.RECT
	win32.GetClientRect(w.hwnd, &client)
	w.size = {int(client.right - client.left), int(client.bottom - client.top)}
	w.minimized = false
	w.maximized = false
	w.pending_maximize = false
	w.decorated = .No_Decorations not_in desc.flags
	w.close_requested = false
	w.focused = win32.GetForegroundWindow() == w.hwnd

	if c, has := desc.background.?; has && w.background == nil {
		w.background = win32.CreateSolidBrush(win32.RGB(c.r, c.g, c.b))
	}
	if .Hidden not_in desc.flags && .No_Activate in desc.flags {
		// behind everything, and the focus left where it is (a maximized window is not maximized: SW_SHOWMAXIMIZED activates)
		win32.SetWindowPos(w.hwnd, win32.HWND_BOTTOM, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE)
		win32.ShowWindow(w.hwnd, win32.SW_SHOWNOACTIVATE)
		if w.background != nil {
			win32.UpdateWindow(w.hwnd)
		}
	} else if .Hidden not_in desc.flags {
		win32.ShowWindow(w.hwnd, win32.SW_SHOWMAXIMIZED if .Maximized in desc.flags else win32.SW_SHOW) // (WM_SIZE sets w.maximized and w.size)
		if w.background != nil {
			win32.UpdateWindow(w.hwnd) // painted now, while the program is still starting up (no message loop runs yet)
		}
	} else {
		w.pending_maximize = .Maximized in desc.flags
	}
	if .Fullscreen in desc.flags {
		set_fullscreen(w, true)
	}
	w.events = {} // what the creation itself stirred up is not news
	clear(&w.input)
	return true
}

@(private)
destroy_hwnd :: proc(w: ^Window) {
	stop_background(w)
	if w.hwnd != nil {
		win32.DestroyWindow(w.hwnd)
		w.hwnd = nil
	}
}

// ---- the message procedure -----------------------------------------------------------------------------------

@(private)
wnd_proc :: proc "system" (hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) -> win32.LRESULT {
	context = runtime.default_context()

	w: ^Window
	if msg == win32.WM_NCCREATE {
		cs := (^win32.CREATESTRUCTW)(rawptr(uintptr(lparam)))
		w = (^Window)(cs.lpCreateParams)
		win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, win32.LONG_PTR(uintptr(w)))
	} else {
		w = (^Window)(rawptr(uintptr(win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA))))
	}
	if w == nil {
		return win32.DefWindowProcW(hwnd, msg, wparam, lparam)
	}

	switch msg {
	case win32.WM_CLOSE:
		w.close_requested = true
		w.events += {.Close_Requested}
		return 0 // the program decides whether to destroy the window

	case win32.WM_NCDESTROY:
		win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, 0)

	case win32.WM_ERASEBKGND:
		if w != nil && w.background != nil { // (before the first frame: the colour asked for, not a white or empty window)
			r: win32.RECT
			win32.GetClientRect(hwnd, &r)
			win32.FillRect(win32.HDC(wparam), &r, w.background)
		}
		return 1 // the graphics API draws everything: no flicker from a background

	case win32.WM_SIZE:
		if wparam == win32.SIZE_MINIMIZED {
			if !w.minimized {
				w.minimized = true
				w.events += {.Minimized}
			}
		} else {
			if w.minimized {
				w.minimized = false
				w.events += {.Restored}
			}
			w.maximized = wparam == win32.SIZE_MAXIMIZED
			size := [2]int{int(win32.LOWORD(lparam)), int(win32.HIWORD(lparam))}
			if size != w.size {
				w.size = size
				w.events += {.Resized}
			}
		}
		return 0

	case win32.WM_SETFOCUS:
		w.focused = true
		w.events += {.Focus_Gained}
		return 0

	case win32.WM_KILLFOCUS:
		w.focused = false
		w.events += {.Focus_Lost}
		queue_input(w, {kind = .Focus_Lost})
		return 0

	case win32.WM_DPICHANGED:
		w.dpi_scale = f32(win32.HIWORD(wparam)) / 96
		w.events += {.Dpi_Changed}
		r := (^win32.RECT)(rawptr(uintptr(lparam)))
		win32.SetWindowPos(hwnd, nil, r.left, r.top, r.right - r.left, r.bottom - r.top, win32.SWP_NOZORDER | win32.SWP_NOACTIVATE)
		return 0

	case win32.WM_GETMINMAXINFO:
		if w.desc.min_width > 0 || w.desc.min_height > 0 {
			mmi := (^win32.MINMAXINFO)(rawptr(uintptr(lparam)))
			style := win32.DWORD(win32.GetWindowLongPtrW(hwnd, win32.GWL_STYLE))
			cx, cy := outer_size(w.desc.flags, style, w.desc.min_width, w.desc.min_height, max(win32.GetDpiForWindow(hwnd), 96))
			mmi.ptMinTrackSize = {cx, cy}
			return 0
		}

	// ---- a window without decorations: the client area is all of the window ----
	case win32.WM_NCCALCSIZE:
		if .No_Decorations in w.desc.flags {
			if wparam != 0 && bool(win32.IsZoomed(hwnd)) {
				// a maximized window with a frame is made bigger than the screen by that frame: take it off again
				params := (^win32.NCCALCSIZE_PARAMS)(rawptr(uintptr(lparam)))
				dpi := max(win32.GetDpiForWindow(hwnd), 96)
				padding := win32.GetSystemMetricsForDpi(win32.SM_CXPADDEDBORDER, dpi)
				fx := win32.GetSystemMetricsForDpi(win32.SM_CXFRAME, dpi) + padding
				fy := win32.GetSystemMetricsForDpi(win32.SM_CYFRAME, dpi) + padding
				r := &params.rgrc[0]
				r.left += fx
				r.right -= fx
				r.top += fy
				r.bottom -= fy
			}
			return 0
		}

	case win32.WM_NCHITTEST:
		if .No_Decorations in w.desc.flags {
			return nc_hit_test(w, hwnd, lparam)
		}

	case win32.WM_NCMOUSEMOVE:
		if .No_Decorations in w.desc.flags {
			// over the program's own title bar (which the window system owns): the program still wants to know where the pointer is
			p := win32.POINT{win32.GET_X_LPARAM(lparam), win32.GET_Y_LPARAM(lparam)}
			win32.ScreenToClient(hwnd, &p)
			queue_input(w, {kind = .Mouse_Move, x = f32(p.x), y = f32(p.y)})
		}

	// ---- keyboard ----
	case win32.WM_KEYDOWN, win32.WM_SYSKEYDOWN, win32.WM_KEYUP, win32.WM_SYSKEYUP:
		down := msg == win32.WM_KEYDOWN || msg == win32.WM_SYSKEYDOWN
		if key := translate_key(wparam, lparam); key != .None {
			if !down {
				queue_input(w, {kind = .Key_Up, key = key})
			} else if lparam & (1 << 30) != 0 {
				queue_input(w, {kind = .Key_Repeat, key = key})
			} else {
				queue_input(w, {kind = .Key_Down, key = key})
			}
		}
		if msg == win32.WM_SYSKEYDOWN || msg == win32.WM_SYSKEYUP {
			break // Windows still gets Alt+F4 and Alt+Space
		}
		return 0

	case win32.WM_SYSCOMMAND:
		if wparam & 0xFFF0 == win32.SC_KEYMENU && lparam == 0 {
			return 0 // a tap of Alt must not freeze the window in a menu loop (there is no menu)
		}

	case win32.WM_SYSCHAR:
		if wparam != ' ' {
			return 0 // Alt + a letter: no beep
		}

	case win32.WM_CHAR:
		c := u32(wparam)
		switch {
		case c >= 0xD800 && c <= 0xDBFF:
			w.high_surrogate = u16(c)
		case c >= 0xDC00 && c <= 0xDFFF:
			if w.high_surrogate != 0 {
				cp := 0x10000 + ((u32(w.high_surrogate) - 0xD800) << 10) + (c - 0xDC00)
				w.high_surrogate = 0
				queue_input(w, {kind = .Char, char = rune(cp)})
			}
		case c >= 32 && c != 127: // the control characters (Tab, Enter, Backspace) are keys, not text
			queue_input(w, {kind = .Char, char = rune(c)})
		}
		return 0

	// ---- mouse ----
	case win32.WM_SETCURSOR:
		if win32.LOWORD(lparam) == win32.HTCLIENT {
			win32.SetCursor(cursor_handle(w)) // (the arrow, a hand, ... or none)
			return 1
		}

	case win32.WM_MOUSELEAVE:
		w.mouse_inside = false
		return 0

	case win32.WM_MOUSEMOVE:
		if !w.mouse_inside {
			w.mouse_inside = true
			track := win32.TRACKMOUSEEVENT {
				cbSize    = size_of(win32.TRACKMOUSEEVENT),
				dwFlags   = win32.TME_LEAVE, // (to be told when it leaves)
				hwndTrack = hwnd,
			}
			win32.TrackMouseEvent(&track)
		}
		queue_input(w, {kind = .Mouse_Move, x = f32(win32.GET_X_LPARAM(lparam)), y = f32(win32.GET_Y_LPARAM(lparam))})
		return 0

	case win32.WM_LBUTTONDOWN, win32.WM_RBUTTONDOWN, win32.WM_MBUTTONDOWN, win32.WM_XBUTTONDOWN:
		button := mouse_button(msg, wparam)
		queue_input(w, {kind = .Mouse_Down, button = button})
		win32.SetCapture(hwnd) // a drag that leaves the window still ends here
		return 1 if msg == win32.WM_XBUTTONDOWN else 0

	case win32.WM_LBUTTONUP, win32.WM_RBUTTONUP, win32.WM_MBUTTONUP, win32.WM_XBUTTONUP:
		button := mouse_button(msg, wparam)
		queue_input(w, {kind = .Mouse_Up, button = button})
		held := win32.MK_LBUTTON | win32.MK_RBUTTON | win32.MK_MBUTTON | win32.MK_XBUTTON1 | win32.MK_XBUTTON2
		if wparam & win32.WPARAM(held) == 0 {
			win32.ReleaseCapture()
		}
		return 1 if msg == win32.WM_XBUTTONUP else 0

	case win32.WM_MOUSEWHEEL:
		queue_input(w, {kind = .Wheel, y = f32(win32.GET_WHEEL_DELTA_WPARAM(wparam)) / 120})
		return 0

	case win32.WM_MOUSEHWHEEL:
		queue_input(w, {kind = .Wheel, x = f32(win32.GET_WHEEL_DELTA_WPARAM(wparam)) / 120})
		return 0
	}
	return win32.DefWindowProcW(hwnd, msg, wparam, lparam)
}

// What the pointer is over in a window without decorations (WM_NCHITTEST): the resize handles along the edges, then what the program says its title bar is.
@(private)
nc_hit_test :: proc(w: ^Window, hwnd: win32.HWND, lparam: win32.LPARAM) -> win32.LRESULT {
	p := win32.POINT{win32.GET_X_LPARAM(lparam), win32.GET_Y_LPARAM(lparam)} // on the screen
	win32.ScreenToClient(hwnd, &p)
	x, y := int(p.x), int(p.y)

	if .Fixed_Size not_in w.desc.flags && !w.fullscreen && !bool(win32.IsZoomed(hwnd)) {
		border := int(RESIZE_BORDER * max(win32.GetDpiForWindow(hwnd), 96) / 96)
		left, right := x < border, x >= w.size.x - border
		top, bottom := y < border, y >= w.size.y - border
		switch {
		case top && left:
			return win32.HTTOPLEFT
		case top && right:
			return win32.HTTOPRIGHT
		case bottom && left:
			return win32.HTBOTTOMLEFT
		case bottom && right:
			return win32.HTBOTTOMRIGHT
		case left:
			return win32.HTLEFT
		case right:
			return win32.HTRIGHT
		case top:
			return win32.HTTOP
		case bottom:
			return win32.HTBOTTOM
		}
	}
	if w.hit_test != nil && w.hit_test(w, x, y, w.hit_test_user) == .Caption {
		return win32.HTCAPTION
	}
	return win32.HTCLIENT
}

@(private)
mouse_button :: proc "contextless" (msg: win32.UINT, wparam: win32.WPARAM) -> input.Mouse_Button {
	switch msg {
	case win32.WM_LBUTTONDOWN, win32.WM_LBUTTONUP:
		return .Left
	case win32.WM_RBUTTONDOWN, win32.WM_RBUTTONUP:
		return .Right
	case win32.WM_MBUTTONDOWN, win32.WM_MBUTTONUP:
		return .Middle
	}
	switch win32.GET_XBUTTON_WPARAM(wparam) {
	case win32.XBUTTON1:
		return .Back
	case win32.XBUTTON2:
		return .Forward
	}
	return .Extra
}

// ---- keys ----------------------------------------------------------------------------------------------------

// A Windows virtual key (with the scan code and the "extended" bit that tell left from right) as the input package's key.
@(private)
translate_key :: proc "contextless" (wparam: win32.WPARAM, lparam: win32.LPARAM) -> input.Key {
	vk := u32(wparam)
	scan := u32(lparam >> 16) & 0xFF
	extended := lparam & (1 << 24) != 0

	switch vk {
	case 'A' ..= 'Z':
		return input.Key(u16(input.Key.A) + u16(vk - 'A'))
	case '0' ..= '9':
		return input.Key(u16(input.Key.Num_0) + u16(vk - '0'))
	case win32.VK_F1 ..= win32.VK_F24:
		return input.Key(u16(input.Key.F1) + u16(vk - win32.VK_F1))
	case win32.VK_NUMPAD0 ..= win32.VK_NUMPAD9:
		return input.Key(u16(input.Key.Kp_0) + u16(vk - win32.VK_NUMPAD0))

	case win32.VK_SHIFT:
		if win32.MapVirtualKeyW(scan, win32.MAPVK_VSC_TO_VK_EX) == win32.VK_RSHIFT {
			return .Right_Shift
		}
		return .Left_Shift
	case win32.VK_LSHIFT:
		return .Left_Shift
	case win32.VK_RSHIFT:
		return .Right_Shift
	case win32.VK_CONTROL:
		return .Right_Ctrl if extended else .Left_Ctrl
	case win32.VK_LCONTROL:
		return .Left_Ctrl
	case win32.VK_RCONTROL:
		return .Right_Ctrl
	case win32.VK_MENU:
		return .Right_Alt if extended else .Left_Alt
	case win32.VK_LMENU:
		return .Left_Alt
	case win32.VK_RMENU:
		return .Right_Alt
	case win32.VK_LWIN:
		return .Left_Super
	case win32.VK_RWIN:
		return .Right_Super

	case win32.VK_RETURN:
		return .Kp_Enter if extended else .Enter
	case win32.VK_ESCAPE:
		return .Escape
	case win32.VK_TAB:
		return .Tab
	case win32.VK_SPACE:
		return .Space
	case win32.VK_BACK:
		return .Backspace
	case win32.VK_DELETE:
		return .Delete
	case win32.VK_INSERT:
		return .Insert
	case win32.VK_HOME:
		return .Home
	case win32.VK_END:
		return .End
	case win32.VK_PRIOR:
		return .Page_Up
	case win32.VK_NEXT:
		return .Page_Down
	case win32.VK_LEFT:
		return .Left
	case win32.VK_RIGHT:
		return .Right
	case win32.VK_UP:
		return .Up
	case win32.VK_DOWN:
		return .Down
	case win32.VK_CAPITAL:
		return .Caps_Lock
	case win32.VK_SCROLL:
		return .Scroll_Lock
	case win32.VK_NUMLOCK:
		return .Num_Lock
	case win32.VK_SNAPSHOT:
		return .Print_Screen
	case win32.VK_PAUSE:
		return .Pause
	case win32.VK_APPS:
		return .Menu

	case win32.VK_OEM_7:
		return .Apostrophe
	case win32.VK_OEM_COMMA:
		return .Comma
	case win32.VK_OEM_MINUS:
		return .Minus
	case win32.VK_OEM_PERIOD:
		return .Period
	case win32.VK_OEM_2:
		return .Slash
	case win32.VK_OEM_1:
		return .Semicolon
	case win32.VK_OEM_PLUS:
		return .Equal
	case win32.VK_OEM_4:
		return .Left_Bracket
	case win32.VK_OEM_5:
		return .Backslash
	case win32.VK_OEM_6:
		return .Right_Bracket
	case win32.VK_OEM_3:
		return .Grave

	case win32.VK_DECIMAL:
		return .Kp_Decimal
	case win32.VK_DIVIDE:
		return .Kp_Divide
	case win32.VK_MULTIPLY:
		return .Kp_Multiply
	case win32.VK_SUBTRACT:
		return .Kp_Subtract
	case win32.VK_ADD:
		return .Kp_Add
	}
	return .None
}
