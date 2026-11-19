"""The multi-version site: tools/site_versions.py builds each release tag, caches it by commit sha and assembles one folder.

The real Hugo build runs in `make site-versions` and pages.yml. This test runs the whole assembly on a small git
repository whose `make site` writes two pages: the tags that become versions (and the ones that do not), the tag with
no site left out, a tag that fails (or no tag built at all) failing the run, the latest release served at the root, the
selector loaded once by every page (the docs theme's own tags, or the assembly's on a page built without the theme) and
by nothing else, a second run that builds only what is not cached, and each tag built with the docs theme commit it
pins.
"""
import importlib.util
import json
import os
import subprocess

import pytest

from tests.agentica_test import ROOT

# Each tag's `make site` records its own base URL and version in its pages (and the mark of its docs theme, when it has
# one); a tree with a FAIL file fails. With the selector on (HUGO_PARAMS_VERSIONS_*), it does what the docs theme does:
# the selector's two files under _versions/, and its two tags, minified, in the head of every page.
MAKEFILE = (
    "HEAD = $(if $(HUGO_PARAMS_VERSIONS_ENABLED),<link rel=stylesheet href=$(HUGO_PARAMS_VERSIONS_ROOT)_versions/"
    "selector.css><script src=$(HUGO_PARAMS_VERSIONS_ROOT)_versions/selector.js defer></script>)\n"
    ".PHONY: site\n"
    "site:\n"
    "\t@test ! -e FAIL\n"
    "\t@test ! -e site/themes/docs-theme/FAIL\n"
    "\t@if [ -e FLAKY ] && [ ! -e $(ONCE) ]; then touch $(ONCE); exit 1; fi\n"
    "\t@echo run >> $(RUNS)\n"
    "\tmkdir -p site/public/library\n"
    "\tprintf '<html><head>$(HEAD)</head><body>%s %s</body></html>' '$(HUGO_FLAGS)' \"$$(cat VERSION)\""
    " > site/public/library/index.html\n"
    "\tprintf '<html><head>$(HEAD)</head><body>%s</body></html>' '$(HUGO_FLAGS)' > site/public/index.html\n"
    "\tprintf 'see <head></head> /agentica/' > site/public/llms.txt\n"
    "\t@if [ -e site/themes/docs-theme/mark ]; then cat site/themes/docs-theme/mark >> site/public/index.html; fi\n"
    "\tmkdir -p site/public/only-$$(cat VERSION)\n"
    "\tprintf '<html><head><link href=x REL=canonical><meta content=all name=robots><link rel=icon href=data:x></head>"
    "<body><link rel=canonical href=body></body></html>' > site/public/only-$$(cat VERSION)/index.html\n"
    "\tprintf '<html><head>$(HEAD)</head><body>not found</body></html>' > site/public/404.html\n"
    "\t@if [ -n '$(HUGO_PARAMS_VERSIONS_ENABLED)' ]; then mkdir -p site/public/_versions;"
    " echo js > site/public/_versions/selector.js; echo css > site/public/_versions/selector.css; fi\n"
    "\tprintf '<urlset></urlset>' > site/public/sitemap.xml\n"
    "\t@if [ -e site/content.es ]; then mkdir -p site/public/es; printf '<html lang=es><head><link rel=alternate hreflang=en href=https://example.org/docs/><link rel=alternate hreflang=es href=https://example.org/docs/es/></head>"
    "<body>es</body></html>' > site/public/es/index.html; printf '<urlset></urlset>' > site/public/es/sitemap.xml;"
    " printf '<html lang=en><head><link rel=alternate hreflang=en href=https://example.org/docs/><link rel=alternate hreflang=es href=https://example.org/docs/es/></head><body>root</body></html>' > site/public/index.html; fi\n"
    "\tgit rev-parse --is-inside-work-tree > site/public/git.txt\n"
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
    """0.9.0 and 0.10.0 from before the docs theme, 0.11.0 with it (its `mark` is "theme one", in tmp_path/theme)."""
    repo = tmp_path / "repo"
    (repo / "site").mkdir(parents=True)
    (repo / ".github" / "workflows").mkdir(parents=True)
    (repo / "Makefile").write_text(MAKEFILE)
    git(repo, "init", "-q")
    release(repo, "0.1.0", "0.1.0")  # before the site existed: no site/hugo.toml, no pages.yml
    (repo / "site" / "hugo.toml").write_text("")
    pins = "HUGO_VERSION: 1.0.0\n  HUGO_SHA256: a\n  DART_SASS_VERSION: 1.0.0\n  DART_SASS_SHA256: b\n"
    (repo / ".github" / "workflows" / "pages.yml").write_text("env:\n  " + pins)
    release(repo, "0.9.0", "0.9.0")
    release(repo, "0.10.0-beta.1", "0.10.0-beta.1")
    release(repo, "0.10.0", "0.10.0")
    theme = tmp_path / "theme"
    theme.mkdir()
    git(theme, "init", "-q")
    (theme / "mark").write_text("theme one")
    (theme / "assets" / "versions").mkdir(parents=True)
    for name in ("selector.js", "selector.css"):
        (theme / "assets" / "versions" / name).write_text("theme " + name)
    git(theme, "add", "-A")
    git(theme, "commit", "-q", "-m", "one")
    git(repo, "-c", "protocol.file.allow=always", "submodule", "add", "-q", str(theme), tool.THEME)
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


def spanish_release(repo, version):
    """A release with a Spanish site (site/content.es), which the fixture's `make site` builds into es/."""
    (repo / "site" / "content.es").mkdir(exist_ok=True)
    (repo / "site" / "content.es" / "_index.md").write_text("Hola\n")
    release(repo, version, version)


def spanish_build(repo, tmp_path, monkeypatch):
    """Two releases with a Spanish site, then the build; dev is the working tree, which has one too."""
    spanish_release(repo, "0.13.0")
    spanish_release(repo, "0.14.0")
    code, out, _ = build(tmp_path, monkeypatch)
    assert code == 0
    return out


def test_a_version_with_a_spanish_copy_lists_its_languages(repo, tmp_path, monkeypatch):
    out = spanish_build(repo, tmp_path, monkeypatch)
    entries = {entry["version"]: entry for entry in json.loads((out / "versions.json").read_text())}
    for version in ("dev", "0.14.0", "0.13.0"):
        assert entries[version]["languages"] == ["en", "es"]
    assert "languages" not in entries["0.10.0"]


def test_a_spanish_copy_loses_its_sitemaps_and_alternates_and_the_root_keeps_them(repo, tmp_path, monkeypatch):
    out = spanish_build(repo, tmp_path, monkeypatch)
    for folder in ("0.13.0", "dev"):
        assert not list((out / folder).rglob("sitemap.xml"))
        for page in ("index.html", "es/index.html"):
            assert "hreflang" not in (out / folder / page).read_text().split("</head>")[0]
    assert (out / "sitemap.xml").exists() and (out / "es" / "sitemap.xml").exists()
    root_head = (out / "es" / "index.html").read_text().split("</head>")[0]
    assert root_head.count("hreflang=es") == 1 and root_head.count("hreflang=en") == 1


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
    # A Hugo warning fails dev's build only: a released tag's content cannot change.
    tag = "--baseURL https://example.org/docs/0.9.0/ --panicOnWarning=false 0.9.0"
    assert tag in (out / "0.9.0" / "library" / "index.html").read_text()
    root = "--baseURL https://example.org/docs/ --panicOnWarning=false 0.11.0"
    assert root in (out / "library" / "index.html").read_text()
    assert "--baseURL https://example.org/docs/dev/</body>" in (out / "dev" / "index.html").read_text()
    assert not (out / "0.1.0").exists() and not (out / "0.10.0-beta.1").exists()
    assert "`0.1.0`" in (tmp_path / "summary.md").read_text()
    # The root build, with the theme, publishes the selector that every version loads.
    assert (out / "_versions" / "selector.js").exists() and (out / "_versions" / "selector.css").exists()


def test_every_html_page_loads_the_selector_once_and_the_cache_skips_builds(repo, tmp_path, monkeypatch):
    code, out, first = build(tmp_path, monkeypatch)
    tags = (
        '<link rel="stylesheet" href="/docs/_versions/selector.css">'
        '<script src="/docs/_versions/selector.js" defer></script>'
    )
    pages = list(out.rglob("*.html"))
    assert pages and all(page.read_text().count("_versions/selector.js") == 1 for page in pages)
    # A build with the theme loads it with the theme's tags, from the root of all versions; one from before the theme
    # gets the assembly's.
    for page in ("0.11.0/library/index.html", "library/index.html", "dev/index.html", "0.11.0/404.html"):
        text = (out / page).read_text()
        assert "<script src=/docs/_versions/selector.js defer>" in text and tags not in text
    for page in ("0.9.0/library/index.html", "0.10.0/only-0.10.0/index.html", "0.10.0/404.html"):
        assert (out / page).read_text().count(tags) == 1
    # Other files are not touched, even when they look like a page.
    assert (out / "llms.txt").read_text() == "see <head></head> /agentica/"
    # 0.9.0, 0.10.0 and 0.11.0 (versioned and at the root) and dev; 0.1.0 has no site and never runs make.
    assert first == 5
    code, out, total = build(tmp_path, monkeypatch)
    assert code == 0 and total - first == 1  # only dev builds again: the working tree is never cached
    assert all(page.read_text().count("_versions/selector.js") == 1 for page in out.rglob("*.html"))


def test_a_root_built_without_the_theme_gets_the_selector_of_the_current_theme(repo, tmp_path, monkeypatch):
    monkeypatch.setattr(tool, "final_tags", lambda: ["0.10.0", "0.9.0"])
    code, out, _ = build(tmp_path, monkeypatch)
    assert code == 0
    assert (out / "_versions" / "selector.js").read_text() == "theme selector.js"
    assert (out / "_versions" / "selector.css").read_text() == "theme selector.css"


def test_only_the_root_is_indexed_and_tags_build_in_a_git_checkout(repo, tmp_path, monkeypatch):
    code, out, _ = build(tmp_path, monkeypatch)
    assert code == 0
    canonical = '<link rel="canonical" href="https://example.org/docs/library/">'
    noindex = '<meta name="robots" content="noindex,follow">'
    for folder in ("0.9.0", "0.10.0"):
        page = (out / folder / "library" / "index.html").read_text()
        assert page.count(canonical) == 1 and noindex not in page
        assert (out / folder / "404.html").read_text().count(noindex) == 1
    for folder in ("0.9.0", "0.10.0", "dev"):
        assert not (out / folder / "sitemap.xml").exists()
    # A page the root does not have: noindex; its own head tags go (any case or order), and the body stays as it was.
    old = (out / "0.10.0" / "only-0.10.0" / "index.html").read_text()
    head, body = old.split("</head>")
    assert head.count(noindex) == 1 and "canonical" not in head.lower() and "content=all" not in head
    assert body == "<body><link rel=canonical href=body></body></html>"
    # A page with an icon of its own (a tag from before the docs theme) gets the org icons instead, at the root too.
    assert head.count(tool.ORG_ICONS) == 1 and "data:x" not in head
    root = (out / "only-0.11.0" / "index.html").read_text()
    assert root.count(tool.ORG_ICONS) == 1 and "data:x" not in root
    # dev is unreleased: every page is noindex, with no canonical, even where the root has the page.
    for page in ("library/index.html", "index.html", "only-0.12.0/index.html", "404.html"):
        text = (out / "dev" / page).read_text().split("</head>")[0]
        assert text.count(noindex) == 1 and "canonical" not in text.lower()
    # The root keeps its own tags and its sitemap.
    assert "content=all" in (out / "only-0.11.0" / "index.html").read_text()
    assert (out / "sitemap.xml").exists() and "noindex" not in (out / "library" / "index.html").read_text()
    # Each tag ran make in a git checkout (Hugo's enableGitInfo needs one), and no worktree is left behind.
    assert (out / "0.10.0" / "git.txt").read_text().strip() == "true"
    worktrees = subprocess.run(["git", "-C", str(repo), "worktree", "list"], capture_output=True, text=True).stdout
    assert len(worktrees.splitlines()) == 1


def tag_with_theme(repo, tmp_path):
    """Tag 0.13.0, with the docs theme of the fixture; returns the theme repo."""
    release(repo, "0.13.0", "0.13.0")
    return tmp_path / "theme"


def test_a_tag_with_the_theme_is_built_with_the_current_theme_and_pins(repo, tmp_path, monkeypatch):
    theme = tag_with_theme(repo, tmp_path)
    # The checkout then pins a newer theme and newer tools; the tag keeps its own pins.
    (theme / "mark").write_text("theme two")
    git(theme, "commit", "-q", "-am", "two")
    git(repo / tool.THEME, "pull", "-q")
    workflow = repo / ".github" / "workflows" / "pages.yml"
    workflow.write_text(workflow.read_text().replace("HUGO_VERSION: 1.0.0", "HUGO_VERSION: 2.0.0"))
    release(repo, "0.14.0-dev")
    used = []
    monkeypatch.setattr(tool, "tool_env", lambda text, tools: used.append(tool.pins(text)["HUGO_VERSION"]) or dict(os.environ))
    code, out, first = build(tmp_path, monkeypatch)
    assert code == 0
    # The tag's content, the look of the current theme: at its folder and at the root.
    assert "theme two" in (out / "0.13.0" / "index.html").read_text()
    assert "0.13.0" in (out / "0.13.0" / "library" / "index.html").read_text()
    assert "theme two" in (out / "index.html").read_text()
    assert "theme two" in (out / "dev" / "index.html").read_text()
    # A tag from before the theme keeps its own Hugo pins; one with the theme takes the current ones.
    assert used.count("2.0.0") == 4 and used.count("1.0.0") == 2  # 0.11.0, 0.13.0 twice and dev; 0.9.0, 0.10.0
    # A newer theme pin changes the cache key of the tags with the theme, so they build again; the others stay cached.
    (theme / "mark").write_text("theme three")
    git(theme, "commit", "-q", "-am", "three")
    git(repo / tool.THEME, "pull", "-q")
    release(repo, "0.14.0-dev2")
    code, out, second = build(tmp_path, monkeypatch)
    assert code == 0 and second - first == 4  # 0.11.0, 0.13.0 at its folder and at the root, and dev
    assert "theme three" in (out / "0.13.0" / "index.html").read_text()
    # So does a change of the pins alone.
    workflow.write_text(workflow.read_text().replace("HUGO_VERSION: 2.0.0", "HUGO_VERSION: 3.0.0"))
    release(repo, "0.14.0-dev3")
    code, out, third = build(tmp_path, monkeypatch)
    assert code == 0 and third - second == 4 and used.count("3.0.0") == 4


def test_org_icons_match_the_theme_and_a_page_with_them_is_left_alone(tmp_path):
    partial = (ROOT / tool.THEME / "layouts" / "_partials" / "favicon.html").read_text()
    links = "".join(line for line in partial.splitlines() if line.startswith("<link"))
    assert links == tool.ORG_ICONS
    themed = "<html><head>\n" + partial.split("-}}\n", 1)[1] + "</head><body>a</body></html>"
    pages = {"themed.html": themed, "old.html": '<head><link rel="shortcut icon" href=x></head>', "part.html": "<p>"}
    for name, text in pages.items():
        (tmp_path / name).write_text(text)
    assert tool.use_org_icons(tmp_path) == 1
    assert (tmp_path / "themed.html").read_text() == themed and (tmp_path / "part.html").read_text() == "<p>"
    assert (tmp_path / "old.html").read_text() == "<head>" + tool.ORG_ICONS + "</head>"


def test_a_tag_that_fails_with_the_current_theme_fails_the_run(repo, tmp_path, monkeypatch, capsys):
    theme = tag_with_theme(repo, tmp_path)
    # A theme that the tag's `make site` cannot build with (the fixture fails on a FAIL file in the tree).
    (theme / "FAIL").write_text("")
    git(theme, "add", "-A")
    git(theme, "commit", "-q", "-m", "breaks old tags")
    git(repo / tool.THEME, "pull", "-q")
    release(repo, "0.14.0-dev")
    code, _, _ = build(tmp_path, monkeypatch)
    assert code == 1
    assert "0.13.0" in capsys.readouterr().out


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
