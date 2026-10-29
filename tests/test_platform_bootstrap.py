"""Native bootstrap contracts, without shells or repository runtime files."""

import json
import os
import re
import shutil
import subprocess

import pytest

from tests.agentica_test import PYTHON, Child, run, scaled, vm_environment
from tests.agentica_test import vm_binary as binary




def test_copied_binary_compiles_and_runs_outside_the_checkout(tmp_path) -> None:
    root = tmp_path
    executable = root / binary().name
    shutil.copy2(binary(), executable)
    project = root / "project with spaces ñ🙂"
    project.mkdir()
    source = project / "main ñ🙂.agc"
    (project / "helper.agc").write_text(
        'export def value() -> String\n  return "relative"\nend\n',
        encoding="utf-8",
    )
    source.write_text(
        'import Helper from "helper"\n'
        'import Queue from "std/queue"\n\n'
        'def main() -> Void\n'
        '  puts(Helper.value())\n'
        '  q = Queue.push(Queue.new(), "stdlib")\n'
        '  puts(Queue.pop(q).unwrap!.value)\n'
        '  for arg in System.args()\n    puts(arg)\n  end\nend\n',
        encoding="utf-8",
    )
    environment = vm_environment()
    if os.name != "nt":
        environment["PATH"] = ""
    command = [executable]
    version = run(command + ["--version"], cwd=root, env=environment)
    assert version.code == 0, version.stderr
    assert re.search(r"^\d+\.\d+\.\d+", version.stdout)
    help_result = run(command + ["--help"], cwd=root, env=environment)
    assert help_result.code == 0, help_result.stderr
    assert "agentica" in help_result.stdout
    checked = run(command + ["check", source], cwd=root, env=environment)
    assert checked.code == 0, checked.stderr
    arguments = ["space value", '"quoted"', "", "ñ🙂"]
    expected = "relative\nstdlib\n" + "\n".join(arguments) + "\n"
    direct = run(command + [source, *arguments], cwd=root, env=environment)
    assert (direct.code, direct.stdout) == (0, expected), direct.stderr
    bytecode = root / "compiled ñ🙂.agcb"
    compiled = run(
        command + ["compile", source, "-o", bytecode], cwd=root, env=environment
    )
    assert compiled.code == 0, compiled.stderr
    loaded = run(
        command + ["run", "--", bytecode, *arguments], cwd=root, env=environment
    )
    assert (loaded.code, loaded.stdout) == (0, expected), loaded.stderr
    previous = bytecode.read_bytes()
    refused = run(
        command + ["run", "--driver-pid", str(os.getpid() + 1), "--", bytecode],
        cwd=root, env=environment,
    )
    assert refused.code == 2, refused.stderr
    assert bytecode.read_bytes() == previous
    source.write_text(
        'def main() -> Void\n  value: Int = "wrong"\n  puts(value)\nend\n',
        encoding="utf-8",
    )
    invalid = run(command + ["--json", "check", source], cwd=root, env=environment)
    assert invalid.code == 1, invalid.stderr
    assert json.loads(invalid.stderr)["code"] == "CHECK-TYPE-MISMATCH"


def test_file_limits_preserve_existing_data_and_flush_on_close(tmp_path) -> None:
    root = tmp_path
    source = root / "limits.agc"
    source.write_text(
        'def main() -> Void\n'
        '  path = System.args()[0]\n'
        '  mib = (1..17).to_a.reduce("abcdefgh") do |text, _n|\n'
        '    text + text\n  end\n'
        '  File.write_text(path, "sentinel", 5000).unwrap!\n'
        '  puts(File.write_text(path, mib + "x", 5000).ok?)\n'
        '  puts(File.read_text(path, 5000).unwrap!)\n'
        '  File.write_text(path, mib, 5000).unwrap!\n'
        '  puts(File.read_text(path, 5000).unwrap!.length)\n'
        '  file = File.open(path, "append", 5000).unwrap!\n'
        '  File.write(file, "x", 5000).unwrap!\n'
        '  File.close(file, 5000).unwrap!\n'
        '  puts(File.read_text(path, 5000).ok?)\nend\n',
        encoding="utf-8",
    )
    output = root / "data ñ🙂.txt"
    result = run([binary(), source, output], cwd=root, env=vm_environment())
    assert (result.code, result.stdout) == (0, "false\nsentinel\n1048576\nfalse\n"), result.stderr
    assert output.read_bytes() == b"abcdefgh" * (1 << 17) + b"x"


def test_standard_input_uses_a_pipe(tmp_path) -> None:
    root = tmp_path
    source = root / "stdin.agc"
    source.write_text(
        'def main() -> Void\n'
        '  puts(IO.gets())\n'
        'end\n',
        encoding="utf-8",
    )
    result = run([binary(), source], cwd=root, env=vm_environment(), stdin=b"from pipe\n")
    assert (result.code, result.stdout) == (0, 'ok("from pipe")\n'), result.stderr


