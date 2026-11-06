"""The multi-version site: tools/site_versions.py builds each release tag, caches it by commit sha and assembles one folder.

The real Hugo build runs in `make site-versions` and pages.yml. This test runs the whole assembly on a small git
repository whose `make site` writes two pages: the tags that become versions (and the ones that do not), a tag that
fails to build left out, the latest release served at the root, the selector tag added to every page once, and a second
run that builds only what is not in the cache.
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
    "\t@echo run >> $(RUNS)\n"
    "\tmkdir -p site/public/library\n"
    "\tprintf '<html><head></head><body>%s %s</body></html>' '$(HUGO_FLAGS)' \"$$(cat VERSION)\""
    " > site/public/library/index.html\n"
    "\tprintf '<html><head></head><body>%s</body></html>' '$(HUGO_FLAGS)' > site/public/index.html\n"
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


def release(repo, version, tag=None, fail=False):
    (repo / "VERSION").write_text(version + "\n")
    marker = repo / "FAIL"
    if fail:
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
    (repo / "site" / "hugo.toml").write_text("")
    for name in tool.SELECTOR_FILES:
        shutil.copy(ROOT / "site" / "versions" / name, repo / "site" / "versions" / name)
    pins = "HUGO_VERSION: 1.0.0\n  HUGO_SHA256: a\n  DART_SASS_VERSION: 1.0.0\n  DART_SASS_SHA256: b\n"
    (repo / ".github" / "workflows" / "pages.yml").write_text("env:\n  " + pins)
    (repo / "Makefile").write_text(MAKEFILE)
    git(repo, "init", "-q")
    release(repo, "0.9.0", "0.9.0")
    release(repo, "0.10.0-beta.1", "0.10.0-beta.1")
    release(repo, "0.10.0", "0.10.0")
    release(repo, "0.10.1", "0.10.1", fail=True)
    release(repo, "0.11.0", "0.11.0")
    release(repo, "0.12.0", "bootstrap-racket")
    monkeypatch.setattr(tool, "ROOT", repo)
    monkeypatch.setattr(tool, "tool_env", lambda workflow, tools: dict(os.environ))
    return repo


def build(tmp_path, monkeypatch):
    """Run the build; returns the output folder and how many `make site` runs it made so far."""
    runs = tmp_path / "runs"
    monkeypatch.setenv("RUNS", str(runs))
    args = tool.argparse.Namespace(
        out=str(tmp_path / "out"), cache=str(tmp_path / "cache"), tools=str(tmp_path / "tools"),
        base_url="https://example.org/docs",
    )
    assert tool.build(args) == 0
    return tmp_path / "out", runs.read_text().count("run")


def test_one_folder_per_release_with_the_latest_at_the_root(repo, tmp_path, monkeypatch, capsys):
    out, _ = build(tmp_path, monkeypatch)
    assert json.loads((out / "versions.json").read_text()) == [
        {"version": "0.11.0", "path": "0.11.0/", "latest": True},
        {"version": "0.10.0", "path": "0.10.0/"},
        {"version": "0.9.0", "path": "0.9.0/"},
        {"version": "dev", "path": "dev/"},
    ]
    # Each build bakes in its own base URL; the root is the latest release under the root URL.
    assert "--baseURL https://example.org/docs/0.9.0/ 0.9.0" in (out / "0.9.0" / "library" / "index.html").read_text()
    assert "--baseURL https://example.org/docs/ 0.11.0" in (out / "library" / "index.html").read_text()
    assert "--baseURL https://example.org/docs/dev/" in (out / "dev" / "index.html").read_text()
    assert not (out / "0.10.1").exists() and not (out / "0.10.0-beta.1").exists()
    assert "left out: 0.10.1" in capsys.readouterr().out
    assert (out / "_versions" / "selector.js").exists()


def test_every_page_loads_the_selector_once_and_the_cache_skips_builds(repo, tmp_path, monkeypatch):
    out, first = build(tmp_path, monkeypatch)
    tag = '<script src="/docs/_versions/selector.js" defer></script>'
    pages = list(out.rglob("*.html"))
    assert pages and all(page.read_text().count(tag) == 1 for page in pages)
    # 0.9.0, 0.10.0 and 0.11.0 (versioned and at the root) and dev; the failing 0.10.1 stops before it records a run.
    assert first == 5
    _, total = build(tmp_path, monkeypatch)
    assert total - first == 1  # only dev builds again: the working tree is never cached
