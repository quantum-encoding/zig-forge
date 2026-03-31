# Terminal Multiplexer (terminal_mux) - Architecture Design

A high-performance terminal multiplexer written in Zig, designed as a modern tmux alternative
with GPU-accelerated rendering and native Zig configuration.

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              User Terminal                               │
│                          (stdin/stdout/sigwinch)                        │
└─────────────────────────────┬───────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                           Terminal Mux Server                            │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │                        Session Manager                            │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐               │   │
│  │  │  Session 1  │  │  Session 2  │  │  Session N  │               │   │
│  │  │  ┌───────┐  │  │  ┌───────┐  │  │  ┌───────┐  │               │   │
│  │  │  │ Pane1 │  │  │  │ Pane1 │  │  │  │ Pane1 │  │               │   │
│  │  │  ├───────┤  │  │  ├───────┤  │  │  ├───────┤  │               │   │
│  │  │  │ Pane2 │  │  │  │ Pane2 │  │  │  │ Pane2 │  │               │   │
│  │  │  └───────┘  │  │  └───────┘  │  │  └───────┘  │               │   │
│  │  └─────────────┘  └─────────────┘  └─────────────┘               │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                          │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────┐  │
│  │  PTY Manager    │  │   Renderer      │  │  Session Persistence    │  │
│  │  (fork/exec)    │  │  (GPU/Software) │  │  (WAL-based)            │  │
│  └─────────────────┘  └─────────────────┘  └─────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        Child Processes (shells)                          │
│              PTY1 ↔ bash    PTY2 ↔ zsh    PTY3 ↔ python                 │
└─────────────────────────────────────────────────────────────────────────┘
```

## Core Subsystems

### 1. PTY Management Subsystem

The PTY subsystem handles creation and management of pseudo-terminals.

**Linux PTY Creation Flow:**
```
1. Open /dev/ptmx (master)
2. grantpt() - change ownership of slave device
3. unlockpt() - unlock slave device
4. ptsname() - get slave device path (/dev/pts/N)
5. fork()
   - Child: setsid(), open slave, dup2 to stdin/stdout/stderr, exec shell
   - Parent: manages master fd, handles I/O multiplexing
```

**Zig Implementation Approach:**
- Use `std.posix.open()` for /dev/ptmx
- Direct syscalls for grantpt/unlockpt via ioctl
- TIOCGPTN ioctl to get pts number
- `std.posix.fork()` for child process creation
- `std.posix.setsid()` to create new session
- TIOCSCTTY ioctl to set controlling terminal

**Key Data Structures:**
```zig
const Pty = struct {
    master_fd: std.posix.fd_t,
    slave_fd: std.posix.fd_t,
    slave_path: [64]u8,
    child_pid: std.posix.pid_t,

    // Terminal state
    rows: u16,
    cols: u16,
    original_termios: std.posix.termios,
};
```

### 2. Session Management

Sessions contain windows, and windows contain panes.

**Hierarchy:**
```
Server
└── Session (named, e.g., "dev", "build")
    └── Window (indexed, e.g., 0, 1, 2)
        └── Pane (unique ID, contains PTY)
            └── Terminal emulator state (scrollback, cursor, attributes)
```

**Key Operations:**
- Session create/attach/detach/kill
- Window create/rename/close
- Pane split (horizontal/vertical), resize, close
- Focus management (which pane receives input)

### 3. Terminal Emulation

Each pane contains a virtual terminal that:
- Parses ANSI escape sequences (CSI, OSC, DCS)
- Maintains a grid of cells with attributes
- Tracks cursor position
- Manages scrollback buffer (ring buffer for efficiency)
- Handles alternate screen buffer

**Parser State Machine:**
```
Ground → ESC → CSI_Entry → CSI_Param → CSI_Final → Ground
                        → OSC_Entry → OSC_String → Ground
                        → DCS_Entry → DCS_String → Ground
