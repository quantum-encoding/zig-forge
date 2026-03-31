# Zig Core Utils

High-performance Zig implementations of GNU coreutils (**131 utilities**), optimized for modern hardware with parallel processing, SIMD acceleration, and zero-copy I/O.

## Feature Parity Summary

| Category | Full | Partial | Basic | Total |
|----------|------|---------|-------|-------|
| File Operations | 8 | 6 | 2 | 16 |
| Text Processing | 15 | 3 | 1 | 19 |
| System Info/User | 9 | 9 | 4 | 22 |
| Encoding/Hashing | 2 | 9 | 0 | 11 |
| Path/Name Utils | 4 | 4 | 0 | 8 |
| Process/Permission | 6 | 6 | 1 | 13 |
| Misc Utilities | 14 | 6 | 2 | 22 |
| Extended/Custom | 14 | 4 | 0 | 18 |
| **TOTAL** | **72 (56%)** | **47 (36%)** | **10 (8%)** | **129** |

- **Full**: All or nearly all GNU options implemented
- **Partial**: Core functionality complete, some options missing
- **Basic**: Minimal implementation

See [FEATURE_PARITY.md](FEATURE_PARITY.md) for detailed per-utility analysis.

## Performance Highlights

Benchmarked on Samsung 990 EVO Pro NVMe (7400 MB/s), Intel Core i9, 17,854 files:

| Utility | GNU Time | Zig Time | Speedup | Optimization |
|---------|----------|----------|---------|--------------|
| `find` | 21.1s | **2.1s** | **10.2x** | MPMC queue + getdents64 |
| `sha256sum` | 0.388s | **0.111s** | **3.5x** | SIMD acceleration |
| `du` | ~3s | **~1s** | **~3x** | Parallel traversal |
| `tree` | 14ms | **9ms** | **1.5x** | Buffered I/O + Io API |
| `clipboard` | 92.9ms | **84.9ms** | **1.09x** | Pure Zig + 7x lower variance |
| `time` | 16.87ms | **16.54ms** | **1.02x** | Pure Zig + 7x lower variance |
| `ping` | - | - | **parity** | Raw ICMP sockets, microsecond precision |
| `jq` | 61ms | **31ms** | **2x** | Buffered I/O, 1MB JSON |
| `grep` | - | - | **parity** | SIMD pattern matching |
| `wc` | - | - | **parity** | SIMD line/word counting |

### SIMD-Accelerated Utilities
- **zgrep** - SIMD pattern matching for high-performance text search
- **zwc** - SIMD line/word counting
- **zregex** - Thompson NFA with SIMD newline search (ReDoS-immune)
- **zsha256sum** - SIMD message schedule expansion

### Parallel Execution Support
- **zdu** - `--threads=N` for parallel directory scanning
- **zfind** - Lock-free MPMC queue for parallel traversal (10.2x faster)
- **zxargs** - `-P/--max-procs` for parallel command execution

### Extended Functionality Beyond GNU
- **zsort** - Added `-R` (random shuffle) and `-V` (version sort)
- **zrealpath** - Added `--relative-to` and `--relative-base`
- **zfind** - Added `--json-stats` output
- **zdu** - Added `--json-stats` and `--threads` options
- **zbench** - Full hyperfine-like benchmarking utility

## Utilities

### File Operations (16 utilities)

| Utility | Description | GNU Equivalent | Parity |
|---------|-------------|----------------|--------|
| `zcat` | Concatenate and display files | `cat` | Full |
| `zcp` | Copy files and directories | `cp` | Partial |
| `zdd` | Convert and copy files | `dd` | Partial |
| `zln` | Create hard/symbolic links | `ln` | Partial |
| `zlink` | Create hard links | `link` | Partial |
| `zls` | List directory contents | `ls` | Partial |
| `zmv` | Move/rename files | `mv` | Basic |
| `zrm` | Remove files and directories | `rm` | Full |
| `zrmdir` | Remove empty directories | `rmdir` | Full |
| `zmkdir` | Create directories | `mkdir` | Full |
| `zmkfifo` | Create FIFOs | `mkfifo` | Full |
| `zmknod` | Create special files | `mknod` | Full |
| `ztouch` | Update file timestamps | `touch` | Partial |
| `ztruncate` | Shrink/extend file size | `truncate` | Basic |
| `zshred` | Secure file deletion | `shred` | Partial |
| `zinstall` | Copy files and set attributes | `install` | Partial |

### Directory Operations

| Utility | Description | GNU Equivalent | Parity |
|---------|-------------|----------------|--------|
| `zfind` | Search for files (parallel, 10.2x faster) | `find` | Full |
| `ztree` | Display directory tree | `tree` | Full |
| `zvdir` | Long listing with escape sequences | `vdir` | Full |

### Text Processing (19 utilities)

