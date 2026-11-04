"""Prints a macOS process's exact argv, each word followed by a NUL.

`ps` joins argv with spaces, which loses where one word ends and the next
begins; the kernel's KERN_PROCARGS2 keeps them apart. Its layout: argc as
an int, the executable's path, NUL padding, then argc NUL-terminated
words (and the environment after them, never read here). Exits 1 when the
process cannot be read (gone, or another user's).

Usage: python3 -I proc-argv.py <pid>
"""
import ctypes
import ctypes.util
import struct
import sys

CTL_KERN, KERN_ARGMAX, KERN_PROCARGS2 = 1, 8, 49


def sysctl(libc, mib, size):
    names = (ctypes.c_int * len(mib))(*mib)
    buf = ctypes.create_string_buffer(size)
    length = ctypes.c_size_t(size)
    if libc.sysctl(names, len(mib), buf, ctypes.byref(length), None, 0) != 0:
        raise OSError(ctypes.get_errno(), "sysctl failed")
    return buf.raw[: length.value]


def main():
    try:
        pid = int(sys.argv[1])
        libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
        argmax = struct.unpack("i", sysctl(libc, [CTL_KERN, KERN_ARGMAX], 4))[0]
        raw = sysctl(libc, [CTL_KERN, KERN_PROCARGS2, pid], argmax)
        argc = struct.unpack("i", raw[:4])[0]
        rest = raw[4:]
        pos = rest.index(b"\0")
        while pos < len(rest) and rest[pos] == 0:
            pos += 1
        words = rest[pos:].split(b"\0")[:argc]
        if len(words) != argc:
            raise ValueError("argv cut short")
    except (IndexError, ValueError, OSError, struct.error) as err:
        print(f"proc-argv: {err}", file=sys.stderr)
        return 1
    sys.stdout.buffer.write(b"".join(w + b"\0" for w in words))
    return 0


if __name__ == "__main__":
    sys.exit(main())
