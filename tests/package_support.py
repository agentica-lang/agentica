"""Packages for the tests of the manager (docs/future/45-packages.md, phases 45a to 45c).

`Workspace` fills the deps/ folder of the project by hand (a build reads packages only from there); `Remotes` makes git repositories that `agentica install`, `add` and
`update` fetch from. `package_hash` is the hash rule of docs/grammar/05b-modules.md written again with hashlib and
os.walk, as a second implementation to check the Agentica one against.
"""
import hashlib
import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

from tests.agentica_test import WINDOWS, cli, run, tool, vm_environment

COMMIT = "a" * 40

# A package that imports another one, and a program that imports it, for the tests that fetch.
GREET = 'import Tools from "pkg/tools/bang"\n\nexport def hello() -> String\n  return "hello" + Tools.bang()\nend\n'
BANG = 'export def bang() -> String\n  return "!"\nend\n'
MAIN = 'import Greet from "pkg/greeter/greet"\n\ndef main() -> Void\n  puts(Greet.hello())\nend\n'


def package_hash(folder):
    """sha256: and the hex SHA-256 of: for each .agc file in bytewise order of its path from `folder` (written with "/"),
    the path, a zero byte, the size in decimal, a zero byte and the bytes. Hidden folders and the agc_libs folder at
    the root are left out. The `.agc` extension and the name agc_libs are compared without regard to case."""
    folder = Path(folder)
    paths = []
    for directory, names, files in os.walk(folder):
        relative = Path(directory).relative_to(folder)
        root = str(relative) == "."
        names[:] = [name for name in names if not name.startswith(".") and not (root and name.lower() == "agc_libs")]
        paths += [(relative / name).as_posix() for name in files if name.lower().endswith(".agc")]
    digest = hashlib.sha256()
    for path in sorted(paths, key=lambda text: text.encode("utf-8")):
        data = (folder / path).read_bytes()
        digest.update(path.encode("utf-8") + b"\0" + str(len(data)).encode() + b"\0" + data)
    return "sha256:" + digest.hexdigest()


def cache_path(git):
    """The part of the cache path for a git URL: host/owner/repo, with no scheme and no .git."""
    rest = git[len("https://"):]
    return rest[:-len(".git")] if rest.endswith(".git") else rest


def dependency(git, tag=None, ref=None, subdir=None):
    """A dependency of a manifest, as the inline table the manifest writes."""
    entry = {"git": git}
    if tag is not None:
        entry["tag"] = tag
    if ref is not None:
        entry["ref"] = ref
    if subdir is not None:
        entry["subdir"] = subdir
    return entry


def inline_table(entry):
    return "{ " + ", ".join('%s = "%s"' % pair for pair in entry.items()) + " }"


def manifest_text(dependencies, extra=""):
    """The text of an agentica.toml with these {name: dependency} entries and any text after them."""
    text = 'name = "app"\n\n[dependencies]\n'
    text += "".join("%s = %s\n" % (name, inline_table(entry)) for name, entry in dependencies.items())
    return text + extra