| Utility | Description | GNU Equivalent | Parity |
|---------|-------------|----------------|--------|
| `zawk` | Pattern scanning and processing | `awk` | Partial |
| `zcut` | Remove sections from lines | `cut` | Full |
| `zfmt` | Format text paragraphs | `fmt` | Partial |
| `zfold` | Wrap lines to width | `fold` | Full |
| `zgrep` | Search text patterns (SIMD) | `grep` | Full |
| `zhead` | Display first lines | `head` | Full |
| `zjoin` | Join lines on common field | `join` | Full |
| `znl` | Number lines of files | `nl` | Full |
| `zpaste` | Merge lines of files | `paste` | Full |
| `zsed` | Stream editor | `sed` | Partial |
| `zsort` | Sort lines (-R random, -V version) | `sort` | Full |
| `zsplit` | Split file into pieces | `split` | Full |
| `ztac` | Reverse cat | `tac` | Basic |
| `ztail` | Display last lines | `tail` | Full |
| `ztr` | Translate/delete characters | `tr` | Full |
| `zuniq` | Report or omit repeated lines | `uniq` | Full |
| `zwc` | Count lines/words/chars (SIMD) | `wc` | Full |
| `zxargs` | Build/execute commands (parallel) | `xargs` | Full |

### Additional Text Utilities

| Utility | Description | GNU Equivalent | Parity |
|---------|-------------|----------------|--------|
| `zecho` | Display text | `echo` | Full |
| `zexpand` | Convert tabs to spaces | `expand` | Full |
| `zunexpand` | Convert spaces to tabs | `unexpand` | Full |
| `zcomm` | Compare two sorted files | `comm` | Full |
| `zseq` | Print number sequences | `seq` | Full |
| `zshuf` | Shuffle lines randomly | `shuf` | Partial |
| `zpr` | Paginate/format for printing | `pr` | Partial |
| `znumfmt` | Convert numbers to/from human-readable | `numfmt` | Partial |
| `zmore` | View file one screenful at a time | `more` | Full |
| `zregex` | Pattern matching (Thompson NFA, ReDoS-immune) | - | Full |

### Path & Name Utilities (8 utilities)

| Utility | Description | GNU Equivalent | Parity |
|---------|-------------|----------------|--------|
| `zbasename` | Strip directory from path | `basename` | Full |
| `zdirname` | Strip filename from path | `dirname` | Full |
| `zpathchk` | Check path validity | `pathchk` | Full |
| `zreadlink` | Print symlink target | `readlink` | Full |
| `zrealpath` | Resolve canonical path (--relative-to) | `realpath` | Partial |
| `zstat` | Display file status | `stat` | Partial |
| `ztest` | Condition evaluation | `test`/`[` | Partial |
| `zexpr` | Evaluate expressions | `expr` | Partial |
| `zpwd` | Print working directory | `pwd` | Full |

### System Info & User (22 utilities)

| Utility | Description | GNU Equivalent | Parity |
|---------|-------------|----------------|--------|
| `zarch` | Print machine architecture | `arch` | Full |
| `zdate` | Display/set date and time | `date` | Partial |
| `zdf` | Disk free space | `df` | Partial |
| `zdu` | Disk usage (parallel) | `du` | Partial |
| `zenv` | Environment variable utility | `env` | Partial |
| `zfree` | Display memory usage | `free` | Partial |
| `zgroups` | Print group memberships | `groups` | Full |
| `zhostid` | Print host identifier | `hostid` | Partial |
| `zhostname` | Print/set hostname | `hostname` | Basic |
| `zid` | Display user/group IDs | `id` | Partial |
| `zlogname` | Print login name | `logname` | Basic |
| `znproc` | Print number of processors | `nproc` | Partial |
| `zprintenv` | Print environment | `printenv` | Full |
| `zps` | Process status listing | `ps` | Basic |
| `zpwd` | Print working directory | `pwd` | Full |
| `zsys` | System information (composite) | - | Full |
| `ztty` | Print terminal name | `tty` | Full |
| `zuname` | Print system information | `uname` | Partial |
| `zuptime` | System uptime | `uptime` | Partial |
| `zusers` | Print logged-in users | `users` | Partial |
| `zwho` | Print logged-in users | `who` | Basic |
| `zwhoami` | Print effective user ID | `whoami` | Full |

### Encoding & Hashing (11 utilities)

| Utility | Description | GNU Equivalent | Parity |
|---------|-------------|----------------|--------|
| `zbase32` | Base32 encode/decode | `base32` | Full |
| `zbase64` | Base64 encode/decode | `base64` | Full |
| `zbasenc` | Base encoding utility | `basenc` | Partial |
| `zb2sum` | BLAKE2 checksums | `b2sum` | Partial |
| `zcksum` | CRC checksums | `cksum` | Basic |
| `zhashsum` | Generic hash utility | - | Partial |
| `zmd5sum` | MD5 checksums | `md5sum` | Partial |
| `zsha1sum` | SHA1 checksums | `sha1sum` | Partial |
| `zsha256sum` | SHA256 checksums (SIMD, 3.5x faster) | `sha256sum` | Partial |
| `zsha512sum` | SHA512 checksums | `sha512sum` | Partial |
| `zsum` | Checksum and count blocks | `sum` | Partial |

### Process & Permission (13 utilities)

| Utility | Description | GNU Equivalent | Parity |
|---------|-------------|----------------|--------|
| `zchgrp` | Change file group | `chgrp` | Partial |
| `zchmod` | Change file permissions | `chmod` | Partial |
| `zchown` | Change file owner | `chown` | Partial |
| `zchroot` | Run with different root | `chroot` | Full |
| `zkill` | Send signals to processes | `kill` | Full |
| `znice` | Run with modified priority | `nice` | Full |
| `znohup` | Run immune to hangups | `nohup` | Full |
| `zpgrep` | Find processes by name | `pgrep` | Partial |
| `zpkill` | Kill processes by name | `pkill` | Partial |
| `zruncon` | Run with SELinux context | `runcon` | Full |
| `zstdbuf` | Modify stdio buffering | `stdbuf` | Basic |
| `zsudo` | Execute as root/other user (PAM) | `sudo` | Partial |
| `ztimeout` | Run with time limit | `timeout` | Full |