```

**Cell Structure:**
```zig
const Cell = struct {
    char: u21,           // Unicode codepoint
    fg: Color,           // Foreground (RGB or indexed)
    bg: Color,           // Background
    attrs: CellAttrs,    // Bold, italic, underline, etc.
};

const CellAttrs = packed struct {
    bold: bool,
    dim: bool,
    italic: bool,
    underline: bool,
    blink: bool,
    inverse: bool,
    strikethrough: bool,
    wide: bool,          // Wide character (CJK)
};
```

### 4. Rendering Subsystem

**Two modes:**

1. **Software Rendering (default)** - ANSI escape sequences to stdout
   - Compute diff between previous and current frame
   - Output only changed cells
   - Use cursor movement to skip unchanged regions

2. **GPU Rendering (DRM/KMS)** - Direct framebuffer access
   - Open /dev/dri/card0
   - Use DRM modesetting API
   - Font rendering via software rasterizer (no FreeType dependency)
   - Double-buffered page flipping

**GPU Rendering Flow:**
```
1. Open DRM device (/dev/dri/card0)
2. Get resources (connectors, encoders, CRTCs)
3. Create dumb buffer (DRM_IOCTL_MODE_CREATE_DUMB)
4. Map buffer to memory (mmap)
5. Render text to buffer
6. Page flip (DRM_IOCTL_MODE_PAGE_FLIP)
```

**Note:** DRM/KMS ioctls are not in Zig stdlib - we'll define them manually based on Linux headers.

### 5. Session Persistence

WAL-based persistence for crash recovery and session resurrection.

**Persisted State:**
- Session/window/pane hierarchy
- Scrollback content
- Current working directory of each pane
- Environment variables
- Shell command history (optional)

**Recovery Flow:**
```
1. On startup, check for existing socket/lockfile
2. If found, try to connect (attach mode)
3. If not found or stale, read WAL and reconstruct state
4. Re-execute shells in their original directories
```

### 6. IPC (Client-Server Communication)

**Unix Domain Socket Protocol:**
- Server listens on $XDG_RUNTIME_DIR/terminal_mux.sock or /tmp/terminal_mux-$UID/default.sock
- Binary protocol with length-prefixed messages

**Message Types:**
```zig
const MessageType = enum(u8) {
    // Client → Server
    attach = 0x01,
    detach = 0x02,
    new_session = 0x03,
    new_window = 0x04,
    split_pane = 0x05,
    kill_pane = 0x06,
    resize = 0x07,
    input = 0x08,
    list_sessions = 0x09,

    // Server → Client
    output = 0x80,
    session_info = 0x81,
    error_msg = 0x82,
    sync_state = 0x83,
};
```

### 7. Configuration System

**Zig-Native Configuration:**

Instead of parsing tmux.conf, configuration is a Zig struct that compiles with the binary:

```zig
// config.zig
pub const Config = struct {
    prefix_key: Key = .{ .ctrl = true, .char = 'b' },

    shell: []const u8 = "/bin/bash",
    default_term: []const u8 = "xterm-256color",

    scrollback_lines: u32 = 10000,

    // Colors
    status_bg: Color = .{ .r = 0, .g = 128, .b = 0 },
    status_fg: Color = .{ .r = 255, .g = 255, .b = 255 },

    // Keybindings
    bindings: []const Binding = &default_bindings,
};

