"""Hand-made packages for the tests of the manager (docs/future/45-packages.md, phase 45a).

There is no fetching yet, so a test fills the package cache itself. `package_hash` is the hash rule of 45.6 written
again with hashlib and os.walk, as a second implementation to check the Agentica one against.
"""
import hashlib
import json
import os
from pathlib import Path

from tests.agentica_test import WINDOWS

COMMIT = "a" * 40


def package_hash(folder):
    """sha256: and the hex SHA-256 of: for each .agc file in bytewise order of its path from `folder` (written with "/"),
    the path, a zero byte, the size in decimal, a zero byte and the bytes. Hidden folders and the agc_libs folder at
    the root are left out."""
    folder = Path(folder)
    paths = []
    for directory, names, files in os.walk(folder):
        relative = Path(directory).relative_to(folder)
        root = str(relative) == "."
        names[:] = [name for name in names if not name.startswith(".") and not (root and name == "agc_libs")]
        paths += [(relative / name).as_posix() for name in files if name.endswith(".agc")]
    digest = hashlib.sha256()
    for path in sorted(paths, key=lambda text: text.encode("utf-8")):
        data = (folder / path).read_bytes()
        digest.update(path.encode("utf-8") + b"\0" + str(len(data)).encode() + b"\0" + data)
    return "sha256:" + digest.hexdigest()


def cache_path(git):
    """The part of the cache path for a git URL: host/owner/repo, with no scheme and no .git."""
    rest = git[len("https://"):]
    return rest[:-len(".git")] if rest.endswith(".git") else rest


def dependency(git, tag=None, ref=None):
    """A dependency of a manifest, as the inline table the manifest writes."""
    entry = {"git": git}
    if tag is not None:
        entry["tag"] = tag
    if ref is not None:
        entry["ref"] = ref
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

    def folder(self, git, commit=COMMIT):
        """Where the cache keeps one commit of a package."""
        return self.pkg_root / cache_path(git) / commit

    def add_package(self, name, git, files, tag=None, ref=None, dependencies=None, commit=COMMIT):
        """Writes the files of a package into the cache, with the agentica.toml that declares `dependencies` when
        there are any, and notes its entry for the lock. A package is pinned by `tag`, or by `ref` when it has no tag."""
        folder = self.folder(git, commit)
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

    def write_lock(self, edit=None):
        """Writes agentica.lock from the packages added so far, sorted by name; `edit` may change the entries first."""
        entries = sorted((dict(entry) for entry in self.locked), key=lambda entry: entry["name"])
        if edit:
            edit(entries)
        text = "version = 1\n"
        for entry in entries:
            text += "\n[[package]]\n"
            order = ["name", "git", "tag", "ref", "commit", "hash"]
            for key in order + [key for key in entry if key not in order]:
                if key in entry:
                    text += "%s = %s\n" % (key, json.dumps(entry[key]))
        (self.project / "agentica.lock").write_text(text, encoding="utf-8")

    def write_manifest(self, dependencies, extra=""):
        """Writes agentica.toml with these {name: dependency} entries and any text after them."""
        (self.project / "agentica.toml").write_text(manifest_text(dependencies, extra), encoding="utf-8")
