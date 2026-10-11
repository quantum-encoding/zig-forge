//! Win32 declarations terminal_mux needs on Windows: ConPTY, job objects,
//! pipes, console modes, Toolhelp32 and Winsock (AF_UNIX streams + WSAPoll).
//!
//! Zig 0.16's std declares almost none of these (it talks to ntdll), so they
//! are declared here, against the Windows SDK headers named beside each group.
//! Only `CreateProcessW` comes from std, because std already declares that
//! symbol. Nothing in this file is referenced on other targets.

const std = @import("std");
const windows = std.os.windows;

pub const HANDLE = windows.HANDLE;
pub const BOOL = c_int;
pub const DWORD = u32;
pub const WORD = u16;
pub const UINT = c_uint;
pub const HRESULT = i32;
pub const HPCON = *anyopaque;
pub const SOCKET = usize;

pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;
pub const INVALID_HANDLE_VALUE: usize = std.math.maxInt(usize);
pub const INVALID_SOCKET: SOCKET = std.math.maxInt(usize);
pub const SOCKET_ERROR: c_int = -1;

// ── processes, pipes, ConPTY (processthreadsapi.h, consoleapi.h) ─────────────

pub const COORD = extern struct { X: i16, Y: i16 };
pub const SMALL_RECT = extern struct { Left: i16, Top: i16, Right: i16, Bottom: i16 };

pub const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
pub const STARTUPINFOW = windows.STARTUPINFOW;
pub const PROCESS_INFORMATION = windows.PROCESS.INFORMATION;
pub const CreateProcessFlags = windows.CreateProcessFlags;
pub const CreateProcessW = windows.kernel32.CreateProcessW;

pub const STARTUPINFOEXW = extern struct {
    StartupInfo: STARTUPINFOW,
    lpAttributeList: ?*anyopaque,
};

pub const STARTF_USESTDHANDLES: DWORD = 0x0000_0100;
pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x0002_0016;
pub const STILL_ACTIVE: DWORD = 259;
pub const INFINITE: DWORD = 0xFFFF_FFFF;
pub const WAIT_OBJECT_0: DWORD = 0;
pub const WAIT_TIMEOUT: DWORD = 0x102;

