import json
import tempfile
import unittest
from pathlib import Path

import diagnostics


def bash_call(call: str, command: str, output: str) -> list[dict]:
    return [
        {
            "type": "tool_execution_start",
            "toolCallId": call,
            "toolName": "bash",
            "args": {"command": command},
        },
        {
            "type": "tool_execution_end",
            "toolCallId": call,
            "toolName": "bash",
            "result": {"content": [{"type": "text", "text": output}]},
        },
    ]


PLAIN = 'a.agc:2:7 error[CHECK-UNKNOWN-NAME]\nunknown function "len"\n\n2 |   x = len(s)\n'
AI = "check failed: 1 error\n\n[CHECK-UNKNOWN-NAME]\n  message: unknown function \"str\"\n  source: y = str(n)\n"
JSON = '{"code":"PARSE-UNEXPECTED-TOKEN","message":"expected an expression"}'
DOCS = "file.agc:2:14 error[CHECK-TYPE-MISMATCH]\nexpected Int, found String\n"
ESCAPED = '{"code":"CHECK-UNKNOWN-NAME","message":"unknown function \\"len\\""}'


class DiagnosticsTests(unittest.TestCase):
    def test_counts_codes_messages_sources_and_repeats(self) -> None:
        events = (
            bash_call("1", "cat notes.md", PLAIN)
            + bash_call("2", "agentica check a.agc", PLAIN)
            + bash_call("3", "agentica --ai a.agc", AI)
            + bash_call("4", "agentica --json a.agc", JSON)
            + bash_call("5", "agentica a.agc", "ok\n")
            + bash_call("6", "cat skills/agentica-programming/references/diagnostics.md", DOCS)
            + bash_call("7", "strings bin/agentica | grep CHECK", DOCS)
            + bash_call("8", "cd /workspace && ./bin/agentica --json a.agc", ESCAPED)
        )
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory) / "t1-stats-binary-1"
            run.mkdir()
            (run / "agent.jsonl").write_text(
                "\n".join(json.dumps(event) for event in events) + "\n", encoding="utf-8"
            )
            stats, runs, calls = diagnostics.collect([Path(directory)], {"binary"})

        self.assertEqual((runs, calls), (1, 5))
        unknown = stats["CHECK-UNKNOWN-NAME"]
        self.assertEqual(unknown.hits, 3)
        self.assertEqual(unknown.repeats, 1)
        self.assertEqual(
            unknown.messages, {'unknown function "len"': 2, 'unknown function "str"': 1}
        )
        self.assertEqual(set(unknown.sources), {"x = len(s)", "y = str(n)"})
        self.assertEqual(stats["PARSE-UNEXPECTED-TOKEN"].messages["expected an expression"], 1)
        self.assertNotIn("CHECK-TYPE-MISMATCH", stats)

    def test_skips_other_arms_and_unknown_directories(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            for name in ("t1-stats-python-1", "scratch"):
                run = Path(directory) / name
                run.mkdir()
                (run / "agent.jsonl").write_text(
                    "\n".join(json.dumps(e) for e in bash_call("1", "agentica a.agc", PLAIN)),
                    encoding="utf-8",
                )
            stats, runs, calls = diagnostics.collect([Path(directory)], {"binary"})

        self.assertEqual((stats, runs, calls), ({}, 0, 0))

    def test_run_names_split_into_task_and_arm(self) -> None:
        for name, task, arm in (
            ("t1-stats-binary-1", "t1-stats", "binary"),
            ("t9-inventory-orders-typed-python-12", "t9-inventory-orders", "typed-python"),
            ("t9-inventory-orders-python-2", "t9-inventory-orders", "python"),
            ("t20-big-log-skill-3", "t20-big-log", "skill"),
            ("t20-big-log-skill-minimal-3", "t20-big-log", "skill-minimal"),
        ):
            with self.subTest(name=name):
                found = diagnostics.RUN_NAME.match(name)
                self.assertIsNotNone(found)
                self.assertEqual((found["task"], found["arm"]), (task, arm))


if __name__ == "__main__":
    unittest.main()
