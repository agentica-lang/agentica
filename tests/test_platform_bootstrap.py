"""Native bootstrap contracts, without shells or repository runtime files."""

import json
import os
import shutil

from tests.agentica_test import PYTHON, Child, TestCase, run, vm_environment
from tests.agentica_test import vm_binary as binary


class PlatformBootstrap(TestCase):
    def test_copied_binary_compiles_and_runs_outside_the_checkout(self) -> None:
        root = self.make_temp_dir("agentica-native-")
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
        self.assertEqual(version.code, 0, version.stderr)
        self.assertRegex(version.stdout, r"^\d+\.\d+\.\d+")
        help_result = run(command + ["--help"], cwd=root, env=environment)
        self.assertEqual(help_result.code, 0, help_result.stderr)
        self.assertIn("agentica", help_result.stdout)
        checked = run(command + ["check", source], cwd=root, env=environment)
        self.assertEqual(checked.code, 0, checked.stderr)
        arguments = ["space value", '"quoted"', "", "ñ🙂"]
        expected = "relative\nstdlib\n" + "\n".join(arguments) + "\n"
        direct = run(command + [source, *arguments], cwd=root, env=environment)
        self.assertEqual((direct.code, direct.stdout), (0, expected), direct.stderr)
        bytecode = root / "compiled ñ🙂.agcb"
        compiled = run(
            command + ["compile", source, "-o", bytecode], cwd=root, env=environment
        )
        self.assertEqual(compiled.code, 0, compiled.stderr)
        loaded = run(
            command + ["run", "--", bytecode, *arguments], cwd=root, env=environment
        )
        self.assertEqual((loaded.code, loaded.stdout), (0, expected), loaded.stderr)
        previous = bytecode.read_bytes()
        refused = run(
            command + ["run", "--driver-pid", str(os.getpid() + 1), "--", bytecode],
            cwd=root, env=environment,
        )
        self.assertEqual(refused.code, 2, refused.stderr)
        self.assertEqual(bytecode.read_bytes(), previous)
        source.write_text(
            'def main() -> Void\n  value: Int = "wrong"\n  puts(value)\nend\n',
            encoding="utf-8",
        )
        invalid = run(command + ["--json", "check", source], cwd=root, env=environment)
        self.assertEqual(invalid.code, 1, invalid.stderr)
        self.assertEqual(json.loads(invalid.stderr)["code"], "CHECK-TYPE-MISMATCH")

    def test_file_limits_preserve_existing_data_and_flush_on_close(self) -> None:
        root = self.make_temp_dir("agentica-native-limits-")
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
        self.assertEqual(
            (result.code, result.stdout),
            (0, "false\nsentinel\n1048576\nfalse\n"),
            result.stderr,
        )
        self.assertEqual(output.read_bytes(), b"abcdefgh" * (1 << 17) + b"x")

    def test_standard_input_uses_a_pipe(self) -> None:
        root = self.make_temp_dir("agentica-native-stdin-")
        source = root / "stdin.agc"
        source.write_text(
            'def main() -> Void\n'
            '  puts(IO.gets())\n'
            'end\n',
            encoding="utf-8",
        )
        result = run([binary(), source], cwd=root, env=vm_environment(), stdin=b"from pipe\n")
        self.assertEqual((result.code, result.stdout), (0, 'ok("from pipe")\n'), result.stderr)

    def test_harness_stops_native_children_on_timeout(self) -> None:
        command = [PYTHON, "-c", "import time; time.sleep(60)"]
        child = self.adopt(Child(command, capture_stderr=True))
        child.stop()
        self.assertIsNotNone(child.process.poll())
        with self.assertRaisesRegex(AssertionError, "timed out"):
            run(command, timeout=0.2)
