"""Hand-made packages for the tests of the manager (docs/future/45-packages.md, phase 45a).

There is no fetching yet, so a test fills the package cache itself. `package_hash` is the hash rule of 45.6 written
again with hashlib and os.walk, as a second implementation to check the Agentica one against.
"""
import hashlib
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


def host_path(key):
    """The part of the cache path for a key: GitHub keys have no host, so they get github.com."""
    return key if "." in key.split("/")[0] else "github.com/" + key


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

    def folder(self, key, commit=COMMIT):
        """Where the cache keeps one commit of a package."""
        return self.pkg_root / host_path(key) / commit

    def add_package(self, key, version, files, requires=(), commit=COMMIT):
        """Writes the files of a package into the cache and notes its entry for the lock."""
        folder = self.folder(key, commit)
        for name, text in files.items():
            path = folder / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(text if isinstance(text, bytes) else text.encode("utf-8"))
        entry = {"name": key, "version": version, "source": "https://%s.git" % host_path(key), "commit": commit,
                 "hash": package_hash(folder), "requires": list(requires)}
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
            for key in ["name", "version", "source", "commit", "hash"]:
                if key in entry:
                    text += '%s = "%s"\n' % (key, entry[key])
            if "requires" in entry:
                text += "requires = [%s]\n" % ", ".join('"%s"' % item for item in entry["requires"])
        (self.project / "agentica.lock").write_text(text, encoding="utf-8")

    def write_manifest(self, dependencies, extra=""):
        """Writes agentica.toml with these {key: minimum} dependencies and any text after them."""
        text = 'name = "me/app"\nversion = "0.1.0"\n\n[dependencies]\n'
        text += "".join('"%s" = "%s"\n' % pair for pair in dependencies.items())
        (self.project / "agentica.toml").write_text(text + extra, encoding="utf-8")