### Miscellaneous Utilities (22 utilities)

| Utility | Description | GNU Equivalent | Parity |
|---------|-------------|----------------|--------|
| `zcomm` | Compare two sorted files | `comm` | Full |
| `zcsplit` | Split by context | `csplit` | Partial |
| `zecho` | Display text | `echo` | Full |
| `zexpand` | Convert tabs to spaces | `expand` | Full |
| `zunexpand` | Convert spaces to tabs | `unexpand` | Full |
| `zfactor` | Prime factorization | `factor` | Full |
| `zfalse` | Exit with failure | `false` | Basic |
| `ztrue` | Exit with success | `true` | Basic |
| `zmktemp` | Create temporary files | `mktemp` | Full |
| `znumfmt` | Convert numbers to/from human-readable | `numfmt` | Partial |
| `zod` | Octal dump | `od` | Partial |
| `zpr` | Paginate for printing | `pr` | Partial |
| `zprintf` | Format and print | `printf` | Partial |
| `zptx` | Permuted index | `ptx` | Partial |
| `zseq` | Print number sequences | `seq` | Full |
| `zshuf` | Shuffle lines randomly | `shuf` | Partial |
| `zsleep` | Delay execution | `sleep` | Full |
| `zsync` | Synchronize filesystems | `sync` | Full |
| `ztee` | Tee output | `tee` | Partial |
| `ztsort` | Topological sort | `tsort` | Full |
| `zunlink` | Remove single file | `unlink` | Full |
| `zyes` | Output string repeatedly | `yes` | Full |

### Extended & Custom Utilities (18 utilities)

| Utility | Description | Type | Parity |
|---------|-------------|------|--------|
| `zbackup` | Coreutils swap manager | Custom | Full |
| `zbench` | Benchmarking (hyperfine-like) | Custom | Full |
| `zcurl` | URL transfer tool | Extended | Partial |
| `zfind` | Parallel file finder (10.2x faster) | Extended | Full |
| `zfree` | Memory display utility | Extended | Full |
| `zgzip` | Gzip compress/decompress | Extended | Full |
| `zjq` | JSON query and manipulation | Custom | Partial |
| `zmore` | File pager | Extended | Full |
| `zping` | ICMP ping (microsecond precision) | Extended | Full |
| `zregex` | Thompson NFA regex (ReDoS-immune) | Custom | Full |
| `zstty` | Terminal line settings | Extended | Full |
| `zsys` | System info aggregator | Custom | Full |
| `ztar` | Archive utility (gzip/bzip2/xz/zstd) | Extended | Full |
| `ztime` | Time command execution | Extended | Full |
| `ztree` | Directory tree listing | Extended | Full |
| `zuptime` | System uptime | Extended | Full |
| `zvdir` | Detailed directory listing | Extended | Full |
| `zxz` | XZ/LZMA decompression | Extended | Partial |
| `zzstd` | Zstandard decompression | Extended | Partial |

### Clipboard

| Utility | Description | GNU Equivalent | Parity |
|---------|-------------|----------------|--------|
| `zcopy` | Copy stdin to clipboard | `xclip`/`wl-copy` | Full |
| `zpaste` | Paste clipboard to stdout | `xclip`/`wl-paste` | Full |

## Building

Each utility is a standalone Zig project:

```bash
# Build a specific utility
cd zfind && zig build -Doptimize=ReleaseFast

# Build all utilities (from zig_core_utils directory)
for dir in z*/; do
    (cd "$dir" && zig build -Doptimize=ReleaseFast 2>/dev/null) && echo "Built $dir"
done
```

## Usage Examples

### zfind - Parallel File Search (10.2x faster)

```bash
# Find by name pattern
zfind /path -name "*.zig"
zfind . -name "*.c" -o -name "*.h"

# Find by type
zfind /home -type f              # Files only
zfind /var -type d               # Directories only
zfind /dev -type l               # Symlinks only

# Find by size
zfind . -size +10M               # Larger than 10MB
zfind . -size -1k                # Smaller than 1KB
zfind . -size 4096c              # Exactly 4096 bytes

# Find by time
zfind . -mtime -1                # Modified in last 24 hours
zfind . -mtime +7                # Modified more than 7 days ago

# Find by permissions
zfind /usr -perm 755             # Exact permissions
zfind . -perm -u+x               # User executable

# Execute commands
zfind . -name "*.tmp" -exec rm {} \;
zfind . -name "*.log" -exec gzip {} \;

# Depth control
zfind . -maxdepth 2 -name "*.txt"
zfind . -mindepth 1 -maxdepth 3 -type f

# Pruning
zfind . -name ".git" -prune -o -name "*.zig" -print
```

### zsha256sum - SIMD-Accelerated Hashing (3.5x faster)

```bash
# Hash single file
zsha256sum file.bin

# Hash multiple files
zsha256sum *.iso

# Verify checksums
zsha256sum -c checksums.txt

# Output in BSD format
zsha256sum --tag file.bin
```

### zgrep - Pattern Search

```bash
# Basic search
zgrep "pattern" file.txt

# Recursive search
zgrep -r "TODO" src/

# Case insensitive
zgrep -i "error" logs/

# Show line numbers
zgrep -n "function" *.zig

# Invert match
zgrep -v "debug" output.log

# Count matches
zgrep -c "import" src/*.zig
```

