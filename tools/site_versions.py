#!/usr/bin/env python3
"""Build the documentation site of every release into one folder (pages.yml; `make site-versions`).

    site_versions.py build [--out DIR] [--cache DIR] [--base-url URL] [--tools DIR]

The output is one site per final release (`X.Y.Z` tags, no pre-releases) under `VERSION/`, the development site under
`dev/`, the latest release again at the root, `versions.json` and `_versions/selector.{js,css}` (site/versions/).

Each tag is built from its own tree with `make site`, using the Hugo and Dart Sass versions that tag pins in its
`.github/workflows/pages.yml`. Only a tag whose tree has no site (no `site/hugo.toml`, no pins) and that is older than
every built tag is left out. Any other failure (a download, `npm ci`, a timeout, a Hugo error, a no-site tag newer than
a built one) is tried once more and then fails the run, so a release never drops silently from the deploy; so does a run
in which no tag built. The output of a tag is cached by its commit sha (and the base URL, which Hugo bakes into every
link), so a run builds only `dev` and the tags it has not seen; the cache folder is pruned to the current builds. With
GITHUB_OUTPUT set, `fresh=true` tells the workflow that something new is worth saving. The selector is not part of a
cached build: the assembly adds its `<link>` and `<script>` tags to every page, so a build from the cache loads the
current selector.

Python's standard library only.
"""
from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
import re
import shutil
import ssl
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
# The pauses between the tries of a download (5 tries): GitHub answers 5xx now and then.
DOWNLOAD_BACKOFF = (5, 10, 20, 40)
REQUEST_TIMEOUT = 30
FINAL_TAG = re.compile(r"^\d+\.\d+\.\d+$")
PIN = re.compile(r"^\s+(HUGO_VERSION|HUGO_SHA256|DART_SASS_VERSION|DART_SASS_SHA256):\s*(\S+)\s*$", re.MULTILINE)
SELECTOR_FILES = ("selector.js", "selector.css")
BUILD_TIMEOUT_S = 900
HUGO_URL = "https://github.com/gohugoio/hugo/releases/download/v{v}/hugo_extended_{v}_linux-amd64.tar.gz"
SASS_URL = "https://github.com/sass/dart-sass/releases/download/{v}/dart-sass-{v}-linux-x64.tar.gz"


class BuildError(Exception):
    """A version failed to build."""


class NoSite(BuildError):
    """The tree has no site to build (an old tag): the only failure that leaves a tag out instead of failing the run."""


