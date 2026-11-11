#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
weaken_libcxx_imports.py  (v2 — chained-fixups aware, full-tree iOS 15 compat)
=============================================================================

为什么 v1 完全无效（latestlog8/9/10 的直接原因）
------------------------------------------------
CI 用 iOS 26.x SDK 链接，MobileGL 又定义了 ``_LIBCPP_DISABLE_AVAILABILITY``，
压掉 libc++ 头里的 ``availability(introduced=iOS 16.3)`` 标注。于是 clang /
ld64 把 C++20/23 新符号（浮点 ``std::to_chars``、``std::expected``、
``std::format``、``bad_expected_access<void>`` 的 vtable/RTTI …）编成
对 ``/usr/lib/libc++.1.dylib`` 的 **强引用**。iPadOS 15.0 的系统 libc++ 没有
它们，dyld 在 dlopen 阶段直接拒绝加载::

    dlopen(@rpath/libMobileGL.dylib, 0x000A):
      Symbol not found: __ZTVNSt3__119bad_expected_accessIvEE
        Expected in: /usr/lib/libc++.1.dylib

**v1 的错误**：只改了 ``LC_SYMTAB`` 里 nlist_64 的 ``N_WEAK_REF`` 位。
但 ld64 自 Xcode 14 起默认生成 ``LC_DYLD_CHAINED_FIXUPS``，dyld 判 weak
靠的是 **chained fixups import table 里每个条目的 ``weak_import`` 位**，
根本不读 symtab 的 n_desc。所以 v1 的 ``--verify`` 自己检查自己、显示
"236 个已 weak 化 VERIFIED"，真实 dyld 仍按强引用绑定 —— 自欺欺人。

本版同时改写两处，保证 dyld 与 nm / 静态检查看到的是同一件事：
  1) ``LC_DYLD_CHAINED_FIXUPS`` 的 import table：libc++ 条目 ``weak_import=1``
  2) ``LC_SYMTAB`` 的 nlist_64：libc++ undefined ``n_desc |= N_WEAK_REF``

覆盖范围（不再打地鼠）
----------------------
实测仓库 30 个 vendored dylib 中 24 个含 chained fixups，
libc++ undefined import 合计 **1514 个且全部为强引用**，分布在 MobileGL×2 /
MoltenVK / mithril / glslang×3 / shaderc×2 / spirv-cross×4 / OSMesa /
lwjgl_vma / metallum×2 等。逐个补符号、或只处理 MobileGL 都是打地鼠。
本脚本对 ``--all <dir>`` 下的**每一个** arm64 Mach-O 做集合级处理，
不依赖任何符号名清单。

另外把 ``LC_BUILD_VERSION.minos`` / ``LC_VERSION_MIN_IPHONEOS.version``
异常高于目标系统（>15.0）的降到 14.0.0（项目 deployment target），
避免 dyld 因 minos 过高直接拒绝（实测 libvulkan.1.dylib 为 26.2.0）。

用法
----
    python3 weaken_libcxx_imports.py <file|dir> ...        # 处理（幂等）
    python3 weaken_libcxx_imports.py --all <dir>           # 递归处理目录内所有 arm64 Mach-O
    python3 weaken_libcxx_imports.py --verify --all <dir>  # 只读校验（检查 fixup 位）
    python3 weaken_libcxx_imports.py --report --all <dir>  # 只输出审计报告
    python3 weaken_libcxx_imports.py --self-test           # 合成 Mach-O 自测