### zls - Directory Listing

```bash
# Basic listing
zls

# Long format with details
zls -l

# Show hidden files
zls -a

# Human-readable sizes
zls -lh

# Sort by time
zls -lt

# Recursive listing
zls -R src/
```

### zdu - Disk Usage (Parallel)

```bash
# Summarize directory
zdu -s /home

# Human readable
zdu -h /var

# Max depth
zdu --max-depth=2 /

# Sort by size
zdu -h /home | sort -h
```

### zwc - Word/Line Count

```bash
# Count lines
zwc -l *.zig

# Count words
zwc -w document.txt

# Count characters
zwc -c file.txt

# All counts
zwc file.txt
```

### zsudo - Privilege Elevation

```bash
# Run command as root
zsudo ls /root

# Run as different user
zsudo -u www-data whoami

# Login shell as root
zsudo -i

# Preserve environment
zsudo -E make install

# Validate credentials (refresh timeout)
zsudo -v

# Invalidate cached credentials
zsudo -k
```

**Security Note:** zsudo must be installed setuid root:
```bash
sudo chown root:root zsudo && sudo chmod 4755 zsudo
```

### zxargs - Parallel Command Execution

```bash
# Basic usage - pass files to rm
find . -name "*.tmp" | zxargs rm

# Null-delimited input (safe for filenames with spaces)
find . -name "*.log" -print0 | zxargs -0 gzip

# Parallel execution (4 processes)
find . -name "*.jpg" | zxargs -P4 mogrify -resize 50%

# Batch arguments (10 files per command)
ls *.txt | zxargs -n10 cat

# Replace string mode
ls *.txt | zxargs -I{} cp {} {}.bak

# Trace mode (show commands)
echo "a b c" | zxargs -t -n1 echo

# Use all CPU cores
find . -name "*.c" | zxargs -P0 gcc -c
```

### ztree - Directory Tree Display (1.5x faster)

```bash
# Basic tree view
ztree

# Limit depth
ztree -L 2 /path/to/dir

# Show hidden files
ztree -a

# Show file sizes (human readable)
ztree -s -h

# Directories only
ztree -d

# ASCII characters (no Unicode)
ztree -A

# Pattern filter
ztree -P "*.zig"

# Directories first, reverse sort
ztree --dirsfirst -r

# No colors
ztree -n
```

### ztime - Command Timing (1.02x faster, 7x more consistent)

```bash
# Basic timing
ztime ./my_program

# Verbose output with resource usage
ztime -v make -j8

# POSIX portable format
ztime -p sleep 1

# Custom format string
ztime -f "Real: %e User: %U Sys: %S\n" command

# Output to file
ztime -o timing.log ./benchmark

# Append to file
ztime -o timing.log -a ./benchmark

# Quiet mode (suppress command output)
ztime -q ./noisy_program
```

**Format specifiers:**
- `%e` - Elapsed real time (seconds)
- `%U` - User CPU time (seconds)
- `%S` - System CPU time (seconds)
- `%P` - Percent CPU ((U+S)/E)
- `%M` - Maximum resident set size (KB)
- `%F` - Major page faults
- `%R` - Minor page faults
- `%c` - Voluntary context switches
- `%w` - Involuntary context switches
- `%x` - Exit status

### zdate - Date/Time Display

```bash
# Current date and time
zdate

# Custom format
zdate +%Y-%m-%d           # 2026-01-05
zdate +"%H:%M:%S"         # 18:59:17

# UTC time
zdate -u
zdate -u +"%H:%M:%S UTC"

# RFC formats
zdate -R                  # RFC 2822
zdate --rfc-3339=seconds  # RFC 3339

# ISO 8601 formats
zdate -I                  # Date only
zdate -Iseconds           # With time
zdate -Ins                # With nanoseconds

# File modification time
zdate -r /path/to/file
```

### zid - User/Group Information

```bash
# Full info for current user
zid
# uid=1000(user) gid=1000(user) groups=998(wheel),1000(user)

# User ID only
zid -u                    # 1000
zid -un                   # user (name)

# Group ID only
zid -g                    # 1000
zid -gn                   # user (name)

# All groups
zid -G                    # 998 1000
zid -Gn                   # wheel user

# Real IDs (not effective)
zid -r -u

# Info for another user
zid root
```

### zcopy/zpaste - Clipboard Operations (1.09x faster, 7x more consistent)

```bash
# Copy to clipboard
echo "hello" | zcopy
cat file.txt | zcopy
pwd | zcopy -n              # Strip trailing newline

# Paste from clipboard
zpaste                      # To stdout
zpaste > file.txt           # To file
zpaste | grep pattern       # In pipeline

# Primary selection (X11)
echo "text" | zcopy -p      # Copy to PRIMARY
zpaste -p                   # Paste from PRIMARY

# Verbose mode
echo "test" | zcopy -v      # Show what's copied
```

**Features:**
- Auto-detects Wayland vs X11
- Supports CLIPBOARD and PRIMARY selection
- Strip trailing newline option (`-n`)
- Works with pipes and redirects

### zenv - Environment Variables

