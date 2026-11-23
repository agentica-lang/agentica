"""File.seek against Python's os.lseek on the same file, and the handle kinds that cannot seek.

The peer program takes the file and a list of steps (`seek:N`, `read:N`, `line`) and prints one line per step. The
Python side runs the same steps with os.lseek and os.read. `line` fills the handle's read buffer (64 KiB), so a seek
after it shows that the buffer is dropped.
"""
import os
import random
import sys

import pytest

from tests.agentica_test import cli, compile_agc, run, run_vm

PEER = """def main() -> Void
  args = System.args()
  file = File.open(args[0]).unwrap!
  for step in args.drop(1)
    parts = step.split(":")
    case parts[0]
      "seek" -> puts(File.seek(file, parts[1].to_i!).ok?)
      "read" -> puts(OpenSSL.Digest.hexencode(File.read_bytes(file, parts[1].to_i!).unwrap!))
      _ ->
        case File.read_line(file)
          ok(line) -> puts(OpenSSL.Digest.hexencode(line.bytes))
          error(_) -> puts("eof")
        end
    end
  end
  _ = File.close(file)
end
"""


def text_lines(size):
    rng = random.Random(1927)
    out = bytearray()
    while len(out) < size:
        out += bytes(rng.choice(b"abcdefghijklmnopqrstuvwxyz0123456789 ") for _ in range(rng.randint(0, 120)))
        out += b"\n"
    return bytes(out[:size])


DATA = text_lines(150_000)
SIZE = len(DATA)

STEPS = [
    "read:10",
    "seek:0", "read:16",
    "seek:75000", "read:100",
    "line", "seek:1000", "read:50",
    "line", "seek:4090", "read:20",
    "seek:65530", "read:20",
    "line", "seek:65533", "line", "line",
    f"seek:{SIZE // 2}", "line", f"seek:{SIZE // 3}", "read:70000",
    f"seek:{SIZE}", "read:10", "line",
    f"seek:{SIZE + 5000}", "read:10", "line",
    "seek:5", "read:1048576",
]


def read_exactly(fd, count):
    out = b""
    while len(out) < count:
        got = os.read(fd, count - len(out))
        if not got:
            break
        out += got
    return out


def python_steps(path, steps):
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_BINARY", 0))
    lines = []
    try:
        for step in steps:
            kind, _, arg = step.partition(":")
            if kind == "seek":
                os.lseek(fd, int(arg), os.SEEK_SET)
                lines.append("true")
            elif kind == "read":
                lines.append(read_exactly(fd, int(arg)).hex())
            else:
                start = os.lseek(fd, 0, os.SEEK_CUR)
                rest = read_exactly(fd, 1 << 20)
                if not rest:
                    lines.append("eof")
                    continue
                end = rest.find(b"\n")
                line = rest if end < 0 else rest[:end]
                os.lseek(fd, start + len(line) + (0 if end < 0 else 1), os.SEEK_SET)
                lines.append(line.rstrip(b"\r").hex())
    finally:
        os.close(fd)
    return lines


@pytest.fixture(scope="module")
def peer(tmp_path_factory):
    source = tmp_path_factory.mktemp("file-seek") / "peer.agc"
    source.write_text(PEER, encoding="utf-8")
    return compile_agc(source, source.with_suffix(".agcb"))


def test_seek_matches_os_lseek(peer, tmp_path):
    path = tmp_path / "data.txt"
    path.write_bytes(DATA)
    result = run_vm(peer, args=[str(path), *STEPS])
    assert result.code == 0, result.stderr
    assert result.stdout.splitlines() == python_steps(path, STEPS)


def run_program(tmp_path, body, *args):
    path = tmp_path / "seek.agc"
    path.write_text("def main() -> Void\n" + body + "end\n", encoding="utf-8")
    return run(cli() + [str(path), *args])


def test_a_write_handle_cannot_seek(tmp_path):
    body = '  file = File.open(System.args()[0], "write").unwrap!\n  puts(File.seek(file, 0).message)\n'
    result = run_program(tmp_path, body, str(tmp_path / "out.txt"))
    assert result.code == 0, result.stderr
    assert result.stdout == "filesystem: file handle is not open for reading\n"


@pytest.mark.skipif(sys.platform == "win32", reason="host-only: Windows has no FIFO files")
def test_a_fifo_cannot_seek(tmp_path):
    fifo = tmp_path / "pipe"
    os.mkfifo(fifo)
    body = "  file = File.open(System.args()[0]).unwrap!\n  puts(File.seek(file, 0).message)\n"
    result = run_program(tmp_path, body, str(fifo))
    assert result.code == 0, result.stderr
    assert result.stdout == "filesystem: cannot seek a pipe, FIFO or terminal\n"
