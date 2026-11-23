"""File.seek through the CLI: a negative offset halts at the offset."""
import json

from tests.agentica_test import cli, run
from tests.spec_support import covered


def test_negative_offset_halts_at_the_offset(tmp_path):
    data = tmp_path / "data.txt"
    data.write_bytes(b"abc")
    program = tmp_path / "seek.agc"
    source = (
        "def main() -> Void\n"
        "  file = File.open(System.args()[0]).unwrap!\n"
        "  n = 0 - 1\n"
        "  puts(File.seek(file, n))\n"
        "end\n"
    )
    program.write_text(source, encoding="utf-8")
    result = run(cli() + ["--json", str(program), str(data)])
    assert result.code == 1
    found = json.loads(result.stderr)
    assert found["code"] == "RUNTIME-INDEX-OUT-OF-RANGE"
    assert covered(source, found["range"]) == "n"
