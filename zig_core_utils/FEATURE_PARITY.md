# Zig Core Utils - GNU Coreutils Feature Parity

A comprehensive comparison of Zig Core Utilities against their GNU coreutils equivalents.

**Total utilities analyzed: 131**

## Summary Statistics

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
| **TOTAL** | **72** | **47** | **10** | **129** |

---

## Group 1: File Operations

| Utility | GNU Equivalent | Status | Notes |
|---------|----------------|--------|-------|
| zcat | cat | Full | All common options (-n, -b, -s, -E, -T, -v, -A) |
| zcp | cp | Partial | Missing backup, reflink, sparse options |
| zdd | dd | Partial | Missing iflag/oflag, advanced conv options |
| zln | ln | Partial | Missing backup, relative, interactive |
| zlink | link | Partial | More feature-rich than GNU link |
| zls | ls | Partial | Good coverage of common options |
| zmv | mv | Basic | Missing update, backup, interactive |
| zrm | rm | Full | Includes preserve-root safety |
| zrmdir | rmdir | Full | All major options |
| zmkdir | mkdir | Full | Missing only SELinux context |
| zmkfifo | mkfifo | Full | Missing only SELinux context |
| zmknod | mknod | Full | Missing only SELinux context |
| ztouch | touch | Partial | Missing date string parsing |
| ztruncate | truncate | Basic | Missing reference file, no-create |
| zshred | shred | Partial | Very good coverage |
| zinstall | install | Partial | Some features recognized but unimplemented |

### Detailed: zcat
**Implemented:** -n, -b, -s, -E, -T, -v, -A, -e, -t, --help, --version
**Missing:** -u (unbuffered)

### Detailed: zcp
**Implemented:** -r, -R, -f, -n, -v, -p, -a, -u, -t, --help, --version
**Missing:** -d, -l, -s, -i, -b, --reflink, --sparse, --preserve=ATTR_LIST, -x

### Detailed: zdd
**Implemented:** if=, of=, bs=, ibs=, obs=, count=, skip=, seek=, conv=, status=
**Missing:** cbs=, iflag/oflag, conv=ascii/ebcdic/ibm/block/unblock/sparse

### Detailed: zrm
**Implemented:** -f, -r, -R, -d, -v, -i, -I, --preserve-root, --no-preserve-root
**Missing:** --one-file-system

---

## Group 2: Text Processing

| Utility | GNU Equivalent | Status | Notes |
|---------|----------------|--------|-------|
| zawk | awk/gawk | Partial | Full AWK language, missing -f flag |
| zcat | cat | Full | All major options |
| zcut | cut | Full | Complete implementation |
| zfmt | fmt | Partial | Missing crown/tagged margin |
| zfold | fold | Full | Complete implementation |
| zgrep | grep | Full | SIMD-accelerated, comprehensive |
| zhead | head | Full | Complete with negative counts |
| zjoin | join | Full | Complete implementation |
| znl | nl | Full | Complete implementation |
| zpaste | paste | Full | Complete implementation |
| zsed | sed | Partial | Missing -f script file option |
| zsort | sort | Full | Complete with -R and -V |
| zsplit | split | Full | Complete with -n chunks |
| ztac | tac | Basic | Only reverses lines |
| ztail | tail | Full | Complete with follow modes |
| ztr | tr | Full | Complete with -s squeeze |
| zuniq | uniq | Full | Complete implementation |
| zwc | wc | Full | SIMD-accelerated |
| zxargs | xargs | Full | Includes parallel execution |

### Detailed: zgrep
**Implemented:** -i, -v, -c, -n, -l, -L, -H, -h, -r, -R, -q, -o, -F, -E, -w, -A, -B, -C, -m, --include, --exclude, --exclude-dir
**Missing:** -G, -P, -x, -e, -f, --color, -Z

### Detailed: zsort
**Implemented:** -b, -d, -f, -g, -i, -n, -r, -R, -V, -c, -C, -m, -o, -s, -t, -u, -z, -k
**Missing:** -h, -M, --batch-size, --compress-program, --parallel

### Detailed: zawk
**Implemented:** -F, -v, BEGIN/END blocks, pattern/action, field splitting ($1, NF), built-in variables (NR, FNR, FS, OFS, ORS, FILENAME), string functions (length, substr, index, split, sub, gsub, match, tolower, toupper, sprintf), math functions (int, sqrt, sin, cos, exp, log), associative arrays
**Missing:** -f (program file), user-defined functions, getline, system(), output redirection

