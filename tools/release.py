#!/usr/bin/env python3
"""Package, smoke-test and collect the release archives (release.yml; `make release-package`, `make release-smoke`).

    release.py package --platform P --binary FILE --out DIR   write DIR/agentica-VERSION-P.(tar.gz|zip)
    release.py smoke ARCHIVE --platform P [--binary FILE]     extract and use the package away from the checkout
    release.py collect --in DIR --out DIR                     check the four archives, copy them, write SHA256SUMS
    release.py name --platform P                              print the archive name

The four archive names are fixed here: the workflow, the checksums and the documentation use the same four. Python's
standard library only. Run `smoke` and `collect` as `python -I tools/release.py ...`.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import os
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import zipfile
from pathlib import Path
from typing import NoReturn

ROOT = Path(__file__).resolve().parents[1]

# platform -> (archive extension, executable name). Four packages, no more: collect fails on anything else.
PLATFORMS = {
    "linux-x86_64": ("tar.gz", "agentica"),
    "windows-x86_64": ("zip", "agentica.exe"),
    "macos-x86_64": ("tar.gz", "agentica"),
    "macos-arm64": ("tar.gz", "agentica"),
}

# Every binary is static in these libraries, so every archive ships the same licenses.
LICENSE_FILES = (
    "licenses/bdwgc/NOTICE", "licenses/libuv/LICENSE", "licenses/libuv/LICENSE-extra", "licenses/yyjson/LICENSE",
    "licenses/picohttpparser/LICENSE", "licenses/openssl/LICENSE.txt", "licenses/unicode/LICENSE.txt",
)
DEFAULT_MTIME = 315619200  # 1980-01-02, the first date a zip can hold

# The folders of the smoke test: spaces and non-ASCII letters, like a real user's.
UNICODE_NAME = "ñandú ✓"


def fail(message: str) -> NoReturn:
    print(f"release.py: {message}", file=sys.stderr)
    raise SystemExit(1)


def version() -> str:
    return (ROOT / "VERSION").read_text(encoding="utf-8").strip()


def package_name(platform: str, ver: str | None = None) -> str:
    return f"agentica-{ver or version()}-{platform}"


def archive_name(platform: str, ver: str | None = None) -> str:
    return f"{package_name(platform, ver)}.{PLATFORMS[platform][0]}"


def expected_members(platform: str) -> list[str]:
    """The files of an archive, as paths below its top folder."""
    return sorted(["LICENSE", "NOTICE", f"bin/{PLATFORMS[platform][1]}", *LICENSE_FILES])


def license_text(name: str) -> bytes:
    """The license of a vendored library, cut from the file that holds it."""
    third = ROOT / "vm" / "third_party"
    if name == "licenses/bdwgc/NOTICE":  # the notice at the top of README.QUICK, up to the line about the GPL
        lines = (third / "bdwgc" / "README.QUICK").read_bytes().splitlines(keepends=True)
        end = next(i for i, line in enumerate(lines) if b"covered by the GPL." in line)
        return b"".join(lines[: end + 1])
    if name == "licenses/picohttpparser/LICENSE":  # the comment at the top of the header
        lines = (third / "picohttpparser" / "picohttpparser.h").read_bytes().splitlines(keepends=True)
        end = next(i for i, line in enumerate(lines) if line.startswith(b" */"))
        return b"".join(lines[: end + 1])
    sources = {
        "licenses/libuv/LICENSE": third / "libuv" / "LICENSE",
        "licenses/libuv/LICENSE-extra": third / "libuv" / "LICENSE-extra",
        "licenses/yyjson/LICENSE": third / "yyjson" / "LICENSE",
        "licenses/openssl/LICENSE.txt": third / "openssl" / "LICENSE.txt",
        "licenses/unicode/LICENSE.txt": ROOT / "licenses" / "unicode" / "LICENSE.txt",
    }
    return sources[name].read_bytes()


def source_date() -> int:
    """SOURCE_DATE_EPOCH, else the commit time, so the same commit packs to the same bytes."""
    if os.environ.get("SOURCE_DATE_EPOCH"):
        return int(os.environ["SOURCE_DATE_EPOCH"])
    try:
        out = subprocess.run(["git", "-C", str(ROOT), "log", "-1", "--format=%ct"], capture_output=True, text=True,
                             check=True).stdout.strip()
        return max(int(out), DEFAULT_MTIME)
    except (OSError, ValueError, subprocess.CalledProcessError):
        return DEFAULT_MTIME


def list_archive(path: Path) -> list[tuple[str, str]]:
    """(name, kind) of every member, in archive order; kind is "file", "dir" or "other" (a link or a device)."""
    if path.name.endswith(".zip"):
        with zipfile.ZipFile(path) as z:
            kinds = []
            for i in z.infolist():
                mode = i.external_attr >> 16
                special = mode != 0 and not (stat.S_ISREG(mode) or stat.S_ISDIR(mode))
                kinds.append("other" if special else "dir" if i.is_dir() else "file")
            return [(i.filename.rstrip("/"), kind) for i, kind in zip(z.infolist(), kinds)]
    with tarfile.open(path, "r:gz") as t:
        return [(m.name, "file" if m.isreg() else "dir" if m.isdir() else "other") for m in t.getmembers()]


def verify_archive(path: Path, platform: str, ver: str | None = None) -> None:
    """Fail unless the archive holds exactly the expected files, once each, below one folder."""
    top = package_name(platform, ver)
    entries = list_archive(path)
    names = [name for name, _ in entries]
    odd = sorted(name for name, kind in entries if kind == "other")
    if odd:  # a link or a device could point out of the folder it is extracted into
        fail(f"{path.name} has members that are neither files nor folders: {odd}")
    duplicates = sorted({n for n in names if names.count(n) > 1})
    if duplicates:
        fail(f"{path.name} has duplicate members: {duplicates}")
    for name in names:
        parts = name.split("/")
        if name.startswith("/") or ".." in parts or "\\" in name or parts[0] != top:
            fail(f"{path.name} has the member {name!r} outside {top}/")
    files = sorted(name[len(top) + 1:] for name, kind in entries if kind == "file")
    expected = expected_members(platform)
    if files != expected:
        fail(f"{path.name} holds the wrong files: missing {sorted(set(expected) - set(files))}, "
             f"unexpected {sorted(set(files) - set(expected))}")
    bin_files = [f for f in files if f.startswith("bin/")]
    if len(bin_files) != 1:  # one program: nothing else in bin/
        fail(f"{path.name} has more than the program in bin/: {bin_files}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def package(platform: str, binary: Path, out: Path) -> Path:
    """Write the archive of one platform from its built binary; return its path."""
    ver, top, mtime = version(), package_name(platform), source_date()
    if not binary.is_file():
        fail(f"no binary at {binary}")
    out.mkdir(parents=True, exist_ok=True)
    members: list[tuple[str, bytes, int]] = [  # (path in the archive, content, mode)
        (f"{top}/LICENSE", (ROOT / "LICENSE").read_bytes(), 0o644),
        (f"{top}/NOTICE", (ROOT / "NOTICE").read_bytes(), 0o644),
        (f"{top}/bin/{PLATFORMS[platform][1]}", binary.read_bytes(), 0o755),
        *[(f"{top}/{name}", license_text(name), 0o644) for name in LICENSE_FILES],
    ]
    members.sort()
    target = out / archive_name(platform, ver)
    if target.suffix == ".zip":
        with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as z:
            for name, data, mode in members:
                info = zipfile.ZipInfo(name, date_time=time.gmtime(mtime)[:6])
                info.external_attr = (stat.S_IFREG | mode) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                z.writestr(info, data)
    else:
        with target.open("wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=mtime) as gz:
            with tarfile.open(fileobj=gz, mode="w", format=tarfile.PAX_FORMAT) as t:
                for name, data, mode in members:
                    info = tarfile.TarInfo(name)
                    info.size, info.mode, info.mtime = len(data), mode, mtime
                    info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    t.addfile(info, io.BytesIO(data))
    verify_archive(target, platform, ver)
    print(f"{target} {sha256(target)}")
    return target


# ---------------------------------------------------------------------------------------------------------------
# smoke: the extracted package, away from the checkout and the build environment

# std/http is left out on purpose: it needs the TCP builtins, so network_smoke imports it where the binary has them.
HELLO = 'def main() -> Void\n  puts("hola, mundo ✓ ñandú")\nend\n'
BAD = 'def main() -> Void\n  count = 1\n  count = "two"\n  puts(count)\nend\n'
STD = """\
import Queue from "std/queue"
import Binary from "std/binary"
import Toml from "std/toml"
import Logger from "std/logger"
import BDD from "std/bdd"