class Workspace:
    """A project folder and a package cache folder, both inside `base`."""

    def __init__(self, base):
        self.base = Path(base)
        self.cache = self.base / "cache"
        self.project = self.base / "project"
        self.project.mkdir(parents=True)
        self.locked = []

    @property
    def pkg_root(self):
        """The cache root: $XDG_CACHE_HOME/agentica/pkg, or %LOCALAPPDATA%/agentica/cache/pkg on Windows. self.cache is
        the value of the variable that the system reads (`cache_variables`)."""
        return self.cache / "agentica" / "cache" / "pkg" if WINDOWS else self.cache / "agentica" / "pkg"

    @property
    def cache_variables(self):
        """The environment that points the compiler at self.cache: the system reads one of the two variables."""
        return {"LOCALAPPDATA": str(self.cache)} if WINDOWS else {"XDG_CACHE_HOME": str(self.cache)}

    @property
    def deps(self):
        """The deps/ folder of the project, where a build reads the packages."""
        return self.project / "deps"

    def folder(self, git, commit=COMMIT, subdir=""):
        """Where the cache keeps one commit of a package; a folder of the repository (`subdir`) has the folder
        `<commit>@<subdir with / written @>`."""
        return self.pkg_root / cache_path(git) / (commit + "".join("@" + part for part in subdir.split("/") if part))

    def add_package(self, name, git, files, tag=None, ref=None, dependencies=None, commit=COMMIT):
        """Writes the files of a package into `deps/<name>`, with the agentica.toml that declares `dependencies` when
        there are any, and notes its entry for the lock. A package is pinned by `tag`, or by `ref` when it has no tag."""
        folder = self.deps / name
        for relative, text in files.items():
            path = folder / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(text if isinstance(text, bytes) else text.encode("utf-8"))
        if dependencies is not None:
            (folder / "agentica.toml").write_text(manifest_text(dependencies), encoding="utf-8")
        if tag is None and ref is None:
            tag = "v1.0.0"
        entry = {"name": name, "git": git, "commit": commit, "hash": package_hash(folder)}
        entry.update({"tag": tag} if ref is None else {"ref": ref})
        self.locked.append(entry)
        return entry

    def lock_text(self, edit=None):
        """The text of agentica.lock for the packages added so far, sorted by name; `edit` may change the entries
        first. It is the layout of docs/grammar/05b-modules.md, which `agentica add` and `update` also write."""
        entries = sorted((dict(entry) for entry in self.locked), key=lambda entry: entry["name"])
        if edit:
            edit(entries)
        text = "version = 1\n"
        for entry in entries:
            text += "\n[[package]]\n"
            order = ["name", "git", "subdir", "tag", "ref", "commit", "hash"]
            for key in order + [key for key in entry if key not in order]:
                if key in entry:
                    text += "%s = %s\n" % (key, json.dumps(entry[key]))
        return text

    def write_lock(self, edit=None):
        """Writes agentica.lock from the packages added so far."""
        (self.project / "agentica.lock").write_text(self.lock_text(edit), encoding="utf-8")

    def write_manifest(self, dependencies, extra=""):
        """Writes agentica.toml with these {name: dependency} entries and any text after them."""
        (self.project / "agentica.toml").write_text(manifest_text(dependencies, extra), encoding="utf-8")


class Remotes:
    """Bare git repositories in a temporary folder that stand in for `https://example.test/` (docs/future/45-packages.md,
    45.11). The HOME of the process has a .gitconfig whose `url.<base>.insteadOf` sends that host to the folder, so the
    manifest and the lock keep the https URL and no test reaches the network, and no real git config is read."""

    HOST = "https://example.test/"

    def __init__(self, base):
        base = Path(base)
        self.root = base / "remotes"
        self.work = base / "work"
        self.home = base / "githome"
        self.home.mkdir(parents=True)
        self.root.mkdir()
        self.work.mkdir()
        (self.home / ".gitconfig").write_text(
            '[url "%s/"]\n\tinsteadOf = %s\n' % (self.root.as_uri(), self.HOST), encoding="utf-8")

    @property
    def environment(self):
        """What a process needs so that git reads only this HOME, and never asks a terminal for a password."""
        return {"HOME": str(self.home), "XDG_CONFIG_HOME": str(self.home / "config"), "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": str(self.home / ".gitconfig"), "GIT_TERMINAL_PROMPT": "0",
                "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.test", "GIT_COMMITTER_NAME": "t",
                "GIT_COMMITTER_EMAIL": "t@example.test", "GIT_DIR": None, "GIT_WORK_TREE": None,
                "GIT_INDEX_FILE": None}

    def url(self, path):
        """The https URL of a repository `owner/repo`, as a manifest writes it."""
        return self.HOST + path

    def git(self, *arguments, cwd, stdin=None):
        """Runs git with the isolated environment and returns its stripped stdout; `stdin` is bytes fed to it."""
        env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        env.update({key: value for key, value in self.environment.items() if value is not None})
        done = subprocess.run(["git", *arguments], cwd=str(cwd), env=env, capture_output=True, input=stdin)
        assert done.returncode == 0, (arguments, done.stderr)
        return done.stdout.decode("utf-8").strip()

    def tree(self, entries, cwd):
        """Writes the tree object of `entries` ({name: (mode, type, object id or bytes)}, where bytes become a blob)."""
        lines = []
        for name, (mode, kind, content) in entries.items():
            if isinstance(content, bytes):
                content = self.git("hash-object", "-w", "--stdin", cwd=cwd, stdin=content)
            lines.append("%s %s %s\t%s\n" % (mode, kind, content, name))
        return self.git("mktree", cwd=cwd, stdin="".join(lines).encode("utf-8"))

    def publish(self, path, files, tag=None, annotated=True, links=None, gitlinks=None):
        """Commits `files` ({path: bytes or str}) as the whole tree of the repository `owner/repo`, tags the commit
        (`tag`, annotated unless told otherwise) and pushes it to the bare repository. `links` maps a path to the target
        of a symbolic link, and `gitlinks` the paths of submodule entries (mode 160000). Returns the commit.

        The tree is built with git plumbing (blobs and trees), never through a working folder, so names that differ
        only in case stay two entries on a case-insensitive file system (the default of macOS and Windows)."""
        work = self.work / path
        bare = self.root / path
        if not work.exists():
            work.mkdir(parents=True)
            self.git("init", "--quiet", "--initial-branch=main", cwd=work)
            self.git("init", "--bare", "--quiet", str(bare), cwd=self.work)
            self.git("remote", "add", "origin", str(bare), cwd=work)
        leaves = {name: ("100644", "blob", content if isinstance(content, bytes) else content.encode("utf-8"))
                  for name, content in files.items()}
        leaves.update({name: ("120000", "blob", target.encode("utf-8")) for name, target in (links or {}).items()})
        leaves.update({name: ("160000", "commit", "1" * 40) for name in gitlinks or []})
        root = {}
        for name, leaf in leaves.items():
            *folders, last = name.split("/")
            folder = root
            for part in folders:
                folder = folder.setdefault(part, {})
            folder[last] = leaf

        def write(node):
            entries = {name: ("040000", "tree", write(child)) if isinstance(child, dict) else child
                       for name, child in node.items()}
            return self.tree(entries, work)

        # A first publish has no HEAD yet; later ones chain, so the same files published twice are two commits.
        has_head = (work / ".git" / "refs" / "heads" / "main").exists()
        parent = self.git("rev-parse", "HEAD", cwd=work) if has_head else ""
        commit = self.git("commit-tree", write(root), *(["-p", parent] if parent else []), "-m", "release", cwd=work)
        self.git("update-ref", "HEAD", commit, cwd=work)
        pushed = ["push", "--quiet", "--force", "origin", "HEAD:refs/heads/main"]
        if tag is not None:
            self.git(*(["tag", "-f", "-a", "-m", tag] if annotated else ["tag", "-f"]), tag, cwd=work)
            pushed.append("refs/tags/" + tag)
        self.git(*pushed, cwd=work)
        return commit