```bash
# Print all environment variables
zenv

# Print with empty environment
zenv -i

# Set variables and print
zenv FOO=bar BAZ=qux

# Unset variables
zenv -u HOME -u PATH

# Run command with modified environment
zenv PATH=/custom/bin ls
zenv -i HOME=/tmp bash

# Run command with unset variable
zenv -u LD_LIBRARY_PATH ./program

# NUL-terminated output (for scripts)
zenv -0

# Change directory before running
zenv -C /tmp pwd
```

### zping - Network Ping

```bash
# Basic ping (requires cap_net_raw capability)
zping localhost

# Limited count
zping -c 5 8.8.8.8

# Custom interval (0.2 seconds)
zping -c 10 -i 0.2 192.168.1.1

# Custom packet size
zping -s 1024 host.example.com

# Flood ping (requires root)
zping -f target

# Quiet mode (summary only)
zping -q -c 100 localhost

# IPv6
zping -6 ::1
```

**Setup (required for non-root users):**
```bash
sudo setcap cap_net_raw+ep ./zig-out/bin/zping
```

**Output format:**
```
PING localhost (127.0.0.1) 56(84) bytes of data.
64 bytes from 127.0.0.1: icmp_seq=0 ttl=64 time=0.040 ms
64 bytes from 127.0.0.1: icmp_seq=1 ttl=64 time=0.038 ms

--- localhost ping statistics ---
5 packets transmitted, 5 received, 0% packet loss, time 4002ms
rtt min/avg/max/mdev = 0.038/0.042/0.070/0.012 ms
```

### zkill - Process Signal Sender

```bash
# Send SIGTERM (default) to process
zkill 1234

# Send SIGKILL (force kill)
zkill -9 1234
zkill -KILL 1234
zkill -s SIGKILL 1234

# Send SIGHUP (hangup/reload)
zkill -HUP 1234
zkill -s HUP 1234

# Check if process exists (signal 0)
zkill -0 1234

# Kill multiple processes
zkill -TERM 1234 5678 9012

# List all signals
zkill -l

# Signal table with descriptions
zkill -L

# Convert signal number to name
zkill -l 9

# Convert signal name to number
zkill -l KILL
```

### zpkill - Kill Processes by Name

```bash
# Kill all firefox processes
zpkill firefox

# Force kill with SIGKILL
zpkill -9 chrome
zpkill -KILL chrome

# Send SIGHUP (reload config)
zpkill -HUP nginx

# Match full command line (not just process name)
zpkill -f "python app.py"

# Exact name match only
zpkill -x bash

# Kill newest/oldest matching process
zpkill -n sleep
zpkill -o sleep

# Filter by user ID
zpkill -u 1000 python

# List matching PIDs (don't kill)
zpkill -l java

# Count matching processes (don't kill)
zpkill -c ssh
```

### zpgrep - Find Processes by Name

```bash
# Find PIDs of bash processes
zpgrep bash

# Show PIDs with process names
zpgrep -l bash

# Show PIDs with full command lines
zpgrep -a bash

# Match in full command line
zpgrep -f "python app"

# Exact name match only
zpgrep -x bash

# Find newest/oldest process
zpgrep -n sleep
zpgrep -o sleep

# Filter by user ID
zpgrep -u 1000 python

# Count matching processes
zpgrep -c ssh

# Comma-separated output
zpgrep -d, bash
```

### zps - Process Status

```bash
# Default format (PID TTY TIME CMD)
zps

# Full format with additional columns
zps -f

# Long format (F S UID PID PPID C PRI NI SZ RSS WCHAN TTY TIME CMD)
zps -l

# BSD aux-like format
zps aux

# Show all processes
zps -e
zps -A

# Show specific user's processes
zps -u 1000
zps -u root

# Show processes for a specific PID
zps -p 1234

# Show process hierarchy
zps -f -p 1
```

**Output formats:**
- Default: `PID TTY TIME CMD`
- `-f` (full): `UID PID PPID C STIME TTY TIME CMD`
- `-l` (long): `F S UID PID PPID C PRI NI SZ RSS WCHAN TTY TIME CMD`
- `aux`: `USER PID %CPU %MEM VSZ RSS TTY STAT START TIME COMMAND`

### zlink - Create Links

```bash
# Create hard link
zlink target.txt link.txt

# Create symbolic link
zlink -s target.txt link.txt

# Force overwrite existing link
zlink -sf target.txt link.txt

# Verbose output (combined options supported)
zlink -sv /path/to/target link

# Create multiple links in directory
zlink -sv file1 file2 file3 /dest/dir/

# Relative symbolic link
zlink -rs ../file link
```

### zvdir - Long Listing with Escapes

```bash
# List current directory (equivalent to ls -lb)
zvdir

# Show all files including hidden
zvdir -a

# Human-readable sizes
zvdir -h /home

# Sort by modification time
zvdir -t

# Sort by size, largest first
zvdir -S

# Reverse sort order
zvdir -r

# Numeric user/group IDs
zvdir -n

# Combined options
zvdir -hart /var/log
```

Non-printable characters are escaped as octal (e.g., newline becomes `\012`).

### zbackup - Coreutils Swap Manager

```bash
# Show status of all utilities
zbackup status

# List available Zig utilities by category
zbackup list

# Install single utility (backs up GNU first)
sudo zbackup install ls

# Install multiple utilities
sudo zbackup install ls grep du find

# Install all available utilities
sudo zbackup install --all

# Preview installation (dry-run)
zbackup --dry-run install --all

# Restore GNU utility from backup
sudo zbackup restore ls

# Restore all GNU utilities
sudo zbackup restore --all

# Test utility before installing
zbackup test grep

# Test all utilities
zbackup test --all
```