def run(args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def final_tags() -> list[str]:
    """The `X.Y.Z` tags, newest first. Pre-releases (`-beta.N`) and other tags (`bootstrap-racket`) are left out."""
    names = run(["git", "-C", str(ROOT), "tag", "--list"], capture_output=True).stdout.split()
    return sorted((n for n in names if FINAL_TAG.match(n)), key=version_key, reverse=True)


def version_key(tag: str) -> tuple[int, ...]:
    return tuple(map(int, tag.split(".")))


def pins(workflow: str) -> dict[str, str]:
    """HUGO_VERSION, HUGO_SHA256, DART_SASS_VERSION and DART_SASS_SHA256 of a pages.yml."""
    found = dict(PIN.findall(workflow))
    missing = {"HUGO_VERSION", "HUGO_SHA256", "DART_SASS_VERSION", "DART_SASS_SHA256"} - found.keys()
    if missing:
        raise NoSite("pages.yml does not pin " + ", ".join(sorted(missing)))
    return found


def base_path(base_url: str) -> str:
    """The path of a base URL, with a slash at both ends: `/agentica/` for https://host/agentica."""
    return "/" + urlparse(base_url).path.strip("/") + "/" if urlparse(base_url).path.strip("/") else "/"


def with_slash(url: str) -> str:
    return url if url.endswith("/") else url + "/"


def selector_tags(root_path: str) -> str:
    """The two tags every page gets: the stylesheet first, so the selector is styled when it appears."""
    return (
        '<link rel="stylesheet" href="%s_versions/selector.css">'
        '<script src="%s_versions/selector.js" defer></script>' % (root_path, root_path)
    )


def inject_selector(site: Path, root_path: str) -> int:
    """Add the selector's tags before `</head>` of every HTML page that lacks exactly them; returns the pages changed."""
    tag = selector_tags(root_path)
    changed = 0
    for page in site.rglob("*.html"):
        text = page.read_text(encoding="utf-8")
        if tag in text or "</head>" not in text:
            continue
        page.write_text(text.replace("</head>", tag + "</head>", 1), encoding="utf-8")
        changed += 1
    return changed


def versions_json(built: list[str], dev: bool) -> list[dict]:
    """The order of the selector: `dev` first, then the releases newest first, the first release marked `latest`.

    The selector keeps the file's order and finds the latest release by the `latest` flag, not by position."""
    entries = [{"version": v, "path": v + "/"} for v in built]
    if entries:
        entries[0]["latest"] = True
    if dev:
        entries.insert(0, {"version": "dev", "path": "dev/"})
    return entries


def tool_env(workflow: str, tools: Path) -> dict[str, str]:
    """An environment whose PATH has the pinned hugo and sass, from the PATH or the tools folder (downloaded once)."""
    pinned = pins(workflow)
    hugo = _hugo_dir(pinned, tools)
    sass = _sass_dir(pinned, tools)
    env = dict(os.environ)
    env["PATH"] = os.pathsep.join([str(hugo), str(sass), env["PATH"]])
    env["DART_SASS"] = str(sass)
    return env


def _version_of(command: list[str], pattern: str, env: dict[str, str] | None = None) -> str | None:
    try:
        out = subprocess.run(command, capture_output=True, text=True, timeout=30, env=env).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    match = re.search(pattern, out)
    return match.group(1) if match else None


def _hugo_dir(pinned: dict[str, str], tools: Path) -> Path:
    version = pinned["HUGO_VERSION"]
    on_path = shutil.which("hugo")
    # The pinned archive is the extended edition: a hugo on PATH counts only when it is that edition too.
    if on_path and _version_of(["hugo", "version"], r"hugo v(\d+\.\d+\.\d+)(?=\S*\+extended)") == version:
        return Path(on_path).parent
    folder = tools / ("hugo-" + version)
    if not (folder / "hugo").exists():
        _download(HUGO_URL.format(v=version), pinned["HUGO_SHA256"], folder, strip=0)
    return folder


def _sass_dir(pinned: dict[str, str], tools: Path) -> Path:
    version = pinned["DART_SASS_VERSION"]
    home = Path.home() / ".local" / "opt"
    candidates = [Path(p) for p in (os.environ.get("DART_SASS"), home / "dart-sass", home / ("dart-sass-" + version)) if p]
    on_path = shutil.which("sass")
    if on_path:
        candidates.append(Path(on_path).parent)
    for folder in candidates:
        if (folder / "sass").exists() and _version_of([str(folder / "sass"), "--version"], r"(\d+\.\d+\.\d+)") == version:
            return folder
    folder = tools / ("dart-sass-" + version)
    if not (folder / "sass").exists():
        _download(SASS_URL.format(v=version), pinned["DART_SASS_SHA256"], folder, strip=1)
    return folder


def _retryable(error: BaseException) -> bool:
    """Whether a failed request may succeed when repeated: 5xx, 429, a timeout, a dropped connection, a body cut short.
    Any other 4xx is an answer and a certificate that does not verify is no passing fault."""
    if isinstance(error, urllib.error.HTTPError):
        return error.code >= 500 or error.code == 429
    if isinstance(error, ssl.SSLCertVerificationError):
        return False
    if isinstance(error, urllib.error.URLError) and isinstance(error.reason, ssl.SSLCertVerificationError):
        return False
    return isinstance(error, (OSError, http.client.HTTPException))


def _fetch(url: str, archive: Path) -> None:
    """One try at url, into archive, with a timeout on every read; a body shorter than Content-Length is an error."""
    with urllib.request.urlopen(url, timeout=REQUEST_TIMEOUT) as response, archive.open("wb") as out:
        shutil.copyfileobj(response, out)
        expected = response.headers.get("Content-Length")
        if expected is not None and expected.isdigit() and int(expected) != out.tell():
            raise http.client.IncompleteRead(b"", int(expected) - out.tell())


def _download(url: str, sha256: str, folder: Path, strip: int) -> None:
    """Fetch a pinned archive, check its checksum and unpack it into folder (dropping `strip` leading path levels)."""
    if sys.platform != "linux" or os.uname().machine not in ("x86_64", "AMD64"):
        raise BuildError("the pinned tools are linux-x86_64 archives: put the pinned hugo and sass on PATH (%s)" % url)
    folder.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=folder.parent) as scratch:
        archive = Path(scratch) / "tool.tar.gz"
        for attempt, delay in enumerate(DOWNLOAD_BACKOFF + (None,)):
            try:
                _fetch(url, archive)
                break
            except (OSError, http.client.HTTPException) as error:
                if delay is None or not _retryable(error):
                    raise
                time.sleep(delay)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != sha256:
            raise BuildError("checksum mismatch for " + url)
        unpacked = Path(scratch) / "unpacked"
        with tarfile.open(archive) as tar:
            tar.extractall(unpacked, filter="data")
        source = unpacked
        for _ in range(strip):
            (source,) = list(source.iterdir())
        shutil.rmtree(folder, ignore_errors=True)
        shutil.move(str(source), str(folder))