const default_bindings = [_]Binding{
    .{ .key = .{ .char = '%' }, .action = .split_horizontal },
    .{ .key = .{ .char = '"' }, .action = .split_vertical },
    .{ .key = .{ .char = 'c' }, .action = .new_window },
    .{ .key = .{ .char = 'd' }, .action = .detach },
    // ...
};
```

**Runtime Configuration Override:**
- Environment variables for common options
- Command-line flags override defaults

## File Structure

```
terminal_mux/
├── build.zig
├── src/
│   ├── main.zig           # Entry point (server or client mode)
│   ├── server.zig         # Server main loop
│   ├── client.zig         # Client attach/command logic
│   ├── pty.zig            # PTY creation and management
│   ├── session.zig        # Session/window/pane hierarchy
│   ├── terminal.zig       # Terminal emulator (parser, grid)
│   ├── parser.zig         # ANSI/VT escape sequence parser
│   ├── render.zig         # Rendering abstraction
│   ├── render_ansi.zig    # Software ANSI renderer
│   ├── render_drm.zig     # GPU DRM/KMS renderer
│   ├── persist.zig        # Session persistence (WAL)
│   ├── ipc.zig            # Unix socket protocol
│   ├── config.zig         # Configuration structure
│   ├── input.zig          # Input handling and keybindings
│   └── lib.zig            # Public API re-exports
└── ARCHITECTURE.md
```

## Implementation Phases

### Phase 1: Core PTY Management
- [ ] PTY creation (/dev/ptmx, ioctl)
- [ ] Fork/exec shell
- [ ] Raw terminal mode
- [ ] Basic I/O multiplexing (single pane)

### Phase 2: Terminal Emulation
- [ ] VT100/ANSI parser state machine
- [ ] Character grid with attributes
- [ ] Basic cursor movement
- [ ] Scrollback buffer

### Phase 3: Session/Window/Pane
- [ ] Session data structures
- [ ] Pane splitting (horizontal/vertical)
- [ ] Focus switching
- [ ] Window management

### Phase 4: IPC and Attach/Detach
- [ ] Unix socket server
- [ ] Binary protocol
- [ ] Client attach mode
- [ ] Session listing

### Phase 5: Persistence
- [ ] WAL for session state
- [ ] Crash recovery
- [ ] Session resurrection

### Phase 6: GPU Rendering (Optional)
- [ ] DRM device enumeration
- [ ] Modesetting
- [ ] Dumb buffer allocation
- [ ] Font rendering (built-in bitmap font)
- [ ] Page flipping

## Key Zig 0.16 APIs Used

From our research, these are available:
- `std.posix.fork()` - Fork process
- `std.posix.setsid()` - Create new session
- `std.posix.open()` / `std.posix.close()` - File operations
- `std.posix.read()` / `std.posix.write()` - I/O
- `std.posix.dup2()` - Duplicate fd
- `std.posix.tcgetattr()` / `std.posix.tcsetattr()` - Terminal attributes
- `std.posix.epoll_create1()` / `std.posix.epoll_ctl()` / `std.posix.epoll_wait()` - Event loop
- `std.posix.mmap()` / `std.posix.munmap()` - Memory mapping
- `std.posix.socket()` / `std.posix.bind()` / `std.posix.listen()` / `std.posix.accept()` - Unix sockets
- `std.posix.winsize` - Terminal size structure

**Manual ioctl definitions needed:**
- TIOCGPTN - Get PTY number
- TIOCSPTLCK - Unlock PTY
- TIOCSCTTY - Set controlling terminal
- TIOCNOTTY - Give up controlling terminal
- TIOCGWINSZ / TIOCSWINSZ - Get/set window size (already in stdlib)

**DRM ioctls (for GPU mode):**
- DRM_IOCTL_MODE_GETRESOURCES
- DRM_IOCTL_MODE_GETCRTC
- DRM_IOCTL_MODE_GETCONNECTOR
- DRM_IOCTL_MODE_CREATE_DUMB
- DRM_IOCTL_MODE_MAP_DUMB
- DRM_IOCTL_MODE_PAGE_FLIP

## Performance Considerations

1. **Event Loop**: Single-threaded event loop using epoll for all I/O
2. **Diff-based Rendering**: Only send changed cells to terminal
3. **Ring Buffer Scrollback**: O(1) append, efficient memory usage
4. **Zero-copy IPC**: Share buffers between server and client when possible
5. **Lock-free Data Structures**: For multi-threaded rendering (if needed)

## Security Considerations

1. **PTY Permissions**: Ensure proper ownership/permissions on slave device
2. **Socket Permissions**: Unix socket with mode 0700
3. **No Shell Injection**: Careful handling of pane commands
4. **Sandboxing**: Consider seccomp filter for GPU renderer