**Features:**
- Automatic backup before swap (to `/usr/local/backup/gnu/`)
- Atomic swap using `rename()`
- Color-coded status display (ACTIVE=green, READY=yellow, GNU=dim)
- Performance ratios for each utility
- Dry-run mode for preview
- Easy rollback with restore command

**Status output example:**
```
  Zig Coreutils Status
  ====================

  Utility      Zig Name     Status     Backup     Category   Perf
  ----------------------------------------------------------------------
  ls           zls          ACTIVE    YES       file       2.1x
  grep         zgrep        READY     NO        text       2.8x
  du           zdu          GNU       NO        file       3.2x
```

### ztr - Character Translation

```bash
# Convert lowercase to uppercase
echo "hello world" | ztr 'a-z' 'A-Z'

# Delete vowels
echo "hello world" | ztr -d 'aeiou'

# Squeeze repeated spaces
echo "hello    world" | ztr -s ' '

# Delete and squeeze
echo "hello   world" | ztr -ds ' '

# Complement - delete non-alphanumeric
echo "Hello, World!" | ztr -cd '[:alnum:]'

# Using character classes
echo "Hello World" | ztr '[:upper:]' '[:lower:]'
```

### znl - Line Numbering

```bash
# Number non-empty lines (default)
znl file.txt

# Number all lines
znl -b a file.txt

# Right-justified with leading zeros
znl -n rz -w 4 file.txt

# Custom separator
znl -s ': ' file.txt

# Start from line 100, increment by 10
znl -v 100 -i 10 file.txt

# Pipe from stdin
cat file.txt | znl
```

### zfold - Line Folding

```bash
# Fold to 80 columns (default)
zfold file.txt

# Fold to 40 columns
zfold -w 40 file.txt

# Break at spaces (word wrap)
zfold -s -w 60 file.txt

# Count bytes instead of columns
zfold -b -w 100 file.txt

# Shorthand width
zfold -40 file.txt
```

### zseq - Sequence Generation

```bash
# Print 1 to 5
zseq 5

# Print 2 to 5
zseq 2 5

# Print 0, 2, 4, 6, 8, 10
zseq 0 2 10

# Descending sequence
zseq 5 -1 1

# Equal width (zero-padded)
zseq -w 1 10

# Custom separator
zseq -s ", " 1 5
# Output: 1, 2, 3, 4, 5
```

### ztee - Tee Output

```bash
# Write to stdout and file
echo "hello" | ztee file.txt

# Append to file
echo "log entry" | ztee -a log.txt

# Write to multiple files
ls | ztee file1.txt file2.txt file3.txt

# Save command output while viewing
make 2>&1 | ztee build.log

# In pipeline
curl -s url | ztee response.txt | jq .
```

### zcut - Field Extraction

```bash
# Extract first field (colon delimiter)
zcut -d: -f1 /etc/passwd

# Extract specific characters
echo "hello world" | zcut -c1-5
# Output: hello

# Extract multiple fields
echo "a:b:c:d" | zcut -d: -f1,3
# Output: a:c

# Extract range of fields
echo "a:b:c:d:e" | zcut -d: -f2-4
# Output: b:c:d

# Extract bytes
zcut -b1-10 file.txt

# Extract from Nth to end
echo "a:b:c:d" | zcut -d: -f2-
# Output: b:c:d

# Custom output delimiter
echo "a:b:c" | zcut -d: -f1,3 --output-delimiter=","
# Output: a,c
```

### zsort - Line Sorting

```bash
# Alphabetic sort (default)
zsort file.txt

# Numeric sort
zsort -n numbers.txt

# Reverse sort
zsort -r file.txt

# Case-insensitive sort
zsort -f file.txt

# Sort by second field (colon-separated)
zsort -t: -k2 /etc/passwd

# Remove duplicates while sorting
zsort -u file.txt

# Check if file is sorted
zsort -c file.txt
```

### zuniq - Unique Lines

```bash
# Remove adjacent duplicates (use with zsort)
zsort file | zuniq

# Count occurrences
zsort file | zuniq -c

# Show only duplicates
zsort file | zuniq -d

# Show only unique lines
zsort file | zuniq -u

# Case-insensitive comparison
zsort file | zuniq -i

# Skip first N fields
zuniq -f 2 file.txt

# Compare only first N characters
zuniq -w 10 file.txt
```

### zcomm - Compare Sorted Files

```bash
# Show all three columns (unique to file1, unique to file2, common)
zcomm file1.txt file2.txt

# Show only lines common to both files
zcomm -12 file1.txt file2.txt

# Show lines unique to file1
zcomm -23 file1.txt file2.txt

# Show lines unique to file2
zcomm -13 file1.txt file2.txt
```

### zjoin - Join Files on Field

```bash
# Join on first field (default)
zjoin file1.txt file2.txt

# Join on specific fields
zjoin -1 2 -2 1 file1.txt file2.txt

# Use colon as field separator
zjoin -t: /etc/passwd /etc/group

# Include unmatched lines from file1
zjoin -a1 file1.txt file2.txt

# Case-insensitive join
zjoin -i file1.txt file2.txt
```

### zpaste - Merge Lines