def make_site(tree: Path, base_url: str, env: dict[str, str], log: Path) -> Path:
    """Run the tree's own `make site` with the base URL; returns its site/public."""
    command = ["make", "site", "HUGO_FLAGS=--baseURL " + with_slash(base_url)]
    with log.open("w") as out:
        try:
            subprocess.run(command, cwd=tree, env=env, stdout=out, stderr=subprocess.STDOUT, timeout=BUILD_TIMEOUT_S,
                           check=True)
        except subprocess.CalledProcessError:
            raise BuildError("make site failed (%s)" % _tail(log)) from None
        except subprocess.TimeoutExpired:
            raise BuildError("make site took more than %d s" % BUILD_TIMEOUT_S) from None
    public = tree / "site" / "public"
    if not (public / "index.html").exists():
        raise BuildError("make site wrote no site/public/index.html")
    return public


def _tail(log: Path) -> str:
    lines = [line for line in log.read_text(errors="replace").splitlines() if line.strip()]
    return " | ".join(lines[-3:])[:400]


def sha_of(ref: str) -> str:
    return run(["git", "-C", str(ROOT), "rev-parse", ref + "^{commit}"], capture_output=True).stdout.strip()


def cache_key(ref: str, base_url: str) -> str:
    """The cache folder name of a commit built for a base URL."""
    return "%s-%s" % (sha_of(ref), hashlib.sha256(with_slash(base_url).encode()).hexdigest()[:8])


def prune(cache: Path, keep: set[str]) -> None:
    """Remove every cache entry that is not a current build (an old tag's, an old base URL's, a half-copied one)."""
    for entry in cache.iterdir() if cache.exists() else ():
        if entry.name not in keep:
            shutil.rmtree(entry, ignore_errors=True)


def write_outputs(fresh: list[str]) -> None:
    """`fresh=true` to the step outputs of GitHub Actions when set and something was built, not read from the cache."""
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a", encoding="utf-8") as out:
            out.write("fresh=%s\n" % ("true" if fresh else "false"))


def build_ref(ref: str, base_url: str, cache: Path, tools: Path, logs: Path, label: str) -> tuple[Path, bool]:
    """The built site of a commit, from the cache when its sha and base URL were built before; (folder, cached)."""
    sha = sha_of(ref)
    key = cache_key(ref, base_url)
    done = cache / key
    if done.exists():
        return done, True
    with tempfile.TemporaryDirectory(prefix="agentica-site-") as scratch:
        tree = Path(scratch) / "tree"
        tree.mkdir()
        archive = subprocess.Popen(["git", "-C", str(ROOT), "archive", "--format=tar", sha], stdout=subprocess.PIPE)
        with tarfile.open(fileobj=archive.stdout, mode="r|") as tar:
            tar.extractall(tree, filter="data")
        if archive.wait() != 0:
            raise BuildError("git archive failed")
        public = _build_tree(tree, base_url, tools, logs / (label + ".log"))
        _store(public, cache, key)
    return done, False


def build_tag(tag: str, base_url: str, cache: Path, tools: Path, logs: Path, label: str = "") -> tuple[Path, bool]:
    """build_ref of a tag, tried a second time after a failure that is not NoSite (a blip of the network)."""
    label = label or tag
    try:
        return build_ref(tag, base_url, cache, tools, logs, label)
    except NoSite:
        raise
    except (BuildError, OSError) as err:
        print("retry %-8s %s" % (label, err), flush=True)
        return build_ref(tag, base_url, cache, tools, logs, label)


def write_summary(built: dict, skipped: dict, failed: dict) -> None:
    """The versions, the tags left out and the tags that failed, to the job summary of GitHub Actions when set."""
    lines = ["## Site versions", "", "Built: " + (", ".join(built) or "none") + ", dev", ""]
    for title, tags in (("Left out", skipped), ("Failed", failed)):
        lines += ["%s: %s" % (title, ", ".join("`%s` (%s)" % kv for kv in tags.items()) or "none"), ""]
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as out:
            out.write("\n".join(lines))


def _build_tree(tree: Path, base_url: str, tools: Path, log: Path) -> Path:
    workflow = tree / ".github" / "workflows" / "pages.yml"
    if not (tree / "site" / "hugo.toml").exists() or not workflow.exists():
        raise NoSite("the tree has no site (site/hugo.toml, pages.yml)")
    return make_site(tree, base_url, tool_env(workflow.read_text(), tools), log)


