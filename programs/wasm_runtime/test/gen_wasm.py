#!/usr/bin/env python3
"""Generate a minimal valid WASM module for testing."""

import struct

def leb128_unsigned(val):
    """Encode unsigned integer as LEB128."""
    result = []
    while True:
        byte = val & 0x7f
        val >>= 7
        if val != 0:
            byte |= 0x80
        result.append(byte)
        if val == 0:
            break
    return bytes(result)

def make_section(section_id, content):
    """Create a WASM section."""
    return bytes([section_id]) + leb128_unsigned(len(content)) + content

def make_minimal_wasm():
    """
    Create a minimal WASM module that:
    - Has a function type () -> i32
    - Has one function that returns 42
    - Exports it as "_start"
    """
    wasm = bytearray()

    # Magic number and version
    wasm.extend(b'\x00asm')  # WASM magic
    wasm.extend(struct.pack('<I', 1))  # Version 1

    # Type section (id=1): one function type () -> i32
    type_section = bytearray()
    type_section.append(1)  # count of types
    type_section.append(0x60)  # func type marker
    type_section.append(0)  # param count
    type_section.append(1)  # result count
    type_section.append(0x7f)  # i32
    wasm.extend(make_section(1, bytes(type_section)))

    # Function section (id=3): one function using type 0
    func_section = bytearray()
    func_section.append(1)  # count
    func_section.append(0)  # type index 0
    wasm.extend(make_section(3, bytes(func_section)))

    # Export section (id=7): export the function as "_start"
    export_section = bytearray()
    export_section.append(1)  # count
    export_section.append(6)  # name length
    export_section.extend(b'_start')  # name
    export_section.append(0)  # export kind: function
    export_section.append(0)  # function index
    wasm.extend(make_section(7, bytes(export_section)))

    # Code section (id=10): function body
    code_section = bytearray()
    code_section.append(1)  # count of function bodies

    # Function body
    body = bytearray()
    body.append(0)  # local count
    body.append(0x41)  # i32.const
    body.append(42)  # value 42 (LEB128)
    body.append(0x0b)  # end

    code_section.append(len(body))  # body size
    code_section.extend(body)
    wasm.extend(make_section(10, bytes(code_section)))

    return bytes(wasm)

def make_hello_wasm():
    """
    Create a WASM module that uses WASI to print "Hello, World!"
    - Imports fd_write from wasi_snapshot_preview1
    - Has memory
    - Has _start that calls fd_write
    """
    wasm = bytearray()

    # Magic number and version
    wasm.extend(b'\x00asm')
    wasm.extend(struct.pack('<I', 1))

    # Type section:
    # type 0: (i32, i32, i32, i32) -> i32  (fd_write)
    # type 1: () -> ()  (_start)
    type_section = bytearray()
    type_section.append(2)  # count
    # fd_write type
    type_section.append(0x60)
    type_section.append(4)  # 4 params
    type_section.extend([0x7f, 0x7f, 0x7f, 0x7f])  # i32 x 4
    type_section.append(1)  # 1 result
    type_section.append(0x7f)  # i32
    # _start type
    type_section.append(0x60)
    type_section.append(0)  # 0 params
    type_section.append(0)  # 0 results
    wasm.extend(make_section(1, bytes(type_section)))

    # Import section: fd_write from wasi_snapshot_preview1
    import_section = bytearray()
    import_section.append(1)  # count
    # module name
    mod_name = b'wasi_snapshot_preview1'
    import_section.append(len(mod_name))
    import_section.extend(mod_name)
    # func name
    func_name = b'fd_write'
    import_section.append(len(func_name))
    import_section.extend(func_name)
    import_section.append(0)  # import kind: function
    import_section.append(0)  # type index 0
    wasm.extend(make_section(2, bytes(import_section)))

    # Function section: _start
    func_section = bytearray()
    func_section.append(1)  # count
    func_section.append(1)  # type index 1
    wasm.extend(make_section(3, bytes(func_section)))

    # Memory section: one memory with 1 page min
    mem_section = bytearray()
    mem_section.append(1)  # count
    mem_section.append(0)  # flags (no max)
    mem_section.append(1)  # initial 1 page
    wasm.extend(make_section(5, bytes(mem_section)))

    # Export section: export memory and _start
    export_section = bytearray()
    export_section.append(2)  # count
    # Export memory
    export_section.append(6)
    export_section.extend(b'memory')
    export_section.append(2)  # memory
    export_section.append(0)  # index
    # Export _start
    export_section.append(6)
    export_section.extend(b'_start')
    export_section.append(0)  # function
    export_section.append(1)  # function index (0 is imported fd_write)
    wasm.extend(make_section(7, bytes(export_section)))

    # Data section: store "Hello, World!\n" at offset 8
    # and iovec struct at offset 0
    hello = b'Hello, World!\n'
    data_section = bytearray()
    data_section.append(1)  # count
    data_section.append(0)  # memory index
    # init expr: i32.const 0, end
    data_section.append(0x41)
    data_section.append(0)
    data_section.append(0x0b)
    # data: iovec at 0 (ptr=8, len=14), then message at 8
    iovec_and_msg = struct.pack('<II', 8, len(hello)) + hello
    data_section.append(len(iovec_and_msg))
    data_section.extend(iovec_and_msg)
    wasm.extend(make_section(11, bytes(data_section)))

    # Code section: _start body
    code_section = bytearray()
    code_section.append(1)  # count

    body = bytearray()
    body.append(0)  # no locals
    # fd_write(1, 0, 1, 100)
    # fd = 1 (stdout)
    body.append(0x41); body.append(1)
    # iovs = 0 (pointer to iovec)
    body.append(0x41); body.append(0)
    # iovs_len = 1
    body.append(0x41); body.append(1)
    # nwritten = 100 (arbitrary location for result)
    body.append(0x41); body.append(100)
    # call fd_write (function 0)
    body.append(0x10); body.append(0)
    # drop result
    body.append(0x1a)
    # end
    body.append(0x0b)

    code_section.append(len(body))
    code_section.extend(body)
    wasm.extend(make_section(10, bytes(code_section)))

    return bytes(wasm)

if __name__ == '__main__':
    import sys

    # Generate minimal.wasm
    minimal = make_minimal_wasm()
    with open('test/minimal.wasm', 'wb') as f:
        f.write(minimal)
    print(f'Generated test/minimal.wasm ({len(minimal)} bytes)')

    # Generate hello.wasm
    hello = make_hello_wasm()
    with open('test/hello.wasm', 'wb') as f:
        f.write(hello)
    print(f'Generated test/hello.wasm ({len(hello)} bytes)')