pub extern "kernel32" fn CreatePipe(hReadPipe: *HANDLE, hWritePipe: *HANDLE, lpPipeAttributes: ?*const SECURITY_ATTRIBUTES, nSize: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreatePseudoConsole(size: COORD, hInput: HANDLE, hOutput: HANDLE, dwFlags: DWORD, phPC: *HPCON) callconv(.winapi) HRESULT;
pub extern "kernel32" fn ResizePseudoConsole(hPC: HPCON, size: COORD) callconv(.winapi) HRESULT;
pub extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;
pub extern "kernel32" fn InitializeProcThreadAttributeList(lpAttributeList: ?*anyopaque, dwAttributeCount: DWORD, dwFlags: DWORD, lpSize: *usize) callconv(.winapi) BOOL;
pub extern "kernel32" fn UpdateProcThreadAttribute(lpAttributeList: *anyopaque, dwFlags: DWORD, Attribute: usize, lpValue: ?*anyopaque, cbSize: usize, lpPreviousValue: ?*anyopaque, lpReturnSize: ?*usize) callconv(.winapi) BOOL;
pub extern "kernel32" fn DeleteProcThreadAttributeList(lpAttributeList: *anyopaque) callconv(.winapi) void;
pub extern "kernel32" fn ResumeThread(hThread: HANDLE) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetExitCodeProcess(hProcess: HANDLE, lpExitCode: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: UINT) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn WaitForMultipleObjects(nCount: DWORD, lpHandles: [*]const HANDLE, bWaitAll: BOOL, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: DWORD, lpNumberOfBytesRead: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: DWORD, lpNumberOfBytesWritten: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateEventW(lpEventAttributes: ?*const SECURITY_ATTRIBUTES, bManualReset: BOOL, bInitialState: BOOL, lpName: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
pub extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;
pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

// ── job objects (jobapi2.h, winnt.h) ─────────────────────────────────────────

pub const JobObjectExtendedLimitInformation: c_int = 9;
pub const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: DWORD = 0x0000_2000;

pub const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: i64 = 0,
    PerJobUserTimeLimit: i64 = 0,
    LimitFlags: DWORD = 0,
    MinimumWorkingSetSize: usize = 0,
    MaximumWorkingSetSize: usize = 0,
    ActiveProcessLimit: DWORD = 0,
    Affinity: usize = 0,
    PriorityClass: DWORD = 0,
    SchedulingClass: DWORD = 0,
};

pub const IO_COUNTERS = extern struct {
    ReadOperationCount: u64 = 0,
    WriteOperationCount: u64 = 0,
    OtherOperationCount: u64 = 0,
    ReadTransferCount: u64 = 0,
    WriteTransferCount: u64 = 0,
    OtherTransferCount: u64 = 0,
};

pub const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION = .{},
    IoInfo: IO_COUNTERS = .{},
    ProcessMemoryLimit: usize = 0,
    JobMemoryLimit: usize = 0,
    PeakProcessMemoryUsed: usize = 0,
    PeakJobMemoryUsed: usize = 0,
};

pub extern "kernel32" fn CreateJobObjectW(lpJobAttributes: ?*const SECURITY_ATTRIBUTES, lpName: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetInformationJobObject(hJob: HANDLE, JobObjectInformationClass: c_int, lpJobObjectInformation: *const anyopaque, cbJobObjectInformationLength: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn AssignProcessToJobObject(hJob: HANDLE, hProcess: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn TerminateJobObject(hJob: HANDLE, uExitCode: UINT) callconv(.winapi) BOOL;

// ── process table (tlhelp32.h, processthreadsapi.h) ─────────────────────────

pub const TH32CS_SNAPPROCESS: DWORD = 0x0000_0002;
pub const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;
pub const SYNCHRONIZE: DWORD = 0x0010_0000;

pub const PROCESSENTRY32W = extern struct {
    dwSize: DWORD,
    cntUsage: DWORD = 0,
    th32ProcessID: DWORD = 0,
    th32DefaultHeapID: usize = 0,
    th32ModuleID: DWORD = 0,
    cntThreads: DWORD = 0,
    th32ParentProcessID: DWORD = 0,
    pcPriClassBase: i32 = 0,
    dwFlags: DWORD = 0,
    szExeFile: [260]u16 = @splat(0),
};

pub const FILETIME = extern struct { dwLowDateTime: DWORD = 0, dwHighDateTime: DWORD = 0 };

pub extern "kernel32" fn CreateToolhelp32Snapshot(dwFlags: DWORD, th32ProcessID: DWORD) callconv(.winapi) HANDLE;
pub extern "kernel32" fn Process32FirstW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
pub extern "kernel32" fn Process32NextW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
pub extern "kernel32" fn OpenProcess(dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwProcessId: DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn QueryFullProcessImageNameW(hProcess: HANDLE, dwFlags: DWORD, lpExeName: [*]u16, lpdwSize: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetProcessTimes(hProcess: HANDLE, lpCreationTime: *FILETIME, lpExitTime: *FILETIME, lpKernelTime: *FILETIME, lpUserTime: *FILETIME) callconv(.winapi) BOOL;

// ── console (consoleapi.h, wincon.h, processenv.h) ───────────────────────────

pub const STD_INPUT_HANDLE: DWORD = @bitCast(@as(i32, -10));
pub const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
pub const STD_ERROR_HANDLE: DWORD = @bitCast(@as(i32, -12));

pub const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
pub const ENABLE_LINE_INPUT: DWORD = 0x0002;
pub const ENABLE_ECHO_INPUT: DWORD = 0x0004;
pub const ENABLE_WINDOW_INPUT: DWORD = 0x0008;
pub const ENABLE_MOUSE_INPUT: DWORD = 0x0010;
pub const ENABLE_VIRTUAL_TERMINAL_INPUT: DWORD = 0x0200;
pub const ENABLE_PROCESSED_OUTPUT: DWORD = 0x0001;
pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;
pub const DISABLE_NEWLINE_AUTO_RETURN: DWORD = 0x0008;
pub const CP_UTF8: UINT = 65001;

pub const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: COORD,
    dwCursorPosition: COORD,
    wAttributes: WORD,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: COORD,
};

pub const CTRL_C_EVENT: DWORD = 0;
pub const CTRL_BREAK_EVENT: DWORD = 1;
pub const CTRL_CLOSE_EVENT: DWORD = 2;
pub const CTRL_LOGOFF_EVENT: DWORD = 5;
pub const CTRL_SHUTDOWN_EVENT: DWORD = 6;
pub const HandlerRoutine = *const fn (DWORD) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetConsoleMode(hConsoleHandle: HANDLE, dwMode: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOutput: HANDLE, lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetConsoleCP() callconv(.winapi) UINT;
pub extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) UINT;
pub extern "kernel32" fn SetConsoleCP(wCodePageID: UINT) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetConsoleOutputCP(wCodePageID: UINT) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetConsoleCtrlHandler(HandlerRoutine: ?HandlerRoutine, Add: BOOL) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetEnvironmentStringsW() callconv(.winapi) ?[*]u16;
pub extern "kernel32" fn FreeEnvironmentStringsW(penv: [*]u16) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: ?[*]u16, nSize: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetCurrentDirectoryW(nBufferLength: DWORD, lpBuffer: ?[*]u16) callconv(.winapi) DWORD;

// ── files (fileapi.h) ────────────────────────────────────────────────────────

pub const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFF_FFFF;
pub const FILE_ATTRIBUTE_DIRECTORY: DWORD = 0x10;
pub const ERROR_FILE_NOT_FOUND: DWORD = 2;
pub const ERROR_PATH_NOT_FOUND: DWORD = 3;
pub const ERROR_BROKEN_PIPE: DWORD = 109;

pub extern "kernel32" fn GetFileAttributesW(lpFileName: [*:0]const u16) callconv(.winapi) DWORD;
pub extern "kernel32" fn DeleteFileW(lpFileName: [*:0]const u16) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateDirectoryW(lpPathName: [*:0]const u16, lpSecurityAttributes: ?*const SECURITY_ATTRIBUTES) callconv(.winapi) BOOL;

// ── Winsock (winsock2.h, afunix.h) ───────────────────────────────────────────

pub const SOL_SOCKET: c_int = 0xffff;
pub const SO_SNDTIMEO: c_int = 0x1005;
pub const SO_RCVTIMEO: c_int = 0x1006;
pub const AF_UNIX: c_int = 1;
pub const SOCK_STREAM: c_int = 1;
pub const SD_SEND: c_int = 1;
pub const SD_BOTH: c_int = 2;
pub const FIONBIO: c_long = @bitCast(@as(u32, 0x8004_667E));

pub const POLLERR: i16 = 0x0001;
pub const POLLHUP: i16 = 0x0002;
pub const POLLNVAL: i16 = 0x0004;
pub const POLLWRNORM: i16 = 0x0010;
pub const POLLRDNORM: i16 = 0x0100;
pub const POLLRDBAND: i16 = 0x0200;

pub const WSAEINTR: c_int = 10004;
pub const WSAEWOULDBLOCK: c_int = 10035;
pub const WSAENOTSOCK: c_int = 10038;
pub const WSAEADDRINUSE: c_int = 10048;
pub const WSAECONNABORTED: c_int = 10053;
pub const WSAECONNRESET: c_int = 10054;
pub const WSAENOTCONN: c_int = 10057;
pub const WSAESHUTDOWN: c_int = 10058;
pub const WSAETIMEDOUT: c_int = 10060;
pub const WSAECONNREFUSED: c_int = 10061;

/// afunix.h: `UNIX_PATH_MAX` is 108, as on Linux.
pub const sockaddr_un = extern struct {
    family: u16 = @intCast(AF_UNIX),
    path: [108]u8 = @splat(0),
};

/// WSADATA differs in field order between Win32 and Win64; nothing here
/// reads it, so it is an opaque buffer at least as large as either.
pub const WSADATA = extern struct { bytes: [512]u8 align(8) = undefined };

pub const WSAPOLLFD = extern struct {
    fd: SOCKET,
    events: i16,
    revents: i16,
};

pub extern "ws2_32" fn WSAStartup(wVersionRequired: WORD, lpWSAData: *WSADATA) callconv(.winapi) c_int;
pub extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;
pub extern "ws2_32" fn WSAPoll(fdArray: [*]WSAPOLLFD, fds: c_ulong, timeout: c_int) callconv(.winapi) c_int;
pub extern "ws2_32" fn socket(af: c_int, @"type": c_int, protocol: c_int) callconv(.winapi) SOCKET;
pub extern "ws2_32" fn bind(s: SOCKET, name: *const anyopaque, namelen: c_int) callconv(.winapi) c_int;
pub extern "ws2_32" fn listen(s: SOCKET, backlog: c_int) callconv(.winapi) c_int;
pub extern "ws2_32" fn accept(s: SOCKET, addr: ?*anyopaque, addrlen: ?*c_int) callconv(.winapi) SOCKET;
pub extern "ws2_32" fn connect(s: SOCKET, name: *const anyopaque, namelen: c_int) callconv(.winapi) c_int;
pub extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
pub extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
pub extern "ws2_32" fn shutdown(s: SOCKET, how: c_int) callconv(.winapi) c_int;
pub extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) c_int;
pub extern "ws2_32" fn ioctlsocket(s: SOCKET, cmd: c_long, argp: *c_ulong) callconv(.winapi) c_int;
pub extern "ws2_32" fn setsockopt(s: SOCKET, level: c_int, optname: c_int, optval: [*]const u8, optlen: c_int) callconv(.winapi) c_int;

// ── synchronisation, console input (synchapi.h, consoleapi.h) ────────────────

pub const SRWLOCK = extern struct { ptr: ?*anyopaque = null };
pub extern "kernel32" fn AcquireSRWLockExclusive(SRWLock: *SRWLOCK) callconv(.winapi) void;
pub extern "kernel32" fn ReleaseSRWLockExclusive(SRWLock: *SRWLOCK) callconv(.winapi) void;
pub extern "kernel32" fn ReadConsoleW(hConsoleInput: HANDLE, lpBuffer: [*]u16, nNumberOfCharsToRead: DWORD, lpNumberOfCharsRead: *DWORD, pInputControl: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(.winapi) BOOL;
pub extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(.winapi) BOOL;
pub extern "shell32" fn CommandLineToArgvW(lpCmdLine: [*:0]const u16, pNumArgs: *c_int) callconv(.winapi) ?[*][*:0]u16;
pub extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn IsProcessInJob(ProcessHandle: HANDLE, JobHandle: ?HANDLE, Result: *BOOL) callconv(.winapi) BOOL;