def main() -> Void
  q = Queue.push(Queue.new(), "embedded")
  puts(Result.unwrap!(Queue.peek(q)))
end
"""
UNIT = """\
def main() -> Void
  Test.run([
    Test.test("adds") do
      Test.eq(1 + 2, 3)
    end,
    Test.test("counts characters") do
      Test.eq(String.length("ñandú"), 5)
    end
  ])
end
"""
UNIT_FAILING = UNIT.replace("Test.eq(1 + 2, 3)", "Test.eq(1 + 2, 4)")
FEATURE = """\
Feature: Package smoke

  Scenario: A program greets
    Given the Agentica program "../hola.agc"
    Then I receive the line "hola, mundo ✓ ñandú" within 20000 milliseconds
    And the program exits with code 0 within 20000 milliseconds

  Scenario: A custom step
    When I remember 7
    Then the remembered number is 7
"""
STEPS = """\
import BDD from "std/bdd"

def remember(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.set(ctx, "number", JSON.from(String.to_int!(args[0])))
end

def expect(ctx: BDD.Context, args: List[String]) -> BDD.Context
  actual = Result.unwrap!(JSON.int(Result.unwrap!(BDD.get(ctx, "number"))))
  return BDD.assert(ctx, actual == String.to_int!(args[0]), "wrong number")
end

def main() -> Void
  BDD.run([BDD.step("I remember {int}", &remember), BDD.step("the remembered number is {int}", &expect)])
end
"""
FILES = """\
def main() -> Void
  base = System.args()[0]
  dir = Result.unwrap!(Path.join([base, "datos ñandú", "sub dir"]))
  Result.unwrap!(Dir.mkdir(dir, 5000))
  file = Result.unwrap!(Path.join([dir, "nota ✓.txt"]))
  Result.unwrap!(File.write_text(file, "uno\\n", 5000))
  Result.unwrap!(File.append_text(file, "dos ñ\\n", 5000))
  puts(Result.unwrap!(File.read_text(file, 5000)))
  moved = Result.unwrap!(Path.join([dir, "movida ✓.txt"]))
  Result.unwrap!(Path.rename(file, moved, 5000))
  for name in Result.unwrap!(Dir.list(dir, 5000))
    puts(name)
  end
  puts(Result.unwrap!(File.stat(moved, 5000)).size_bytes)
  Result.unwrap!(Path.remove(moved, 5000))
  puts(List.size(Result.unwrap!(Dir.list(dir, 5000))))
end
"""
PROCESS = """\
def main() -> Void
  p = Result.unwrap!(Process.spawn(System.args()[0], ["--version"], 10000))
  Result.unwrap!(Process.close_stdin(p, 10000))
  puts(Result.unwrap!(Process.read_line(p, 10000)))
  puts(Result.unwrap!(Process.wait(p, 10000)))
  Process.close(p)
end
"""
TCP = """\
def serve(listener: Listener) -> Result[Void]
  socket = try TCP.accept(listener, 10000)
  line = try TCP.read_line(socket, 10000)
  try TCP.send(socket, "echo " + line + "\\n", 10000)
  TCP.close(socket)
  return ok()
end

def main() -> Void
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  server = Task.spawn(&serve, listener)
  client = Result.unwrap!(TCP.connect("127.0.0.1", TCP.local_port(listener), 10000))
  Result.unwrap!(TCP.send(client, "ñandú\\n", 10000))
  puts(Result.unwrap!(TCP.read_line(client, 10000)))
  TCP.close(client)
  Result.unwrap!(Task.await(server))
  TCP.close_listener(listener)
end
"""
HTTP_LOOP = """\
import HTTP from "std/http"

def handle(request: HttpRequest) -> Result[HttpResponse]
  if request.method == "GET" and request.path == "/"
    return ok(HttpResponse(status: 200, headers: [], body: "hola ñandú"))
  end
  return ok(HttpResponse(status: 404, headers: [], body: "no"))
end

def main() -> Void
  server = HTTP.listen("127.0.0.1", 0, &handle, HTTP.server_options()).unwrap!
  client = HTTP.client(HTTP.client_options()).unwrap!
  base = "http://127.0.0.1:#{HTTP.local_port(server)}"
  response = HTTP.get(client, base + "/").unwrap!
  puts("#{response.status} #{response.body}")
  puts(HTTP.get(client, base + "/missing").unwrap!.status)
  HTTP.close_client(client)
  HTTP.close_server(server)
end
"""
# What the VM prints when bytecode names a builtin this build lacks (loader.c, "invalid bytecode: unknown builtin"):
# the way a binary says that a feature, TCP on Windows today, is not built in.
NO_BUILTIN = "unknown builtin"


class Smoke:
    """Runs the extracted binary with a controlled environment and counts what it checked."""

    def __init__(self, exe: Path, cwd: Path, home: Path) -> None:
        self.exe, self.cwd, self.checks = exe, cwd, 0
        if os.name == "nt":
            root = os.environ["SystemRoot"]
            # Neither MSYS2 nor a compiler: only the folders every Windows has, so a missing DLL shows.
            self.env = {"PATH": os.pathsep.join([root + "\\System32", root]), "SystemRoot": root,
                        "TEMP": str(home), "TMP": str(home), "USERPROFILE": str(home)}
        else:
            self.env = {"PATH": "/usr/bin:/bin", "HOME": str(home), "TMPDIR": str(home), "LANG": "C.UTF-8"}

    def run(self, *args: str, code: int | None = 0, timeout: int = 180) -> subprocess.CompletedProcess:
        try:
            proc = subprocess.run([str(self.exe), *args], cwd=self.cwd, env=self.env, capture_output=True, input="",
                                  text=True, encoding="utf-8", timeout=timeout)
        except subprocess.TimeoutExpired as error:
            fail(f"agentica {' '.join(args)}: no exit in {timeout} s\n"
                 f"stdout: {error.stdout or ''}\nstderr: {error.stderr or ''}")
        if code is not None and proc.returncode != code:
            fail(f"agentica {' '.join(args)}: exit {proc.returncode}, expected {code}\n"
                 f"stdout: {proc.stdout}\nstderr: {proc.stderr}")
        return proc

    def expect(self, what: str, condition: bool, proc: subprocess.CompletedProcess | None = None) -> None:
        self.checks += 1
        if not condition:
            detail = f"\nstdout: {proc.stdout}\nstderr: {proc.stderr}" if proc is not None else ""
            fail(f"smoke check failed: {what}{detail}")
        print(f"ok: {what}")


def extract(archive: Path, dest: Path) -> None:
    if archive.name.endswith(".zip"):
        with zipfile.ZipFile(archive) as z:
            z.extractall(dest)
    else:
        with tarfile.open(archive, "r:gz") as t:
            t.extractall(dest, filter="data")


def network_smoke(s: Smoke, work: Path, platform: str) -> None:
    """Loopback TCP and HTTP, on the platforms whose binary has them.

    A binary says what it has: when its bytecode names a builtin the build lacks, the loader rejects it with
    "unknown builtin". Linux and macOS must have TCP, so for them that message is a failure, not a skip; any other
    failure is one everywhere. The Windows port of TCP is in progress: once it lands, the same test turns on there.
    """
    (work / "tcp.agc").write_text(TCP, encoding="utf-8")
    proc = s.run("tcp.agc", code=None)
    if proc.returncode != 0 and NO_BUILTIN in proc.stderr and not platform.startswith(("linux", "macos")):
        note = f"networking skipped: this binary has no TCP builtins ({platform}): {proc.stderr.strip()}"
        print(f"::notice title=Release smoke::{note}" if os.environ.get("GITHUB_ACTIONS") else f"skip: {note}")
        return
    s.expect("TCP loopback echo", proc.returncode == 0 and proc.stdout == "echo ñandú\n", proc)
    (work / "http.agc").write_text(HTTP_LOOP, encoding="utf-8")
    proc = s.run("http.agc")
    s.expect("HTTP loopback client and server", proc.stdout == "200 hola ñandú\n404\n", proc)


def smoke(archive: Path, platform: str, binary: Path | None) -> None:
    """Extract the archive into a folder with spaces and non-ASCII letters, away from the checkout, and run the
    packaged binary there with a controlled PATH."""
    ver = version()
    verify_archive(archive, platform, ver)
    base = Path(tempfile.mkdtemp(prefix="agentica smoke ")).resolve()
    if base == ROOT or ROOT in base.parents or base in ROOT.parents:
        fail(f"{base} is inside the checkout")
    try:
        install = base / f"install {UNICODE_NAME}"
        install.mkdir()
        extract(archive, install)
        exe = install / package_name(platform, ver) / "bin" / PLATFORMS[platform][1]
        work = base / f"trabajo {UNICODE_NAME}"
        work.mkdir()
        s = Smoke(exe, work, base)
        if binary is not None:
            s.expect("the packaged binary is the checked binary", sha256(exe) == sha256(binary))

        out = s.run("--version")
        s.expect(f"--version is {ver}", out.stdout == ver + "\n", out)
        out = s.run("run", "--version")
        s.expect("run --version names the VM and its libraries",
                 out.stdout.startswith(f"agentica {ver} (libgc ") and "libuv" in out.stdout, out)
        out = s.run("--help")
        s.expect("--help lists the commands", "agentica check" in out.stdout and "agentica test" in out.stdout, out)
        out = s.run("help", "String.split")
        s.expect("help NAME describes a builtin", "String.split" in out.stdout, out)

        (work / "hola mundo ✓.agc").write_text(HELLO, encoding="utf-8")
        (work / "bad.agc").write_text(BAD, encoding="utf-8")
        out = s.run("check", "hola mundo ✓.agc")
        s.expect("check ok", out.stdout.strip() == "check ok", out)
        out = s.run("--json", "check", "bad.agc", code=1)
        s.expect("check reports CHECK-TYPE-MISMATCH", "CHECK-TYPE-MISMATCH" in out.stdout + out.stderr, out)
        out = s.run("hola mundo ✓.agc")
        s.expect("run prints non-ASCII text", out.stdout == "hola, mundo ✓ ñandú\n", out)
        s.run("compile", "hola mundo ✓.agc", "-o", "hola ✓.agcb")
        out = s.run("run", "--", "hola ✓.agcb")
        s.expect("compile, then run the bytecode", out.stdout == "hola, mundo ✓ ñandú\n", out)
        seeds = [s.run("--seed", "7", "hola mundo ✓.agc").stdout for _ in range(2)]
        s.expect("--seed is repeatable", seeds[0] == seeds[1])

        (work / "std.agc").write_text(STD, encoding="utf-8")
        out = s.run("std.agc")
        s.expect("std/ modules import from the binary", out.stdout == "embedded\n", out)

        units = work / "pruebas ñ"
        units.mkdir()
        (units / "suma_test.agc").write_text(UNIT, encoding="utf-8")
        out = s.run("test", str(units))
        s.expect("agentica test runs unit tests", "PASS" in out.stdout and "FAIL" not in out.stdout, out)
        failing = work / "fallan"
        failing.mkdir()
        (failing / "suma_test.agc").write_text(UNIT_FAILING, encoding="utf-8")
        out = s.run("test", str(failing), code=1)
        s.expect("a failing unit test exits 1", "FAIL" in out.stdout, out)

        (work / "hola.agc").write_text(HELLO, encoding="utf-8")
        specs = work / "especificaciones ñ"
        specs.mkdir()
        (specs / "paquete.feature").write_text(FEATURE, encoding="utf-8")
        (work / "pasos ñ.agc").write_text(STEPS, encoding="utf-8")
        out = s.run("test", str(specs), "--steps", "pasos ñ.agc")
        s.expect("agentica test runs BDD specs", "FAIL" not in out.stdout and "PASS" in out.stdout, out)

        (work / "files.agc").write_text(FILES, encoding="utf-8")
        out = s.run("files.agc", str(work))
        s.expect("files: write, append, read, rename, list, stat, remove",
                 out.stdout == "uno\ndos ñ\n\nmovida ✓.txt\n11\n0\n", out)

        (work / "process.agc").write_text(PROCESS, encoding="utf-8")
        out = s.run("--allow-run", "process.agc", str(exe))
        s.expect("processes: spawn the packaged binary", out.stdout == f"{ver}\n0\n", out)
        out = s.run("process.agc", str(exe), code=None)
        s.expect("processes need --allow-run", out.returncode != 0, out)

        network_smoke(s, work, platform)
        print(f"smoke passed: {s.checks} checks on {archive.name}")
    finally:
        shutil.rmtree(base, ignore_errors=True)


# ---------------------------------------------------------------------------------------------------------------
# collect: the four archives, exactly once each

def collect(source: Path, out: Path) -> None:
    """Check that `source` (searched recursively) holds the four archives of this version once each, copy them to
    `out` and write SHA256SUMS there."""
    ver = version()
    wanted = {archive_name(p, ver): p for p in PLATFORMS}
    found: dict[str, list[Path]] = {}
    for path in sorted(p for p in source.rglob("*") if p.is_file()):
        found.setdefault(path.name, []).append(path)
    missing = sorted(set(wanted) - set(found))
    extra = sorted(set(found) - set(wanted))
    repeated = sorted(f"{n}: {[str(p) for p in ps]}" for n, ps in found.items() if len(ps) > 1)
    if missing or extra or repeated:
        fail(f"the archives for {ver} are wrong: missing {missing}, unexpected {extra}, duplicated {repeated}")
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    lines = []
    for name in sorted(wanted):
        verify_archive(found[name][0], wanted[name], ver)
        shutil.copyfile(found[name][0], out / name)
        lines.append(f"{sha256(out / name)}  {name}")
    (out / "SHA256SUMS").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("package")
    p.add_argument("--platform", required=True, choices=sorted(PLATFORMS))
    p.add_argument("--binary", required=True, type=Path)
    p.add_argument("--out", required=True, type=Path)
    p = sub.add_parser("smoke")
    p.add_argument("archive", type=Path)
    p.add_argument("--platform", required=True, choices=sorted(PLATFORMS))
    p.add_argument("--binary", type=Path)
    p = sub.add_parser("collect")
    p.add_argument("--in", dest="source", required=True, type=Path)
    p.add_argument("--out", required=True, type=Path)
    p = sub.add_parser("name")
    p.add_argument("--platform", required=True, choices=sorted(PLATFORMS))
    args = parser.parse_args()
    if args.command == "package":
        package(args.platform, args.binary, args.out)
    elif args.command == "smoke":
        smoke(args.archive.resolve(), args.platform, args.binary)
    elif args.command == "collect":
        collect(args.source, args.out)
    else:
        print(archive_name(args.platform))


if __name__ == "__main__":
    main()
