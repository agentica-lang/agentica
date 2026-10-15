"""The logger on the VM (ported from vm-logger-test.rkt)."""
import json
import re

from tests.agentica_test import FIXTURES, PYTHON, TestCase, compile_agc, run, run_vm


class Logger(TestCase):
    def setUp(self):
        self.work = self.make_temp_dir("agentica-logger-")

    def bytecode_of(self, name):
        return compile_agc(FIXTURES / (name + ".agc"), self.work / (name + ".agcb"))

    def test_default_run_prints_one_info_line_on_stderr(self):
        result = run_vm(self.bytecode_of("logger-default"))
        self.assertEqual(result.code, 0)
        self.assertEqual(result.stdout, "")
        self.assertRegex(result.stderr,
                         r"\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z INFO hello\n\Z")

    def test_async_handler_leaves_every_event_in_the_file_in_order(self):
        result = run_vm(self.bytecode_of("logger-async"), cwd=self.work)
        self.assertEqual(result.code, 0)
        self.assertEqual(result.stdout, "")
        lines = (self.work / "app.log").read_text().splitlines()
        self.assertEqual(len(lines), 3)
        events = [json.loads(line) for line in lines]
        self.assertEqual([e["msg"] for e in events],
                         ["server started", "request done", "cannot open the cache"])
        self.assertEqual([e["level"] for e in events], ["info", "info", "error"])
        self.assertEqual(events[1]["fields"], {"path": "/items", "status": "200"})

    def test_python_peer_decodes_json_lines_and_checks_time_text(self):
        """The peer checks time_text against datetime."""
        peer = FIXTURES / "logger-peer.py"
        made = run([PYTHON, peer, "vectors", self.work])
        self.assertEqual(made.code, 0, made.stderr)
        result = run_vm(self.bytecode_of("logger-peer"), stdin=(self.work / "ms.txt").read_bytes())
        self.assertEqual(result.code, 0, result.stderr)
        (self.work / "stdout.txt").write_text(result.stdout)
        (self.work / "stderr.txt").write_text(result.stderr)
        checked = run([PYTHON, peer, "check", self.work])
        self.assertEqual((checked.code, checked.stdout.strip()), (0, "ok"), checked.stderr)