只改 ``LC_DYLD_CHAINED_FIXUPS`` 数据区、``LC_SYMTAB`` n_desc 与 version 字段，
不改文件长度、不改 load commands、不触碰代码段；签名由打包阶段 ldid -S 重签覆盖。
"""

import os
import struct
import sys

# ---- Mach-O 常量 -----------------------------------------------------------
MH_MAGIC_64 = 0xFEEDFACF
ABI64 = 0x01000000
LC_REQ_DYLD = 0x80000000

LC_SYMTAB = 0x2
LC_VERSION_MIN_IPHONEOS = 0x2C
LC_BUILD_VERSION = 0x32
LC_DYLD_CHAINED_FIXUPS = 0x34          # 实际 cmd 带 LC_REQ_DYLD = 0x80000034
DYLIB_CMDS = {0xC, 0x18, 0x1F, 0x20, 0x23}   # LOAD / WEAK / REEXPORT / LAZY / UPWARD

N_EXT = 0x01
N_TYPE = 0x0E
N_UNDF = 0x00
N_WEAK_REF = 0x0040
NLIST64_SIZE = 16

# dyld chained fixups import 格式：
#   1 DYLD_CHAINED_IMPORT           : uint32 lib_ordinal:8, weak:1, name_offset:23   (4B)
#   2 DYLD_CHAINED_IMPORT_ADDEND    : 同上 + int32 addend                              (8B)
#   3 DYLD_CHAINED_IMPORT_ADDEND64  : uint64 lib_ordinal:16, weak:1, reserved:15,
#                                     name_offset:32 + int64 addend                    (16B)
IMPORT_FORMATS = {
    1: dict(size=4,  wide=False, ordinal_mask=0xFF,   weak_shift=8),
    2: dict(size=8,  wide=False, ordinal_mask=0xFF,   weak_shift=8),
    3: dict(size=16, wide=True,  ordinal_mask=0xFFFF, weak_shift=16),
}

TARGET_MINOS = (14, 0, 0)      # 项目 deployment target
MAX_MINOS = (15, 0, 0)         # 目标设备 iPadOS 15.0；超过即视为异常


def decode_ver(v):
    return (v >> 16, (v >> 8) & 0xFF, v & 0xFF)


def encode_ver(t):
    return (t[0] << 16) | (t[1] << 8) | t[2]


def vstr(t):
    return "%d.%d.%d" % t


# ---- 解析 ------------------------------------------------------------------
def parse(data):
    if len(data) < 32:
        raise ValueError("file too short for a Mach-O header")
    magic, cputype = struct.unpack_from("<2I", data, 0)
    if magic != MH_MAGIC_64:
        raise ValueError("not a little-endian 64-bit Mach-O (magic=0x%08x)" % magic)
    if (cputype & 0xFF000000) != ABI64:
        raise ValueError("not a 64-bit Mach-O (cputype=0x%08x)" % cputype)

    ncmds = struct.unpack_from("<I", data, 16)[0]
    sizeofcmds = struct.unpack_from("<I", data, 20)[0]
    if 32 + sizeofcmds > len(data):
        raise ValueError("load commands extend past end of file")

    off = 32
    ordinal = 0
    dylibs = []
    libcxx = set()
    symtab = None
    fixups_cmd = None
    version_fields = []      # (file offset of the version uint32, cmd base)

    for _ in range(ncmds):
        if off + 8 > len(data):
            raise ValueError("truncated load command at 0x%x" % off)
        cmd, cmdsize = struct.unpack_from("<2I", data, off)
        if cmdsize < 8 or off + cmdsize > 32 + sizeofcmds:
            raise ValueError("invalid load command size at 0x%x" % off)
        base = cmd & ~LC_REQ_DYLD

        if base in DYLIB_CMDS:
            ordinal += 1
            if cmdsize < 24:
                raise ValueError("truncated dylib_command at 0x%x" % off)
            name_off = struct.unpack_from("<I", data, off + 8)[0]
            if name_off < 24 or name_off >= cmdsize:
                raise ValueError("invalid dylib name offset at 0x%x" % off)
            name = bytes(data[off + name_off: off + cmdsize]).split(b"\0", 1)[0]
            name = name.decode("utf-8", "replace")
            dylibs.append((ordinal, name))
            if "libc++" in name:
                libcxx.add(ordinal)
        elif base == LC_SYMTAB:
            if cmdsize < 24:
                raise ValueError("truncated symtab_command at 0x%x" % off)
            symtab = struct.unpack_from("<4I", data, off + 8)
        elif base == LC_DYLD_CHAINED_FIXUPS:
            if cmdsize < 16:
                raise ValueError("truncated linkedit_data_command at 0x%x" % off)
            fixups_cmd = struct.unpack_from("<2I", data, off + 8)   # (dataoff, datasize)
        elif base == LC_BUILD_VERSION:
            version_fields.append((off + 12, base))                 # minos
        elif base == LC_VERSION_MIN_IPHONEOS:
            version_fields.append((off + 8, base))                  # version

        off += cmdsize

    if symtab:
        symoff, nsyms, stroff, strsize = symtab
        if symoff + nsyms * NLIST64_SIZE > len(data):
            raise ValueError("symbol table extends past end of file")
        if stroff + strsize > len(data):
            raise ValueError("string table extends past end of file")

    fx = None
    if fixups_cmd:
        dataoff, datasize = fixups_cmd
        if dataoff + 28 > len(data):
            raise ValueError("chained fixups header extends past end of file")
        (fver, starts_off, imports_off, symbols_off,
         imports_count, imports_format, symbols_format) = struct.unpack_from("<7I", data, dataoff)
        if imports_format not in IMPORT_FORMATS:
            raise ValueError("unsupported imports_format=%d" % imports_format)
        fmt = IMPORT_FORMATS[imports_format]
        table = dataoff + imports_off
        if table + imports_count * fmt["size"] > len(data):
            raise ValueError("chained fixups import table extends past end of file")
        fx = dict(dataoff=dataoff, datasize=datasize, imports_off=imports_off,
                  symbols_off=symbols_off, count=imports_count,
                  fmt=imports_format, fmtinfo=fmt, table=table,
                  symbols_format=symbols_format)

    minos = None
    for p, base in version_fields:
        v = struct.unpack_from("<I", data, p)[0]
        if minos is None or decode_ver(v) > minos:
            minos = decode_ver(v)

    return dict(symtab=symtab, libcxx=libcxx, dylibs=dylibs,
                fixups=fx, version_fields=version_fields, minos=minos,
                ncmds=ncmds)


# ---- 处理 ------------------------------------------------------------------
def process(data, modify=True, fix_minos=True):
    buf = bytearray(data)
    info = parse(buf)
    st = dict(libcxx_imports=0, fixup_strong=0, fixup_newly_weak=0,
              symtab_undef=0, symtab_libcxx=0, symtab_strong=0, symtab_newly_weak=0,
              minos_over=[], minos_fixed=0,
              ncmds=info["ncmds"], minos=info["minos"],
              libcxx=sorted(info["libcxx"]),
              fixup_count=info["fixups"]["count"] if info["fixups"] else 0,
              fixup_fmt=info["fixups"]["fmt"] if info["fixups"] else 0,
              has_fixups=bool(info["fixups"]))

    fx = info["fixups"]
    if fx:
        fmt = fx["fmtinfo"]
        for k in range(fx["count"]):
            p = fx["table"] + k * fmt["size"]
            if fmt["wide"]:
                v = struct.unpack_from("<Q", buf, p)[0]
            else:
                v = struct.unpack_from("<I", buf, p)[0]
            lo = v & fmt["ordinal_mask"]
            weak = (v >> fmt["weak_shift"]) & 1
            if lo in info["libcxx"]:
                st["libcxx_imports"] += 1
                if not weak:
                    st["fixup_strong"] += 1
                    if modify:
                        nv = v | (1 << fmt["weak_shift"])
                        if fmt["wide"]:
                            struct.pack_into("<Q", buf, p, nv)
                        else:
                            struct.pack_into("<I", buf, p, nv)
                        st["fixup_newly_weak"] += 1

    symtab = info["symtab"]
    if symtab:
        symoff, nsyms, _, _ = symtab
        for i in range(nsyms):
            p = symoff + i * NLIST64_SIZE
            _, n_type, _, n_desc, n_value = struct.unpack_from("<IBBHQ", buf, p)
            if (n_type & N_TYPE) == N_UNDF and n_value == 0:
                st["symtab_undef"] += 1
                if ((n_desc >> 8) & 0xFF) in info["libcxx"]:
                    st["symtab_libcxx"] += 1
                    if not (n_desc & N_WEAK_REF):
                        st["symtab_strong"] += 1
                        if modify:
                            struct.pack_into("<H", buf, p + 6, n_desc | N_WEAK_REF)
                            st["symtab_newly_weak"] += 1

    if fix_minos:
        for p, _ in info["version_fields"]:
            v = struct.unpack_from("<I", buf, p)[0]
            ver = decode_ver(v)
            if ver > MAX_MINOS:
                st["minos_over"].append(ver)
                if modify:
                    struct.pack_into("<I", buf, p, encode_ver(TARGET_MINOS))
                    st["minos_fixed"] += 1

    out = bytes(buf) if modify else None
    if modify:
        # 在改写后的副本上重新只读统计，作为自校验（检查的是 fixup 位，不是自说自话）
        r2, _, i2 = process(out, modify=False, fix_minos=True)
        st["verify_fixup_strong"] = r2["fixup_strong"]
        st["verify_symtab_strong"] = r2["symtab_strong"]
        st["verify_minos_over"] = len(r2["minos_over"])
        st["minos_after"] = i2["minos"]
    return st, out, info


# ---- 输出 ------------------------------------------------------------------
def describe(path, st, mode):
    print("[ios15/%s] %s" % (mode, path))
    print("    chained-fixups: %s (imports=%d format=%d)  libc++ ordinals: %s"
          % ("YES" if st["has_fixups"] else "no", st["fixup_count"],
             st["fixup_fmt"], st["libcxx"] or "<none>"))
    print("    fixup import table : libc++=%d  strong=%d  -> weak +%d"
          % (st["libcxx_imports"], st["fixup_strong"], st["fixup_newly_weak"]))
    print("    LC_SYMTAB          : undefined=%d  libc++=%d  strong=%d  -> weak +%d"
          % (st["symtab_undef"], st["symtab_libcxx"],
             st["symtab_strong"], st["symtab_newly_weak"]))
    if st["minos_over"]:
        print("    minos: %s -> %s  (was > %s: %s)"
              % (vstr(st["minos"]), vstr(st.get("minos_after") or TARGET_MINOS),
                 vstr(MAX_MINOS), ", ".join(vstr(v) for v in st["minos_over"])))
    else:
        print("    minos: %s (OK)" % (vstr(st["minos"]) if st["minos"] else "n/a"))


def process_path(path, verify=False, report=False):
    with open(path, "rb") as f:
        data = f.read()
    st, out, _ = process(data, modify=not (verify or report), fix_minos=True)

    if report:
        if st["libcxx_imports"] or st["minos_over"]:
            describe(path, st, "REPORT")
        return True

    if verify:
        describe(path, st, "VERIFY")
        bad = []
        if st["fixup_strong"]:
            bad.append("%d libc++ imports STRONG in fixup table (dyld WILL reject dlopen)"
                       % st["fixup_strong"])
        if st["symtab_strong"]:
            bad.append("%d libc++ undefined STRONG in symtab" % st["symtab_strong"])
        if st["minos_over"]:
            bad.append("minos > %s: %s" % (vstr(MAX_MINOS),
                                           ", ".join(vstr(v) for v in st["minos_over"])))
        if bad:
            for b in bad:
                print("    ERROR: " + b)
            return False
        print("    VERIFIED")
        return True

    describe(path, st, "WEAKEN")
    if st.get("verify_fixup_strong") or st.get("verify_symtab_strong") or st.get("verify_minos_over"):
        print("    ERROR: post-rewrite verification failed: fixup=%d symtab=%d minos=%d"
              % (st.get("verify_fixup_strong", 0), st.get("verify_symtab_strong", 0),
                 st.get("verify_minos_over", 0)))
        return False
    if out != data:
        with open(path, "wb") as f:
            f.write(out)
        print("    WROTE (fixup weak +%d, symtab weak +%d, minos fixed %d) -> VERIFIED"
              % (st["fixup_newly_weak"], st["symtab_newly_weak"], st["minos_fixed"]))
    else:
        print("    already compliant (idempotent, no write)")
    return True


def collect(paths, all_mode):
    out = []
    for p in paths:
        if os.path.isdir(p):
            if not all_mode:
                continue
            for root, dirs, files in os.walk(p):
                for fn in files:
                    fp = os.path.join(root, fn)
                    if os.path.islink(fp):
                        continue
                    try:
                        with open(fp, "rb") as f:
                            if f.read(4) == b"\xcf\xfa\xed\xfe":
                                out.append(fp)
                    except OSError:
                        pass
        elif os.path.isfile(p):
            out.append(p)
    return sorted(set(out))


# ---- 合成 Mach-O 自测（含 chained fixups） ---------------------------------
def _dylib_cmd(cmd, name):
    nb = name.encode() + b"\0"
    size = (24 + len(nb) + 7) & ~7
    b = bytearray(size)
    struct.pack_into("<6I", b, 0, cmd, size, 24, 0, 0, 0)
    b[24:24 + len(nb)] = nb
    return bytes(b)


def _build_synthetic():
    """含 LC_DYLD_CHAINED_FIXUPS / LC_SYMTAB / LC_BUILD_VERSION 的最小 arm64 Mach-O。"""
    LC_LOAD_DYLIB = 0xC
    pool = b"_syscall\0__ZTVbad_expected\0"       # name_offset 0 / 9
    fixes = bytearray()
    fixes += struct.pack("<7I", 0, 28, 32, 40, 2, 1, 0)   # header, imports at +32, symbols at +40
    fixes += struct.pack("<I", 0)                          # starts area (unused)
    fixes += struct.pack("<2I",
                         1 | (0 << 8) | (0 << 9),          # ord 1 libSystem, strong
                         2 | (0 << 8) | (9 << 9))          # ord 2 libc++, strong
    fixes += pool
    datasize = len(fixes)

    # symtab string table
    strtab = b"\0" + b"_syscall\0" + b"__ZTVbad_expected\0" + b"_defined\0"
    s1 = 1
    s2 = 1 + len(b"_syscall\0")
    s3 = s2 + len(b"__ZTVbad_expected\0")

    cmds = [
        _dylib_cmd(LC_LOAD_DYLIB, "/usr/lib/libSystem.B.dylib"),   # ord 1
        _dylib_cmd(LC_LOAD_DYLIB, "/usr/lib/libc++.1.dylib"),       # ord 2
        struct.pack("<6I", LC_BUILD_VERSION, 24, 2,
                    encode_ver((26, 2, 0)), encode_ver((26, 2, 0)), 0),
    ]
    sizeofcmds_pre = sum(len(c) for c in cmds)
    dataoff = 32 + sizeofcmds_pre + 16 + 24     # + fixups cmd + symtab cmd
    symoff = dataoff + datasize
    nsyms = 3
    stroff = symoff + nsyms * NLIST64_SIZE

    cmds.append(struct.pack("<4I", LC_DYLD_CHAINED_FIXUPS | LC_REQ_DYLD,
                            16, dataoff, datasize))
    cmds.append(struct.pack("<6I", LC_SYMTAB, 24, symoff, nsyms, stroff, len(strtab)))

    nlists = [
        (s1, N_UNDF | N_EXT, 0, 1 << 8, 0),       # ord 1, 非 libc++
        (s2, N_UNDF | N_EXT, 0, 2 << 8, 0),       # ord 2, libc++, 强
        (s3, 0x0F, 1, 0, 0x1000),                 # defined
    ]
    symtab_bytes = b"".join(struct.pack("<IBBHQ", *n) for n in nlists)
    header = struct.pack("<8I", MH_MAGIC_64, ABI64 | 0x0100000C, 0, 6,
                         len(cmds), sum(len(c) for c in cmds), 0x85, 0)
    blob = bytearray(header + b"".join(cmds) + fixes + symtab_bytes + strtab)
    assert len(blob) == stroff + len(strtab), (len(blob), stroff + len(strtab))
    # LC_BUILD_VERSION 是第 3 条 load command，minos 在命令起点 +12
    minos_off = 32 + len(cmds[0]) + len(cmds[1]) + 12
    return bytes(blob), dict(symoff=symoff, import_table=dataoff + 32,
                             minos_off=minos_off)


def self_test():
    data, pos = _build_synthetic()
    st, out, _ = process(data, modify=True, fix_minos=True)
    assert st["libcxx_imports"] == 1, st
    assert st["fixup_strong"] == 1 and st["fixup_newly_weak"] == 1, st
    assert st["symtab_libcxx"] == 1 and st["symtab_newly_weak"] == 1, st
    assert st["minos_fixed"] == 1, st
    assert st["verify_fixup_strong"] == 0 and st["verify_symtab_strong"] == 0, st
    assert st["verify_minos_over"] == 0, st

    # fixup import table：ord2 的 weak 位=1，ord1 保持 0
    i1 = struct.unpack_from("<I", out, pos["import_table"])[0]
    i2 = struct.unpack_from("<I", out, pos["import_table"] + 4)[0]
    assert (i1 >> 8) & 1 == 0, "libSystem import must stay strong"
    assert (i2 >> 8) & 1 == 1, "libc++ import MUST be weak in fixup table"
    assert (i2 & 0xFF) == 2, "library ordinal must be preserved"

    # symtab n_desc
    d = [struct.unpack_from("<H", out, pos["symoff"] + i * NLIST64_SIZE + 6)[0]
         for i in range(3)]
    assert d[0] == 1 << 8 and d[0] & N_WEAK_REF == 0, "non-libc++ undefined untouched"
    assert d[1] == (2 << 8) | N_WEAK_REF, "libc++ undefined must be weak"
    assert d[2] == 0, "defined symbol untouched"

    # minos
    mv = decode_ver(struct.unpack_from("<I", out, pos["minos_off"])[0])
    assert mv == TARGET_MINOS, mv

    # 幂等
    st2, out2, _ = process(out, modify=True, fix_minos=True)
    assert out2 == out, "second pass must not change any byte"
    assert st2["fixup_newly_weak"] == 0 and st2["symtab_newly_weak"] == 0

    # 只读校验通过
    st3, _, _ = process(out, modify=False, fix_minos=True)
    assert st3["fixup_strong"] == 0 and st3["symtab_strong"] == 0
    assert not st3["minos_over"]

    print("[ios15/SELF-TEST] OK "
          "(chained-fixup weak bit + symtab N_WEAK_REF + minos, ordinal preserved, "
          "non-libc++/defined untouched, idempotent, verify passes)")
    return True


def main(argv):
    args = argv[1:]
    if "--self-test" in args:
        return 0 if self_test() else 1
    verify = "--verify" in args
    report = "--report" in args
    all_mode = "--all" in args
    paths = [a for a in args if not a.startswith("--")]
    if not paths:
        print(__doc__)
        print("ERROR: no path given", file=sys.stderr)
        return 2
    files = collect(paths, all_mode)
    if not files:
        print("ERROR: no arm64 Mach-O found under %s" % paths, file=sys.stderr)
        return 2
    if not report:
        print("[ios15] scanning %d arm64 Mach-O file(s)" % len(files))
    ok = True
    for p in files:
        try:
            if not process_path(p, verify=verify, report=report):
                ok = False
        except (OSError, ValueError, struct.error) as e:
            print("[ios15] ERROR processing %s: %s" % (p, e), file=sys.stderr)
            ok = False
    print("[ios15] %s: %d file(s), %s" %
          ("VERIFY" if verify else ("REPORT" if report else "WEAKEN"),
           len(files), "PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
