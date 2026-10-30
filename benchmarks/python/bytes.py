import gzip
import hashlib
import os
import struct
import sys
import tempfile


def block() -> bytes:
    items = bytearray(65536)
    x = 12345
    for k in range(65536):
        x = (x * 1103515245 + 12345) % 2147483648
        items[k] = (x // 65536) % 256
    return bytes(items)


def zlib_round_trip(data: bytes) -> int:
    part = 524288
    same = 0
    for at in range(0, len(data), part):
        piece = data[at:at + part]
        if gzip.decompress(gzip.compress(piece, 6)) == piece:
            same += 1
    return same


def binary_sum(data: bytes, size: int) -> int:
    total = 0
    for at in range(0, size, 4):
        total = (total + struct.unpack_from("<I", data, at)[0]) % 1000000007
    return total


def file_round_trip(data: bytes, path: str) -> str:
    chunk = 1048576
    with open(path, "wb") as out:
        for at in range(0, len(data), chunk):
            out.write(data[at:at + chunk])
    parts = []
    with open(path, "rb") as source:
        while piece := source.read(chunk):
            parts.append(piece)
    os.remove(path)
    return hashlib.sha256(b"".join(parts)).hexdigest()


def main(scale: int) -> None:
    mib = 4 * scale
    data = block() * (16 * mib)
    digest = hashlib.sha256(data).hexdigest()
    same = zlib_round_trip(data)
    total = binary_sum(data, 1048576 * scale)
    path = os.path.join(os.environ.get("TMPDIR", tempfile.gettempdir()), f"agentica-bench-bytes-{os.getpid()}.bin")
    read_back = file_round_trip(data, path)
    print(f"bytes {mib}: checksum {digest[:16]} {same} {total} {str(read_back == digest).lower()}")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 1)