def lock_entry(ws, remotes, path, files, commit, tag=None, ref=None, name=None, subdir=None):
    """Notes the lock entry of a package whose files the remote holds. The hash comes from the Python implementation of
    the hash rule, over a scratch copy of the .agc files. For a package that is a folder of the repository (`subdir`),
    `files` are the files of that folder, with paths relative to it, and `name` is required."""
    scratch = ws.base / ("scratch-" + (name or path).replace("/", "-"))
    shutil.rmtree(scratch, ignore_errors=True)
    for relative, content in files.items():
        if relative.endswith(".agc"):
            (scratch / relative).parent.mkdir(parents=True, exist_ok=True)
            (scratch / relative).write_bytes(content if isinstance(content, bytes) else content.encode("utf-8"))
    entry = {"name": name or path.split("/")[1], "git": remotes.url(path), "commit": commit,
             "hash": package_hash(scratch) if scratch.exists() else package_hash(ws.base)}
    if subdir is not None:
        entry["subdir"] = subdir
    entry.update({"tag": tag} if ref is None else {"ref": ref})
    ws.locked.append(entry)
    return entry


def environment(ws, remotes, **extra):
    return vm_environment({"AGENTICA_PATH": "", **ws.cache_variables, **remotes.environment, **extra})


def run_json(command, ws, remotes, *words, **extra):
    """The result of `--json COMMAND` in the project folder, and the problem it reported, or None for a success."""
    result = run(cli() + ["--json", command, *words], cwd=ws.project, env=environment(ws, remotes, **extra))
    if result.code == 0:
        assert result.stdout == '{"ok":true}\n'
        return result, None
    return result, json.loads(result.stderr) if result.code == 1 else None


def command(ws, remotes, *words, **extra):
    """The result of `--json WORDS` in the project folder, and the problem it reported (None for a success)."""
    result = run(cli() + ["--json", *words], cwd=ws.project, env=environment(ws, remotes, **extra))
    return result, json.loads(result.stderr) if result.code == 1 else None


def problem_of(ws, remotes, **extra):
    """The problem that `--json check` reports for main.agc of the project, or None."""
    return command(ws, remotes, "check", str(ws.project / "main.agc"), **extra)[1]


def assert_at_key(problem, code, file, key_path):
    assert problem["code"] == code
    assert Path(problem["file"]) == Path(file)
    assert problem.get("key_path", "") == key_path


def cached_files(folder):
    return sorted(path.relative_to(folder).as_posix() for path in folder.rglob("*") if path.is_file())


@pytest.fixture
def git():
    return tool("git")


@pytest.fixture
def remotes(tmp_path, git):
    return Remotes(tmp_path)


@pytest.fixture
def ws(tmp_path):
    return Workspace(tmp_path)