def test_standard_input_preserves_binary_bytes(tmp_path) -> None:
    root = tmp_path
    source = root / "stdin.agc"
    source.write_text(
        'def main() -> Void\n'
        '  puts(IO.read_bytes(5).unwrap!.to_a)\n'
        'end\n',
        encoding="utf-8",
    )
    result = run(
        [binary(), source], cwd=root, env=vm_environment(),
        stdin=b"\x00\r\n\x1a\xff",
    )
    assert (result.code, result.stdout) == (0, "[0, 13, 10, 26, 255]\n"), result.stderr


def test_pending_standard_input_does_not_block_timers_or_exit(tmp_path, adopt) -> None:
    root = tmp_path
    source = root / "stdin.agc"
    source.write_text(
        'def read_input(_arg: Int) -> Result[String]\n'
        '  return IO.gets()\n'
        'end\n\n'
        'def main() -> Void\n'
        '  reader = Task.spawn(&read_input, 0)\n'
        f'  case Task.await(reader, {scaled(100)})\n'
        '    Await.TimedOut -> puts("pending")\n'
        '    Await.Done(_) -> puts("unexpected input")\n'
        '  end\n'
        'end\n',
        encoding="utf-8",
    )
    child = adopt(Child(
        [binary(), source], cwd=root, env=vm_environment(),
        stdin=True, capture_stderr=True,
    ))
    try:
        # Keep the pipe open and empty even while waiting for process exit.
        assert child.next_line() == "pending"
        assert child.wait() == 0, child.stderr_text()
    finally:
        child.close_stdin()


@pytest.mark.parametrize("kind", ["file", "null"])
def test_standard_input_from_a_file_or_the_null_device_reads_to_its_end(tmp_path, kind) -> None:
    source = tmp_path / "stdin.agc"
    source.write_text(
        'def main() -> Void\n'
        '  IO.inspect(IO.read())\n'
        '  IO.inspect(IO.gets())\n'
        'end\n',
        encoding="utf-8",
    )
    data = tmp_path / "input.txt"
    data.write_bytes(b"one\ntwo\n")
    env = vm_environment({"UV_THREADPOOL_SIZE": "1"})
    with open(data if kind == "file" else os.devnull, "rb") as stdin:
        result = subprocess.run([str(binary()), str(source)], cwd=tmp_path, env=env, stdin=stdin,
                                capture_output=True, timeout=scaled(30))
    text = '"one\\ntwo\\n"' if kind == "file" else '""'
    assert (result.returncode, result.stdout.decode()) == (
        0, '%s\nerror("IO.gets reached the end of input")\n' % text), result.stderr


def test_file_locks_are_idempotent_and_released_by_close(tmp_path) -> None:
    root = tmp_path
    source = root / "lock.agc"
    source.write_text(
        'def main() -> Void\n'
        '  path = System.args()[0]\n'
        '  first = File.open(path, "create_private", 5000).unwrap!\n'
        '  second = File.open(path, "read", 5000).unwrap!\n'
        '  puts(File.try_lock(first, 5000))\n'
        '  puts(File.try_lock(first, 5000))\n'
        '  puts(File.try_lock(second, 5000))\n'
        '  File.close(first, 5000).unwrap!\n'
        '  puts(File.try_lock(second, 5000))\n'
        '  File.close(second, 5000).unwrap!\n'
        'end\n',
        encoding="utf-8",
    )
    result = run([binary(), source, root / "lock"], cwd=root, env=vm_environment())
    assert (result.code, result.stdout) == (0, "ok(true)\nok(true)\nok(false)\nok(true)\n"), result.stderr


def test_regular_files_directories_and_metadata_work_together(tmp_path) -> None:
    root = tmp_path
    source = root / "files.agc"
    source.write_text(
        'def main() -> Void\n'
        '  base = System.args()[0]\n'
        '  dir = base + "/nested/data"\n'
        '  path = dir + "/notes.txt"\n'
        '  puts(Dir.mkdir(dir, 5000).ok?)\n'
        '  puts(Dir.mkdir(dir, 5000).ok?)\n'
        '  file = File.open(path, "write", 5000).unwrap!\n'
        '  File.write(file, "alpha\\n", 5000).unwrap!\n'
        '  File.write_bytes(file, "beta".bytes, 5000).unwrap!\n'
        '  File.close(file, 5000).unwrap!\n'
        '  File.append_text(path, "\\nend", 5000).unwrap!\n'
        '  puts(File.read_text(path, 5000).unwrap!)\n'
        '  stat = File.stat(path, 5000).unwrap!\n'
        '  lstat = File.lstat(path, 5000).unwrap!\n'
        '  puts("#{stat.kind} #{stat.size_bytes} #{lstat.kind}")\n'
        '  puts(Dir.list(dir, 5000).unwrap![0])\n'
        'end\n',
        encoding="utf-8",
    )
    result = run([binary(), source, root], cwd=root, env=vm_environment())
    assert (result.code, result.stdout) == (0, "true\ntrue\nalpha\nbeta\nend\nfile 14 file\nnotes.txt\n"), result.stderr


def test_harness_stops_native_children_on_timeout(adopt) -> None:
    command = [PYTHON, "-c", "import time; time.sleep(60)"]
    child = adopt(Child(command, capture_stderr=True))
    child.stop()
    assert child.process.poll() is not None
    with pytest.raises(AssertionError, match="timed out"):
        run(command, timeout=0.2)