### Detailed: zsed
**Implemented:** s (with g/i/I/p/N flags), d, p, q, a, i, c, =, h/H/g/G/x, n, line numbers, $ (last line), /regex/, ranges (N,M), step (N~S), -n, -e, -i, -E/-r
**Missing:** -f (script file), b/t (branching), :label, r/w (read/write files), y (transliterate)

---

## Group 3: System Info & User

| Utility | GNU Equivalent | Status | Notes |
|---------|----------------|--------|-------|
| zarch | arch | Full | All options |
| zdate | date | Partial | Good format, limited date parsing |
| zdf | df | Partial | Core options, missing fs filters |
| zdu | du | Partial | Good coverage with parallel support |
| zenv | env | Partial | Core functionality complete |
| zfree | free | Partial | Most common options |
| zgroups | groups | Full | All options |
| zhostid | hostid | Partial | Missing --version |
| zhostname | hostname | Basic | Only short name option |
| zid | id | Partial | Missing SELinux context |
| zlogname | logname | Basic | Missing --version |
| znproc | nproc | Partial | Missing --version |
| zprintenv | printenv | Full | All options |
| zps | ps | Basic | Fundamental functionality |
| zpwd | pwd | Full | All options |
| zsys | N/A | Full | Custom composite utility |
| ztty | tty | Full | All options |
| zuname | uname | Partial | Missing hardware platform |
| zuptime | uptime | Partial | Most options present |
| zusers | users | Partial | Missing FILE argument |
| zwho | who | Basic | Only heading option |
| zwhoami | whoami | Full | All options |

---

## Group 4: Encoding & Hashing

| Utility | GNU Equivalent | Status | Notes |
|---------|----------------|--------|-------|
| zbase32 | base32 | Full | All options |
| zbase64 | base64 | Full | All options |
| zbasenc | basenc | Partial | Missing z85 encoding |
| zb2sum | b2sum | Partial | Missing strict/warn/ignore-missing |
| zcksum | cksum | Basic | Only POSIX CRC-32 |
| zhashsum | N/A | Partial | Custom multi-algo, no check mode |
| zmd5sum | md5sum | Partial | Missing strict/warn/ignore-missing |
| zsha1sum | sha1sum | Partial | Missing strict/warn/ignore-missing |
| zsha256sum | sha256sum | Partial | Missing strict/warn/ignore-missing |
| zsha512sum | sha512sum | Partial | Missing strict/warn/ignore-missing |
| zsum | sum | Partial | Check mode incomplete |

### Common Missing Options (sha*sum family)
All sha*sum utilities are missing: --strict, --warn, --ignore-missing, --zero

---

## Group 5: Path & Name Utilities

