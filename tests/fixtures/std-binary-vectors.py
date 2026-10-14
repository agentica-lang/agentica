import importlib.util
import math
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUTPUT = HERE / "vm" / "std-binary-vectors.stdin"
HEADER = (
    "# std-binary-vectors.stdin: made by python3 tests/fixtures/std-binary-vectors.py "
    "(struct.pack and struct.unpack); do not edit by hand"
)
INT_MIN = -(1 << 63)
INT_MAX = (1 << 63) - 1

spec = importlib.util.spec_from_file_location("bits_vectors", HERE / "bits-vectors.py")
bits = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bits)

INTS = [
    ("u8", "B", 8, False),
    ("i8", "b", 8, True),
    ("u16", "H", 16, False),
    ("i16", "h", 16, True),
    ("u32", "I", 32, False),
    ("i32", "i", 32, True),
    ("u64", "Q", 64, False),
    ("i64", "q", 64, True),
]
ORDERS = {"be": ">", "le": "<"}
PATTERNS = [
    0x0102030405060708,
    0x8070605040302010,
    0x00FF00FF00FF00FF,
    0xFF00FF00FF00FF00,
    0x7F,
    0x80,
    0xFF,
    0x100,
    0x7FFF,
    0x8000,
    0xFFFF,
    0x10000,
    0x7FFFFFFF,
    0x80000000,
    0xFFFFFFFF,
    0x100000000,
    0x7FFFFFFFFFFFFFFF,
    0x8000000000000000,
    0xFFFFFFFFFFFFFFFF,
]
PAYLOADS = [[], [0], [255], [1, 2, 3, 4, 5], list(range(256)) + [7] * 44]
LENGTHS = [0, 1, 65535, 65536, 65537, 4294967295]
LIMITS = [0, 100, 65536, 4294967295]
BAD_LIMITS = [-1, -5, INT_MIN + 1]


def text(data: bytes) -> str:
    return ",".join(str(b) for b in data) if data else "-"


def bounds(bits_: int, signed: bool) -> tuple[int, int]:
    if signed:
        return -(1 << (bits_ - 1)), (1 << (bits_ - 1)) - 1
    return 0, (1 << bits_) - 1


def int_values(bits_: int, signed: bool) -> list[int]:
    low, high = bounds(bits_, signed)
    high = min(high, INT_MAX)
    values = [0, 1, low, high, high - 1]
    if signed:
        values += [-1, -2, low + 1]
    for pattern in PATTERNS:
        masked = pattern & ((1 << bits_) - 1)
        if signed and masked >> (bits_ - 1):
            masked -= 1 << bits_
        values.append(masked)
    return sorted({v for v in values if low <= v <= high})


def int_lines() -> list[str]:
    lines = []
    for name, code, bits_, signed in INTS:
        for order, prefix in ORDERS.items():
            for value in int_values(bits_, signed):
                packed = struct.pack(prefix + code, value)
                assert struct.unpack(prefix + code, packed)[0] == value
                lines.append(f"int {name} {order} {value} {text(packed)}")
            low, high = bounds(bits_, signed)
            outside = [] if name == "i64" else [low - 1, high + 1, INT_MIN, INT_MAX, INT_MIN + 1]
            if name == "u64":
                outside = [-1, INT_MIN, INT_MIN + 1]
            for value in sorted({v for v in outside if not low <= v <= high}):
                try:
                    struct.pack(prefix + code, value)
                except struct.error:
                    pass
                else:
                    raise AssertionError((name, value))
                lines.append(f"werr {name} {order} {value}")
    for order, prefix in ORDERS.items():
        for value in [1 << 63, (1 << 63) + 1, (1 << 64) - 1, 0x8000000000000000 | 0x0102030405060708]:
            packed = struct.pack(prefix + "Q", value)
            assert struct.unpack(prefix + "Q", packed)[0] > INT_MAX
            lines.append(f"rerr64 {order} {text(packed)}")
    return lines


def float_lines() -> list[str]:
    lines = []
    for order, prefix in ORDERS.items():
        for x in bits.FLOATS:
            source = bits.encode_float(x)
            wide = bits.f64_bits(x)
            packed = struct.pack(prefix + "q", wide)
            if not math.isnan(x):
                assert struct.pack(prefix + "d", x) == packed
            lines.append(f"fwrite f64 {order} {source} {text(packed)}")
            lines.append(f"fread f64 {order} {text(packed)} {source}")
            narrow = bits.f32_bits(x)
            packed32 = struct.pack(prefix + "I", narrow)
            lines.append(f"fwrite f32 {order} {source} {text(packed32)}")
            lines.append(f"fread f32 {order} {text(packed32)} {bits.encode_float(struct.unpack(prefix + 'f', packed32)[0])}")
        for pattern in bits.BITS64:
            packed = struct.pack(prefix + "q", pattern)
            value = struct.unpack(prefix + "d", packed)[0]
            lines.append(f"fread f64 {order} {text(packed)} {bits.encode_float(value)}")
        for pattern in bits.BITS32:
            packed = struct.pack(prefix + "I", pattern)
            value = struct.unpack(prefix + "f", packed)[0]
            lines.append(f"fread f32 {order} {text(packed)} {bits.encode_float(value)}")
    return lines


def frame_lines() -> list[str]:
    lines = []
    for payload in PAYLOADS:
        data = bytes(payload)
        lines.append(f"frame {text(data)} {text(struct.pack('>I', len(data)) + data)}")
    for length in LENGTHS:
        packed = struct.pack(">I", length)
        for limit in LIMITS:
            result = f"{length}" if length <= limit else f"above:{length}"
            lines.append(f"flen {text(packed)} {limit} {result}")
    for limit in BAD_LIMITS:
        lines.append(f"flen {text(struct.pack('>I', 1))} {limit} neg")
    return lines


def main() -> None:
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else OUTPUT
    lines = [HEADER, *int_lines(), *float_lines(), *frame_lines()]
    with open(target, "w", encoding="ascii", newline="\n") as out:
        out.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
