"""The multi-version site: tools/site_versions.py builds each release tag, caches it by commit sha and assembles one folder.

The real Hugo build runs in `make site-versions` and pages.yml. This test runs the whole assembly on a small git
repository whose `make site` writes two pages: the tags that become versions (and the ones that do not), the tag with
no site left out, a tag that fails (or no tag built at all) failing the run, the latest release served at the root, the
selector tags added to every page once and to nothing else, and a second run that builds only what is not cached.
"""
import importlib.util
import json
import os
import shutil
import subprocess

import pytest

from tests.agentica_test import ROOT

# Each tag's `make site` records its own base URL and version in its pages; a tree with a FAIL file fails.
MAKEFILE = (
    ".PHONY: site\n"
    "site:\n"
    "\t@test ! -e FAIL\n"
    "\t@if [ -e FLAKY ] && [ ! -e $(ONCE) ]; then touch $(ONCE); exit 1; fi\n"
    "\t@echo run >> $(RUNS)\n"
    "\tmkdir -p site/public/library\n"
    "\tprintf '<html><head></head><body>%s %s</body></html>' '$(HUGO_FLAGS)' \"$$(cat VERSION)\""
    " > site/public/library/index.html\n"
    "\tprintf '<html><head></head><body>%s</body></html>' '$(HUGO_FLAGS)' > site/public/index.html\n"
    "\tprintf 'see <head></head> /agentica/' > site/public/llms.txt\n"
)