| Utility | GNU Equivalent | Status | Notes |
|---------|----------------|--------|-------|
| zbasename | basename | Full | All options (-a, -s, -z) |
| zdirname | dirname | Full | All functional options |
| zpathchk | pathchk | Full | All portability checks |
| zreadlink | readlink | Full | All major options |
| zrealpath | realpath | Partial | Missing -L/-P logical/physical |
| zstat | stat | Partial | Missing filesystem stat (-f) |
| ztest | test/[ | Partial | Missing file comparison, compound expressions |
| zexpr | expr | Partial | Limited regex, basic operations |

### Detailed: zrealpath
**Implemented:** -e, -m, -s, -z, --relative-to=DIR, --relative-base=DIR, --help, --version
**Missing:** -q (quiet), -L (logical), -P (physical)

### Detailed: ztest
**Implemented:** -e, -f, -d, -r, -w, -x, -s, -L, -h, -b, -c, -p, -S, -u, -g, -k, -z, -n, =, ==, !=, -eq, -ne, -lt, -le, -gt, -ge, !
**Missing:** -O, -G, -N, -t, -ef, -nt, -ot, -a/-o (AND/OR), ( ) grouping

---

## Group 6: Process & Permission

| Utility | GNU Equivalent | Status | Notes |
|---------|----------------|--------|-------|
| zchgrp | chgrp | Partial | Missing -H/-L/-P, --reference |
| zchmod | chmod | Partial | Missing --reference, --preserve-root |
| zchown | chown | Partial | Missing -H/-L/-P, --reference, --from |
| zchroot | chroot | Full | Complete except --version |
| zkill | kill | Full | All common options |
| znice | nice | Full | Complete except --version |
| znohup | nohup | Full | Complete except --version |
| zpgrep | pgrep | Partial | Core options, missing advanced filters |
| zpkill | pkill | Partial | Core options, missing advanced filters |
| zruncon | runcon | Full | All options (requires SELinux) |
| zstdbuf | stdbuf | Basic | Uses env vars instead of LD_PRELOAD |
| zsudo | sudo | Partial | Core PAM auth, limited sudoers parsing |
| ztimeout | timeout | Full | Comprehensive implementation |

### Detailed: zsudo
**Implemented:** -u, -E, -i, -s, -v, -k, -l, -n, -H, PAM auth, credential caching, syslog
**Missing:** -g, -p, -A, -b, -C, -D, -e, -K, -S, full sudoers grammar

---

## Group 7: Miscellaneous Utilities

| Utility | GNU Equivalent | Status | Notes |
|---------|----------------|--------|-------|
| zcomm | comm | Full | All major options |
| zcsplit | csplit | Partial | Missing suffix format, keep-on-error |
| zecho | echo | Full | All escape sequences |
| zexpand | expand | Full | Tab expansion complete |
| zunexpand | unexpand | Full | Tab conversion complete |
| zfactor | factor | Full | Prime factorization |
| zfalse | false | Basic | Missing --help/--version |
| ztrue | true | Basic | Missing --help/--version |
| zmktemp | mktemp | Full | All options |
| znumfmt | numfmt | Partial | Grouping not implemented |
| zod | od | Partial | Missing float types, 8-byte ints |
| zpr | pr | Partial | Missing many formatting options |
| zprintf | printf | Partial | Missing %b and %q |
| zptx | ptx | Partial | Missing reference/formatting |
| zseq | seq | Full | All options including -w |
| zshuf | shuf | Partial | Missing random-source |
| zsleep | sleep | Full | All suffixes and decimal |
| zsync | sync | Full | All options |
| ztee | tee | Partial | Signal handling incomplete |
| ztsort | tsort | Full | Core functionality |
| zunlink | unlink | Full | All options |
| zyes | yes | Full | All functionality |

---

## Group 8: Extended & Custom Utilities

| Utility | Type | Status | Notes |
|---------|------|--------|-------|
| zbackup | Custom | Full | Meta-utility for coreutils management |
| zbench | Custom | Full | Benchmarking (hyperfine-like) |
| zcurl | Extended | Partial | Basic HTTP, lacks advanced curl features |
| zfind | Extended | Full | Parallel file finder with predicates |
| zfree | Extended | Full | Memory display utility |
| zgzip | Extended | Full | Gzip compression/decompression |
| zjq | Custom | Partial | Limited filter syntax |
| zmore | Extended | Full | File pager |
| zping | Extended | Full | ICMP ping utility |
| zregex | Custom | Full | Thompson NFA regex (ReDoS-immune) |
| zstty | Extended | Full | Comprehensive termios support |
| zsys | Custom | Full | System info aggregator |
| ztar | Extended | Full | Tar with gzip/bzip2/xz/zstd |
| ztime | Extended | Full | Command timing |
| ztree | Extended | Full | Directory tree listing |
| zuptime | Extended | Full | System uptime |
| zvdir | Extended | Full | Detailed directory listing |
| zxz | Extended | Partial | Decompression only |
| zzstd | Extended | Partial | Decompression only |

---

## Feature Highlights

### SIMD-Accelerated Utilities
- **zgrep** - SIMD pattern matching for high performance
- **zwc** - SIMD line/word counting
- **zregex** - SIMD newline search with Thompson NFA

### Parallel Execution Support
- **zdu** - --threads=N for parallel directory scanning
- **zfind** - Lock-free MPMC queue for parallel traversal
- **zxargs** - -P/--max-procs for parallel command execution

### Extended Functionality Beyond GNU
- **zsort** - Added -R (random) and -V (version sort)
- **zrealpath** - Added --relative-to and --relative-base
- **zfind** - Added --json-stats output
- **zdu** - Added --json-stats and --threads options
- **zbench** - Full hyperfine-like benchmarking

---

## Implementation Priority for Missing Features

### High Priority
1. **zxz/zzstd** - Add compression support (currently decompress only)
2. **zcp** - Add --reflink, --sparse for modern filesystems
3. **zsed** - Add -f script file support
4. **zawk** - Add -f program file support

### Medium Priority
1. **sha*sum family** - Add --strict, --warn, --ignore-missing
2. **ztest** - Add compound expressions, file comparison
3. **zpgrep/zpkill** - Add advanced process filters

### Low Priority
1. **ztrue/zfalse** - Add --help/--version (trivial utilities)
2. **zhostid/zlogname/znproc** - Add --version

---

## Legend

- **Full**: All or nearly all GNU options implemented
- **Partial**: Core functionality complete, some options missing
- **Basic**: Minimal implementation, fundamental functionality only

---

*Generated: 2026-01-06*
*Utilities analyzed: 129 (excluding 2 not found)*
