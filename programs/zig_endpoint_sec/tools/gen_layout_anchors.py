#!/usr/bin/env python3
"""Generate src/layout_anchors.zig from the EndpointSecurity SDK headers.

The Zig bindings in src/sys.zig are hand-written, so their struct layouts and
enum values need an authority the author did not produce. This script parses
the SDK headers only to learn *which* types and fields exist, then asks Apple's
clang for every sizeof/offsetof/enumerator value and writes them out as data.
The Zig test suite compares @sizeOf/@offsetOf/@intFromEnum against that table.

Also emits src/enums.zig: the enum declarations themselves, so 165 event tags
are not typed by hand. Their values are still checked against clang's.

Usage: tools/gen_layout_anchors.py [--sdk PATH]
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(os.path.dirname(HERE), "src")
HEADERS = ["ESTypes.h", "ESMessageCore.h", "ESMessage.h", "ESClient.h"]

# Types used by ES structs that live in other headers; size-only anchors so
# the std.c definitions the bindings rely on are checked too.
FOREIGN_SIZES = [
    ("struct stat", "stat"),
    ("struct statfs", "statfs"),
    ("struct attrlist", "attrlist"),
    ("struct timespec", "timespec"),
    ("struct timeval", "timeval"),
    ("audit_token_t", "audit_token_t"),
    ("uuid_t", "uuid_t"),
    ("acl_t", "acl_t"),
    ("cpu_type_t", "cpu_type_t"),
    ("cpu_subtype_t", "cpu_subtype_t"),
    ("user_addr_t", "user_addr_t"),
    ("user_size_t", "user_size_t"),
    ("dev_t", "dev_t"),
    ("mode_t", "mode_t"),
    ("uid_t", "uid_t"),
    ("gid_t", "gid_t"),
    ("pid_t", "pid_t"),
]


def sdk_path(explicit):
    if explicit:
        return explicit
    return subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    return text


def strip_attributes(text):
    # API_AVAILABLE(macos(13.0)), API_DEPRECATED("...", macos(10.15, 12.0)), OS_EXPORT ...
    text = re.sub(r"\bAPI_(AVAILABLE|DEPRECATED|UNAVAILABLE)\s*\((?:[^()]|\([^()]*\))*\)", "", text)
    text = re.sub(r"\b(OS_EXPORT|OS_OBJECT_RETURNS_RETAINED|_Nonnull|_Nullable|__BEGIN_DECLS|__END_DECLS)\b", "", text)
    text = re.sub(r"^\s*#.*$", "", text, flags=re.M)
    return text


def load_header_text(sdk):
    parts = []
    for h in HEADERS:
        with open(os.path.join(sdk, "usr/include/EndpointSecurity", h)) as f:
            parts.append(f.read())
    return strip_attributes(strip_comments("\n".join(parts)))


VERSION_NOTE = re.compile(r"(?:field available only if message version|available in msg versions?)\s*>=\s*(\d+)", re.I)


def parse_min_versions(sdk):
    """(struct, field, min_message_version) for every field the header marks
    as only meaningful from a given es_message_t.version onward."""
    out = []
    for h in HEADERS:
        with open(os.path.join(sdk, "usr/include/EndpointSecurity", h)) as f:
            lines = f.read().splitlines()
        pending = []  # fields seen since the last typedef opened
        for line in lines:
            m = VERSION_NOTE.search(line)
            if m:
                decl = line.split("/*")[0].split("//")[0].strip().rstrip(";")
                decl = re.sub(r"\b_Nonnull\b|\b_Nullable\b|\*", " ", decl)
                name = decl.split()[-1]
                pending.append((name, int(m.group(1))))
            closing = re.match(r"^\}\s*(\w+)\s*;", line)
            if closing:
                for name, ver in pending:
                    out.append((closing.group(1), name, ver))
                pending = []
    return out


class Struct:
    def __init__(self, name, kind):
        self.name = name
        self.kind = kind  # "struct" or "union"
        self.paths = []   # dotted C member designators


def parse_enums(text):
    enums = []
    for m in re.finditer(r"typedef\s+enum\s*\{(.*?)\}\s*(\w+)\s*;", text, flags=re.S):
        body, name = m.group(1), m.group(2)
        tags = []
        value = -1
        for item in body.split(","):
            item = item.strip()
            if not item:
                continue
            if "=" in item:
                tag, expr = [x.strip() for x in item.split("=", 1)]
                value = int(expr, 0)
            else:
                tag = item
                value += 1
            if not re.match(r"^[A-Z_0-9]+$", tag):
                raise SystemExit(f"unexpected enumerator {tag!r} in {name}")
            tags.append((tag, value))
        enums.append((name, tags))
    return enums


def split_fields(body):
    """Yield (declaration_text, nested_body_or_None) for one aggregate body."""
    i = 0
    n = len(body)
    while i < n:
        # find end of this declaration: ';' at depth 0
        depth = 0
        j = i
        nested_start = nested_end = None
        while j < n:
            c = body[j]
            if c == "{":
                if depth == 0:
                    nested_start = j
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    nested_end = j
            elif c == ";" and depth == 0:
                break
            j += 1
        decl = body[i:j].strip()
        if nested_start is not None:
            head = body[i:nested_start].strip()
            inner = body[nested_start + 1:nested_end]
            tail = body[nested_end + 1:j].strip()
            i = j + 1
            yield (head, inner, tail)
        else:
            i = j + 1
            if decl:
                yield (decl, None, None)


def field_name(decl):
    # "es_file_t *target", "uint8_t reserved[64]", "uint64_t opaque[]", "int sig"
    decl = decl.replace("*", " ")
    m = re.search(r"(\w+)\s*(\[[^\]]*\])?\s*$", decl)
    if not m:
        raise SystemExit(f"cannot parse field {decl!r}")
    name, arr = m.group(1), m.group(2)
    flexible = arr is not None and arr.strip("[] ") == ""
    return name, flexible


def collect_paths(body, prefix, out):
    for head, inner, tail in split_fields(body):
        if inner is None:
            name, flexible = field_name(head)
            if flexible:
                continue  # sizeof excludes flexible array members; Zig has none
            out.append(prefix + name)
        else:
            # nested struct/union; tail is the member name (or empty = anonymous)
            if tail:
                nested_name = tail.strip()
                collect_paths(inner, prefix + nested_name + ".", out)
            else:
                collect_paths(inner, prefix, out)  # anonymous: members are promoted


def parse_structs(text):
    structs = []
    # Find "typedef struct {" ... "} name;" with balanced braces.
    for m in re.finditer(r"typedef\s+(struct|union)\s*\{", text):
        kind = m.group(1)
        depth = 1
        j = m.end()
        while depth:
            c = text[j]
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
            j += 1
        body = text[m.end():j - 1]
        tail = re.match(r"\s*(\w+)\s*;", text[j:])
        if not tail:
            continue
        s = Struct(tail.group(1), kind)
        collect_paths(body, "", s.paths)
        structs.append(s)
    return structs


def parse_array_typedefs(text):
    # typedef uint8_t es_cdhash_t[20];
    return re.findall(r"typedef\s+\w+\s+(\w+)\s*\[\s*\d+\s*\]\s*;", text)


def write_probe(path, structs, enums, arrays):
    lines = [
        "#include <EndpointSecurity/EndpointSecurity.h>",
        "#include <sys/attr.h>",
        "#include <sys/mount.h>",
        "#include <sys/stat.h>",
        "#include <sys/time.h>",
        "#include <sys/acl.h>",
        "#include <uuid/uuid.h>",
        "#include <stdio.h>",
        "#include <stddef.h>",
        "int main(void) {",
    ]
    for s in structs:
        lines.append(f'  printf("S {s.name} %zu\\n", sizeof({s.name}));')
        for p in s.paths:
            lines.append(f'  printf("F {s.name} {p} %zu\\n", offsetof({s.name}, {p}));')
    for a in arrays:
        lines.append(f'  printf("A {a} %zu\\n", sizeof({a}));')
    for ctype, label in FOREIGN_SIZES:
        lines.append(f'  printf("X {label} %zu\\n", sizeof({ctype}));')
    for name, tags in enums:
        lines.append(f'  printf("N {name} %zu\\n", sizeof({name}));')
        for tag, _ in tags:
            lines.append(f'  printf("E {name} {tag} %lld\\n", (long long){tag});')
    lines.append("  return 0;")
    lines.append("}")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def run_probe(sdk, probe_c):
    exe = probe_c[:-2]
    subprocess.check_call(["xcrun", "clang", "-isysroot", sdk, "-Wno-deprecated-declarations", probe_c, "-o", exe])
    return subprocess.check_output([exe], text=True)


def zig_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def emit_anchors(out_path, output, sdk_label, structs_order, min_versions):
    sizes, fields, arrays, foreign, enum_sizes, enum_tags = {}, {}, {}, {}, {}, {}
    for line in output.splitlines():
        kind, rest = line.split(" ", 1)
        if kind == "S":
            name, size = rest.split()
            sizes[name] = int(size)
        elif kind == "F":
            name, path, off = rest.split()
            fields.setdefault(name, []).append((path, int(off)))
        elif kind == "A":
            name, size = rest.split()
            arrays[name] = int(size)
        elif kind == "X":
            name, size = rest.split()
            foreign[name] = int(size)
        elif kind == "N":
            name, size = rest.split()
            enum_sizes[name] = int(size)
        elif kind == "E":
            name, tag, value = rest.split()
            enum_tags.setdefault(name, []).append((tag, int(value)))

    o = []
    o.append("//! GENERATED by tools/gen_layout_anchors.py — do not edit.")
    o.append(f"//! Source of truth: {sdk_label}")
    o.append("//!")
    o.append("//! Every number here was computed by Apple's clang from the SDK headers.")
    o.append("//! src/anchors_test.zig compares the hand-written bindings in src/sys.zig")
    o.append("//! against this table, so a transcription error fails a test instead of")
    o.append("//! silently reading the wrong bytes out of a kernel message.")
    o.append("")
    o.append(f"pub const sdk = {zig_str(sdk_label)};")
    o.append("")
    o.append("pub const Field = struct { path: []const u8, offset: usize };")
    o.append("pub const Struct = struct { name: []const u8, size: usize, fields: []const Field };")
    o.append("pub const Tag = struct { name: []const u8, value: i64 };")
    o.append("pub const Enum = struct { name: []const u8, size: usize, tags: []const Tag };")
    o.append("pub const Sized = struct { name: []const u8, size: usize };")
    o.append("")
    o.append("pub const structs = [_]Struct{")
    for s in structs_order:
        if s.name not in sizes:
            continue
        o.append(f"    .{{ .name = {zig_str(s.name)}, .size = {sizes[s.name]}, .fields = &.{{")
        for path, off in fields.get(s.name, []):
            o.append(f"        .{{ .path = {zig_str(path)}, .offset = {off} }},")
        o.append("    } },")
    o.append("};")
    o.append("")
    o.append("/// Fixed-size array typedefs (es_cdhash_t, es_sha256_t).")
    o.append("pub const arrays = [_]Sized{")
    for name, size in arrays.items():
        o.append(f"    .{{ .name = {zig_str(name)}, .size = {size} }},")
    o.append("};")
    o.append("")
    o.append("/// Types from other system headers that ES structs embed or point to.")
    o.append("pub const foreign = [_]Sized{")
    for name, size in foreign.items():
        o.append(f"    .{{ .name = {zig_str(name)}, .size = {size} }},")
    o.append("};")
    o.append("")
    o.append("pub const VersionedField = struct { type: []const u8, field: []const u8, min_version: u32 };")
    o.append("")
    o.append("/// Fields the header marks \"available only if message version >= N\".")
    o.append("/// Reading them from an older-version message yields garbage.")
    o.append("pub const min_versions = [_]VersionedField{")
    for st, field, ver in min_versions:
        o.append(f"    .{{ .type = {zig_str(st)}, .field = {zig_str(field)}, .min_version = {ver} }},")
    o.append("};")
    o.append("")
    o.append("pub const enums = [_]Enum{")
    for name, size in enum_sizes.items():
        o.append(f"    .{{ .name = {zig_str(name)}, .size = {size}, .tags = &.{{")
        for tag, value in enum_tags.get(name, []):
            o.append(f"        .{{ .name = {zig_str(tag)}, .value = {value} }},")
        o.append("    } },")
    o.append("};")
    with open(out_path, "w") as f:
        f.write("\n".join(o) + "\n")
    return sizes, enum_tags


def emit_enums(out_path, enums, enum_tags, sdk_label):
    o = []
    o.append("//! GENERATED by tools/gen_layout_anchors.py — do not edit.")
    o.append(f"//! Enum declarations transcribed from {sdk_label}.")
    o.append("//!")
    o.append("//! Every enum is non-exhaustive (`_`): a newer kernel may deliver values")
    o.append("//! this SDK does not know, and a switch must treat those as unknown rather")
    o.append("//! than trap. C enums are `unsigned int` here, hence `enum(u32)`.")
    o.append("")
    for name, _ in enums:
        tags = enum_tags[name]
        o.append(f"pub const {name} = enum(u32) {{")
        for tag, value in tags:
            o.append(f"    {tag} = {value},")
        o.append("    _,")
        o.append("};")
        o.append("")
    with open(out_path, "w") as f:
        f.write("\n".join(o))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sdk")
    args = ap.parse_args()
    sdk = sdk_path(args.sdk)

    text = load_header_text(sdk)
    enums = parse_enums(text)
    structs = parse_structs(text)
    arrays = parse_array_typedefs(text)

    sdk_name = os.path.basename(os.path.realpath(sdk))
    clang_ver = subprocess.check_output(["xcrun", "clang", "--version"], text=True).splitlines()[0]
    sdk_label = f"{sdk_name} via {clang_ver}"

    with tempfile.TemporaryDirectory() as tmp:
        probe = os.path.join(tmp, "probe.c")
        write_probe(probe, structs, enums, arrays)
        output = run_probe(sdk, probe)

    min_versions = parse_min_versions(sdk)
    sizes, enum_tags = emit_anchors(os.path.join(SRC, "layout_anchors.zig"), output, sdk_label, structs, min_versions)
    emit_enums(os.path.join(SRC, "enums.zig"), enums, enum_tags, sdk_label)
    print(f"{len(sizes)} structs, {sum(len(t) for t in enum_tags.values())} enumerators in {len(enum_tags)} enums, {len(arrays)} array typedefs, {len(min_versions)} version-gated fields")


if __name__ == "__main__":
    main()