```bash
# Merge files column-wise
zpaste file1.txt file2.txt

# Custom delimiter
zpaste -d, file1.txt file2.txt

# Serial mode (concatenate each file's lines)
zpaste -s file1.txt file2.txt

# Multiple delimiters (cycle through)
zpaste -d',:' f1.txt f2.txt f3.txt
```

### zgzip/zgunzip - Gzip Compression

```bash
# Compress file (removes original by default)
zgzip file.txt

# Compress to stdout, keep original
zgzip -c file.txt > file.txt.gz

# Keep original file with verbose output (combined options supported)
zgzip -kv file.txt

# Use best compression with verbose output
zgzip -9kv file.txt
zgzip --best file.txt

# Fast compression, keep original
zgzip -1k file.txt
zgzip --fast file.txt

# Verbose output
zgzip -v file.txt

# Decompress
zgunzip file.txt.gz

# Decompress to stdout
zgunzip -dc file.txt.gz

# Decompress, keep original with verbose
zgunzip -dkv file.txt.gz
```

### zxz - XZ Decompression

```bash
# Decompress xz file
zxz -d file.xz

# Decompress to stdout (combined options supported)
zxz -dc file.xz

# Keep original file with verbose output
zxz -dkv file.xz

# Verbose output
zxz -dv file.xz
```

**Note:** Compression requires external `xz` tool. Decompression of `.xz` files is fully supported using Zig's built-in LZMA2 decoder.

### zzstd - Zstandard Decompression

```bash
# Decompress zstd file
zzstd -d file.zst

# Decompress to stdout (combined options supported)
zzstd -dc file.zst

# Keep original file with verbose output
zzstd -dkv file.zst

# Verbose output
zzstd -dv file.zst
```

**Note:** Compression requires external `zstd` tool. Decompression of `.zst` files is fully supported using Zig's built-in Zstandard decoder.

## Architecture

### zfind Optimizations

The `zfind` utility achieves 10.2x speedup through:

1. **Lock-free MPMC Queue**: Dmitry Vyukov's bounded MPMC algorithm with ~85ns push/pop latency
2. **getdents64 Syscall**: Direct kernel syscall with 32KB buffer reads ~100+ directory entries per call (vs 1 for readdir)
3. **Parallel Workers**: Thread pool processes directories concurrently
4. **d_type Optimization**: Uses dirent d_type field to avoid stat() calls when filesystem supports it
5. **Work Stealing**: Outstanding counter tracks pending work for clean termination

```
┌─────────────────────────────────────────────────────────────┐
│                      Main Thread                             │
│  ┌─────────┐    ┌──────────────┐    ┌─────────────────┐    │
│  │ Parse   │───▶│ Queue Root   │───▶│ Spawn Workers   │    │
│  │ Args    │    │ Directory    │    │ (N threads)     │    │
│  └─────────┘    └──────────────┘    └─────────────────┘    │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                    MPMC Work Queue                           │
│  ┌─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┐        │
│  │ Dir │ Dir │ Dir │ Dir │ ... │     │     │     │        │
│  │  1  │  2  │  3  │  4  │     │     │     │     │        │
│  └─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┘        │
└─────────────────────────────────────────────────────────────┘
          │              │              │              │
          ▼              ▼              ▼              ▼
┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│   Worker 0   │ │   Worker 1   │ │   Worker 2   │ │   Worker N   │
│ ┌──────────┐ │ │ ┌──────────┐ │ │ ┌──────────┐ │ │ ┌──────────┐ │
│ │getdents64│ │ │ │getdents64│ │ │ │getdents64│ │ │ │getdents64│ │
│ │ 32KB buf │ │ │ │ 32KB buf │ │ │ │ 32KB buf │ │ │ │ 32KB buf │ │
│ └──────────┘ │ │ └──────────┘ │ │ └──────────┘ │ │ └──────────┘ │
│      │       │ │      │       │ │      │       │ │      │       │
│      ▼       │ │      ▼       │ │      ▼       │ │      ▼       │
│ ┌──────────┐ │ │ ┌──────────┐ │ │ ┌──────────┐ │ │ ┌──────────┐ │
│ │  Match   │ │ │ │  Match   │ │ │ │  Match   │ │ │ │  Match   │ │
│ │ Filters  │ │ │ │ Filters  │ │ │ │ Filters  │ │ │ │ Filters  │ │
│ └──────────┘ │ │ └──────────┘ │ │ └──────────┘ │ │ └──────────┘ │
└──────────────┘ └──────────────┘ └──────────────┘ └──────────────┘
          │              │              │              │
          └──────────────┴──────────────┴──────────────┘
                                  │
                                  ▼
                         ┌──────────────┐
                         │   Output     │
                         │  (mutex)     │
                         └──────────────┘
```

### zsha256sum Optimizations

- SIMD-accelerated message schedule expansion
- Parallel file reading with hash computation
- Memory-mapped I/O for large files

## Requirements

- **Zig**: 0.16.0+
- **OS**: Linux (some utilities use Linux-specific syscalls)
- **libc**: Required for execvp (zfind -exec)

## Directory Structure