def load_tool():
    spec = importlib.util.spec_from_file_location("agentica_site_versions_tool", ROOT / "tools" / "site_versions.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


tool = load_tool()


def git(repo, *args):
    identity = ["-c", "user.name=t", "-c", "user.email=t@t"]
    subprocess.run(["git", *identity, "-C", str(repo), *args], check=True, capture_output=True)


def release(repo, version, tag=None, fail=False, flaky=False):
    """Commit a version; `fail` makes its `make site` fail always, `flaky` only the first time."""
    (repo / "VERSION").write_text(version + "\n")
    for name, on in (("FAIL", fail), ("FLAKY", flaky)):
        marker = repo / name
        if on:
            marker.write_text("")
        elif marker.exists():
            marker.unlink()
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", version)
    if tag:
        git(repo, "tag", tag)


@pytest.fixture
def repo(tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    (repo / "site" / "versions").mkdir(parents=True)
    (repo / ".github" / "workflows").mkdir(parents=True)
    (repo / "Makefile").write_text(MAKEFILE)
    git(repo, "init", "-q")
    release(repo, "0.1.0", "0.1.0")  # before the site existed: no site/hugo.toml, no pages.yml
    (repo / "site" / "hugo.toml").write_text("")
    for name in tool.SELECTOR_FILES:
        shutil.copy(ROOT / "site" / "versions" / name, repo / "site" / "versions" / name)
    pins = "HUGO_VERSION: 1.0.0\n  HUGO_SHA256: a\n  DART_SASS_VERSION: 1.0.0\n  DART_SASS_SHA256: b\n"
    (repo / ".github" / "workflows" / "pages.yml").write_text("env:\n  " + pins)
    release(repo, "0.9.0", "0.9.0")
    release(repo, "0.10.0-beta.1", "0.10.0-beta.1")
    release(repo, "0.10.0", "0.10.0")
    release(repo, "0.11.0", "0.11.0")
    release(repo, "0.12.0", "bootstrap-racket")
    monkeypatch.setattr(tool, "ROOT", repo)
    monkeypatch.setattr(tool, "tool_env", lambda workflow, tools: dict(os.environ))
    return repo


def build(tmp_path, monkeypatch):
    """Run the CLI; returns its exit code, the output folder and how many `make site` runs there were so far."""
    runs = tmp_path / "runs"
    monkeypatch.setenv("RUNS", str(runs))
    monkeypatch.setenv("ONCE", str(tmp_path / "once"))
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(tmp_path / "summary.md"))
    monkeypatch.setenv("GITHUB_OUTPUT", str(tmp_path / "output"))
    (tmp_path / "output").unlink(missing_ok=True)
    code = tool.main([
        "build", "--out", str(tmp_path / "out"), "--cache", str(tmp_path / "cache"),
        "--tools", str(tmp_path / "tools"), "--base-url", "https://example.org/docs",
    ])
    return code, tmp_path / "out", runs.read_text().count("run") if runs.exists() else 0


def test_pins_come_from_the_real_workflow():
    pinned = tool.pins((ROOT / ".github" / "workflows" / "pages.yml").read_text())
    assert pinned["HUGO_VERSION"].count(".") == 2 and pinned["DART_SASS_VERSION"].count(".") == 2
    assert len(pinned["HUGO_SHA256"]) == 64 and len(pinned["DART_SASS_SHA256"]) == 64


def test_one_folder_per_release_with_the_latest_at_the_root(repo, tmp_path, monkeypatch):
    code, out, _ = build(tmp_path, monkeypatch)
    assert code == 0
    # dev is first in the selector; the latest release stays the one marked (and selected at the root).
    assert json.loads((out / "versions.json").read_text()) == [
        {"version": "dev", "path": "dev/"},
        {"version": "0.11.0", "path": "0.11.0/", "latest": True},
        {"version": "0.10.0", "path": "0.10.0/"},
        {"version": "0.9.0", "path": "0.9.0/"},
    ]
    # Each build bakes in its own base URL; the root is the latest release under the root URL.
    assert "--baseURL https://example.org/docs/0.9.0/ 0.9.0" in (out / "0.9.0" / "library" / "index.html").read_text()
    assert "--baseURL https://example.org/docs/ 0.11.0" in (out / "library" / "index.html").read_text()
    assert "--baseURL https://example.org/docs/dev/" in (out / "dev" / "index.html").read_text()
    assert not (out / "0.1.0").exists() and not (out / "0.10.0-beta.1").exists()
    assert "`0.1.0`" in (tmp_path / "summary.md").read_text()
    assert (out / "_versions" / "selector.js").exists() and (out / "_versions" / "selector.css").exists()


def test_every_html_page_loads_the_selector_once_and_the_cache_skips_builds(repo, tmp_path, monkeypatch):
    code, out, first = build(tmp_path, monkeypatch)
    tags = (
        '<link rel="stylesheet" href="/docs/_versions/selector.css">'
        '<script src="/docs/_versions/selector.js" defer></script>'
    )
    pages = list(out.rglob("*.html"))
    assert pages and all(page.read_text().count(tags) == 1 for page in pages)
    # Other files are not touched, even when they look like a page.
    assert (out / "llms.txt").read_text() == "see <head></head> /agentica/"
    # 0.9.0, 0.10.0 and 0.11.0 (versioned and at the root) and dev; 0.1.0 has no site and never runs make.
    assert first == 5
    code, out, total = build(tmp_path, monkeypatch)
    assert code == 0 and total - first == 1  # only dev builds again: the working tree is never cached
    assert all(page.read_text().count(tags) == 1 for page in out.rglob("*.html"))


def test_a_tag_that_fails_fails_the_run(repo, tmp_path, monkeypatch, capsys):
    release(repo, "0.11.1", "0.11.1", fail=True)
    release(repo, "0.12.0")
    code, _, _ = build(tmp_path, monkeypatch)
    assert code == 1
    assert "FAIL 0.11.1" in capsys.readouterr().out
    assert "Failed: `0.11.1`" in (tmp_path / "summary.md").read_text()


def test_a_tag_that_fails_once_is_retried_and_built(repo, tmp_path, monkeypatch, capsys):
    release(repo, "0.11.1", "0.11.1", flaky=True)
    release(repo, "0.12.0")
    code, out, _ = build(tmp_path, monkeypatch)
    assert code == 0
    assert "retry 0.11.1" in capsys.readouterr().out
    data = json.loads((out / "versions.json").read_text())
    assert next(e for e in data if e.get("latest")) == {"version": "0.11.1", "path": "0.11.1/", "latest": True}


def test_a_tag_without_a_site_newer_than_a_built_tag_fails_the_run(repo, tmp_path, monkeypatch, capsys):
    config = repo / "site" / "hugo.toml"
    config.unlink()  # a tree the script reads as "no site", though a newer release than 0.11.0 has one
    release(repo, "0.11.1", "0.11.1")
    config.write_text("")
    release(repo, "0.12.0")
    code, _, _ = build(tmp_path, monkeypatch)
    assert code == 1
    assert "FAIL 0.11.1" in capsys.readouterr().out


def test_the_cache_keeps_only_current_builds_and_says_when_something_is_new(repo, tmp_path, monkeypatch):
    build(tmp_path, monkeypatch)
    assert (tmp_path / "output").read_text() == "fresh=true\n"
    stray = tmp_path / "cache" / "old-tag-entry"
    stray.mkdir()
    # 0.9.0, 0.10.0, 0.11.0 and the root copy of 0.11.0, and the stray one.
    assert len(list((tmp_path / "cache").iterdir())) == 5
    build(tmp_path, monkeypatch)
    assert (tmp_path / "output").read_text() == "fresh=false\n"
    assert not stray.exists() and len(list((tmp_path / "cache").iterdir())) == 4


def test_a_run_with_no_version_fails(repo, tmp_path, monkeypatch):
    monkeypatch.setattr(tool, "final_tags", lambda: ["0.1.0"])
    code, _, _ = build(tmp_path, monkeypatch)
    assert code == 1


def test_a_download_retries_5xx_and_short_bodies_but_never_a_404(tmp_path, monkeypatch):
    import io
    import urllib.error
    monkeypatch.setattr(tool.sys, "platform", "linux")
    monkeypatch.setattr(tool.os, "uname", lambda: type("Uname", (), {"machine": "x86_64"})())
    pauses = []
    monkeypatch.setattr(tool.time, "sleep", pauses.append)
    answers = [503, 429, "short", "ok"]

    class Response(io.BytesIO):
        def __init__(self, body, length):
            super().__init__(body)
            self.headers = {"Content-Length": str(length)}

    def urlopen(url, timeout):
        answer = answers.pop(0)
        if answer == "ok":
            return Response(b"not a tar", 9)
        if answer == "short":
            return Response(b"not", 9)
        raise urllib.error.HTTPError(url, answer, "busy", {}, None)

    monkeypatch.setattr(tool.urllib.request, "urlopen", urlopen)
    with pytest.raises(tool.BuildError, match="checksum mismatch"):
        tool._download("https://example.invalid/x.tar.gz", "0" * 64, tmp_path / "out", strip=0)
    assert pauses == [10, 30, 60]

    pauses.clear()
    answers[:] = [404, "ok"]
    with pytest.raises(urllib.error.HTTPError):
        tool._download("https://example.invalid/x.tar.gz", "0" * 64, tmp_path / "out2", strip=0)
    assert pauses == []