def _store(public: Path, cache: Path, key: str) -> None:
    """Copy into the cache under a temporary name, then rename: a half-copied build is never read."""
    cache.mkdir(parents=True, exist_ok=True)
    partial = cache / (key + ".partial")
    shutil.rmtree(partial, ignore_errors=True)
    shutil.copytree(public, partial)
    partial.rename(cache / key)


def copy_site(source: Path, target: Path) -> None:
    shutil.copytree(source, target, symlinks=True, dirs_exist_ok=True)


def folder_size(folder: Path) -> int:
    return sum(f.stat().st_size for f in folder.rglob("*") if f.is_file())


def build(args: argparse.Namespace) -> int:
    started = time.monotonic()
    out, cache, tools = Path(args.out).resolve(), Path(args.cache).resolve(), Path(args.tools).resolve()
    root_url, root_path = with_slash(args.base_url), base_path(args.base_url)
    logs = out.parent / (out.name + "-logs")
    shutil.rmtree(logs, ignore_errors=True)
    logs.mkdir(parents=True)
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)

    built: dict[str, Path] = {}
    skipped: dict[str, str] = {}
    failed: dict[str, str] = {}
    fresh: list[str] = []
    tags = final_tags()
    for tag in tags:
        try:
            folder, hit = build_tag(tag, root_url + tag + "/", cache, tools, logs)
        except NoSite as err:
            skipped[tag] = str(err)
            print("skip %-8s %s" % (tag, err), flush=True)
            continue
        except (BuildError, OSError) as err:
            failed[tag] = str(err)
            print("FAIL %-8s %s" % (tag, err), flush=True)
            continue
        built[tag] = folder
        if not hit:
            fresh.append(tag)
        print("%-5s %-8s" % ("cache" if hit else "built", tag), flush=True)

    # Only the tags older than every built tag can be "no site" (the releases before the site existed). A newer one
    # is a tree this script misreads (a pages.yml that no longer has the pins), and must not drop out of the deploy.
    if built:
        oldest = min(map(version_key, built))
        for tag in [t for t in skipped if version_key(t) > oldest]:
            failed[tag] = skipped.pop(tag) + " (newer than a built tag)"
            print("FAIL %-8s %s" % (tag, failed[tag]), flush=True)

    keep = {cache_key(t, root_url + t + "/") for t in tags if t in built}
    if built:
        keep.add(cache_key(next(iter(built)), root_url))
    prune(cache, keep)

    # A release missing from the deploy (the root would fall back to an older one) is worse than no deploy.
    if failed or not built:
        write_summary(built, skipped, failed)
        write_outputs(fresh)
        raise BuildError("no version was built" if not built and not failed else "failed: " + ", ".join(failed))

    # dev is the working tree: master in pages.yml, which only runs from master (or a pull request).
    dev_folder = _build_tree(ROOT, root_url + "dev/", tools, logs / "dev.log")
    print("built dev", flush=True)

    latest = next(iter(built))
    root_folder, root_hit = build_tag(latest, root_url, cache, tools, logs, latest + "-root")
    if not root_hit:
        fresh.append("root")
    write_outputs(fresh)
    copy_site(root_folder, out)
    for tag, folder in built.items():
        copy_site(folder, out / tag)
    copy_site(dev_folder, out / "dev")

    selector = out / "_versions"
    selector.mkdir()
    for name in SELECTOR_FILES:
        shutil.copy(ROOT / "site" / "versions" / name, selector / name)
    (out / "versions.json").write_text(json.dumps(versions_json(list(built), True), indent=2) + "\n")
    pages = inject_selector(out, root_path)

    seconds = time.monotonic() - started
    print("\nversions: %s, dev" % ", ".join(built))
    print("left out: " + (", ".join("%s (%s)" % kv for kv in skipped.items()) or "none"))
    write_summary(built, skipped, failed)
    print("pages with the selector tags: %d; from the cache: %d of %d tags" % (pages, len(built) - len([f for f in fresh if f != "root"]), len(built)))
    print("time: %.1f s; size: %.1f MB (%s)" % (seconds, folder_size(out) / 1e6, out))
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    b = sub.add_parser("build", help="build every version into one folder")
    b.add_argument("--out", default=str(ROOT / "build" / "site-versions" / "public"))
    b.add_argument("--cache", default=str(ROOT / "build" / "site-versions" / "cache"))
    tools = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "agentica-site-tools"
    b.add_argument("--tools", default=str(tools), help="where downloaded hugo and sass are kept")
    b.add_argument("--base-url", default="http://localhost:8000/", help="where the root of the output is served")
    b.set_defaults(run=build)
    args = parser.parse_args(argv)
    try:
        return args.run(args)
    except BuildError as err:
        print("error: %s" % err, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