```
zig_core_utils/
├── README.md
├── bench/                 # Benchmark scripts
│
├── zarch/                 # Print machine architecture
├── zawk/                  # Pattern scanning and processing
├── zb2sum/                # BLAKE2 checksums
├── zbackup/               # Coreutils swap manager
├── zbase32/               # Base32 encode/decode
├── zbase64/               # Base64 encode/decode
├── zbasename/             # Strip directory from path
├── zbasenc/               # Base encoding utility
├── zbench/                # Benchmarking utility
├── zcat/                  # Concatenate files
├── zchcon/                # Change SELinux context
├── zchgrp/                # Change group ownership
├── zchmod/                # Change file permissions
├── zchown/                # Change file owner
├── zchroot/               # Run command with different root
├── zcksum/                # CRC checksums
├── zclip/                 # Clipboard operations (zcopy + zpaste)
├── zcomm/                 # Compare sorted files
├── zcp/                   # Copy files
├── zcsplit/               # Split by context
├── zcurl/                 # URL transfer tool
├── zcut/                  # Remove sections from lines
├── zdate/                 # Display/set date
├── zdd/                   # Convert and copy files
├── zdf/                   # Disk free space
├── zdir/                  # Directory listing
├── zdircolors/            # Color setup for ls
├── zdirname/              # Strip filename from path
├── zdu/                   # Disk usage (parallel)
├── zecho/                 # Display text
├── zenv/                  # Environment variables
├── zexpand/               # Convert tabs to spaces
├── zexpr/                 # Evaluate expressions
├── zfactor/               # Prime factorization
├── zfalse/                # Exit with failure
├── zfind/                 # Find files (parallel, 10x faster)
├── zfmt/                  # Format text paragraphs
├── zfold/                 # Wrap lines to width
├── zfree/                 # Display memory usage
├── zgrep/                 # Search text patterns
├── zgroups/               # Print group memberships
├── zgzip/                 # Gzip compress/decompress
├── zhashsum/              # Generic hash utility
├── zhead/                 # Display first lines
├── zhostid/               # Print host identifier
├── zhostname/             # Print/set hostname
├── zid/                   # Display user/group IDs
├── zinstall/              # Copy files and set attributes
├── zjoin/                 # Join lines on common field
├── zjq/                   # JSON query and manipulation
├── zkill/                 # Send signals to processes
├── zlink/                 # Create hard links
├── zln/                   # Create links
├── zlogname/              # Print login name
├── zls/                   # List directory contents
├── zmd5sum/               # MD5 checksums
├── zmkdir/                # Create directories
├── zmkfifo/               # Create FIFOs
├── zmknod/                # Create special files
├── zmktemp/               # Create temporary files
├── zmore/                 # File pager
├── zmv/                   # Move/rename files
├── znice/                 # Run with modified priority
├── znl/                   # Number lines
├── znohup/                # Run immune to hangups
├── znproc/                # Print number of processors
├── znumfmt/               # Convert numbers to/from human-readable
├── zod/                   # Octal dump
├── zpaste/                # Merge lines of files
├── zpathchk/              # Check path validity
├── zpgrep/                # Find processes by name
├── zping/                 # ICMP ping
├── zpinky/                # Lightweight finger
├── zpkill/                # Kill processes by name
├── zpr/                   # Paginate for printing
├── zprintenv/             # Print environment
├── zprintf/               # Format and print
├── zps/                   # Process status
├── zptx/                  # Permuted index
├── zpwd/                  # Print working directory
├── zreadlink/             # Print symlink target
├── zrealpath/             # Resolve canonical path
├── zregex/                # Pattern matching with regex
├── zrm/                   # Remove files
├── zrmdir/                # Remove empty directories
├── zruncon/               # Run with SELinux context
├── zsed/                  # Stream editor
├── zseq/                  # Print number sequences
├── zsha1sum/              # SHA1 checksums
├── zsha256sum/            # SHA256 checksums (SIMD, 3.5x faster)
├── zsha512sum/            # SHA512 checksums
├── zshred/                # Secure file deletion
├── zshuf/                 # Shuffle lines
├── zsleep/                # Delay execution
├── zsort/                 # Sort lines
├── zsplit/                # Split files
├── zstat/                 # Display file status
├── zstdbuf/               # Modify stdio buffering
├── zstty/                 # Terminal settings
├── zsudo/                 # Execute as root/other user
├── zsum/                  # Checksum and count blocks
├── zsync/                 # Synchronize filesystems
├── zsys/                  # System information
├── ztac/                  # Reverse cat
├── ztail/                 # Display last lines
├── ztar/                  # Archive utility
├── ztee/                  # Tee output
├── ztest/                 # Condition evaluation
├── ztime/                 # Time command execution
├── ztimeout/              # Run with time limit
├── ztouch/                # Update timestamps
├── ztr/                   # Translate characters
├── ztree/                 # Display directory tree
├── ztrue/                 # Exit with success
├── ztruncate/             # Shrink/extend file size
├── ztsort/                # Topological sort
├── ztty/                  # Print terminal name
├── zuname/                # Print system information
├── zunexpand/             # Convert spaces to tabs
├── zuniq/                 # Report/omit repeated lines
├── zunlink/               # Remove single file
├── zuptime/               # System uptime
├── zusers/                # Print logged-in users
├── zvdir/                 # Long listing with escapes
├── zwc/                   # Count lines/words/chars
├── zwho/                  # Print logged-in users
├── zwhoami/               # Print effective user ID
├── zxargs/                # Build/execute commands (parallel)
├── zxz/                   # XZ/LZMA decompression
├── zyes/                  # Output string repeatedly
└── zzstd/                 # Zstandard decompression
```

Each utility follows the standard structure:
```
zutil/
├── build.zig
└── src/
    └── main.zig
```

## License

MIT License - QUANTUM ENCODING LTD
