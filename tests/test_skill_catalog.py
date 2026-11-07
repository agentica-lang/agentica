"""The programming skill against the builtin catalog.

The site examples run in CI; the programming skill (.agents/skills/agentica-programming) is only read, so a rename of
a builtin could leave it stale. This test reads every code block and every `code span` of the skill, takes each
builtin name it writes (`Namespace.fn`, `Family.Member.fn` and `Family.Member`, with a capitalized namespace) and checks
it against the catalog of the binary (`agentica help --json`, and `agentica help NAME` for the Ruby aliases such as
`String.strip`). A namespace that is no builtin one must be declared or imported in the skill (`import HTTP from
"std/http"`, `struct User`) or be in IGNORED_NAMESPACES; a name the skill shows on purpose as one that does not exist
is in IGNORED_NAMES.
"""
import json
import re
from functools import lru_cache

from tests.agentica_test import ROOT, cli, run

SKILL = ROOT / ".agents" / "skills" / "agentica-programming"

# Namespaces of the examples that are neither builtins nor declared in a code block of the skill.
IGNORED_NAMESPACES = {
    "Alias",  # Alias.f, the form of a call through an import alias
    "Checked",  # fields of std/analysis results in prose
    "Enumerator",  # Ruby's Enumerator.new, shown as what to avoid
    "Hash",  # Ruby's Hash.new, shown as what to avoid
    "Shape",  # a struct of a prose example (Shape.codec)
    "Struct",  # Ruby's Struct.new, and Type.size of a prose example
    "TypeAt",  # fields of std/analysis results in prose
    "Url",  # a module of a prose example
    "Workspace",  # fields of std/analysis results in prose
}

# Names the skill shows on purpose as ones that do not exist, with the builtin to use instead.
IGNORED_NAMES = {"IO.read_all", "Map.new", "JSON.codec", "File.extname"}

FENCE = re.compile(r"^```.*?^```", re.S | re.M)
SPAN = re.compile(r"`([^`\n]+)`")
# Namespace.name with an optional third part; not after a word, a dot, `::` (Ruby's OpenSSL::HMAC), `&` or `@`.
REFERENCE = re.compile(
    r"(?<![\w.:@&$])([A-Z][A-Za-z0-9]*)\.([A-Za-z_][A-Za-z0-9_]*[?!]?)(?:\.([A-Za-z_][A-Za-z0-9_]*[?!]?))?"
)
DECLARED = re.compile(r"\b(?:import|enum|struct|type|resource)\s+([A-Z][A-Za-z0-9]*)")


@lru_cache(maxsize=None)
def catalog():
    """The names of the public builtins."""
    result = run(cli() + ["help", "--json"])
    assert result.code == 0, result.stderr
    return frozenset(entry["name"] for entry in json.loads(result.stdout))


@lru_cache(maxsize=None)
def known_alias(name):
    """True when `agentica help NAME` knows the name: a builtin or a Ruby alias of one (`String.strip`)."""
    return run(cli() + ["help", name]).code == 0


def code_of(text):
    """The code blocks and the code spans of a Markdown text."""
    return [block.group(0) for block in FENCE.finditer(text)] + SPAN.findall(FENCE.sub("", text))


def stale_names(texts, declared=frozenset()):
    """The builtin names the texts write that the catalog lacks, sorted."""
    names = catalog()
    namespaces = {name.split(".")[0] for name in names if "." in name}
    families = {name.split(".")[0] for name in names if name.count(".") == 2}
    members = {name.rsplit(".", 1)[0] for name in names if name.count(".") == 2}
    found = set()
    for text in texts:
        for match in REFERENCE.finditer(text):
            namespace, second, third = match.groups()
            if len(namespace) == 1 or namespace in declared or namespace in IGNORED_NAMESPACES:
                continue
            if namespace.isupper() and namespace not in namespaces:
                continue  # a module constant, NAME.size
            if second[0].isupper():
                # Family.Member or Family.Member.fn; another Type.Name is an enum variant or a type (LogLevel.Info,
                # C.Pointer), which the checker owns.
                member = "%s.%s" % (namespace, second)
                if namespace in families and member not in members:
                    found.add(member)
                elif namespace in families and third and "%s.%s" % (member, third) not in names:
                    found.add("%s.%s" % (member, third))
            elif namespace not in namespaces:
                found.add("%s.%s" % (namespace, second))
            else:
                name = "%s.%s" % (namespace, second)
                if name not in names and name not in IGNORED_NAMES and not known_alias(name):
                    found.add(name)
    return sorted(found)


def test_every_builtin_name_of_the_programming_skill_is_in_the_catalog():
    files = sorted(SKILL.rglob("*.md"))
    assert files
    texts = {path: path.read_text(encoding="utf-8") for path in files}
    declared = frozenset(name for text in texts.values() for name in DECLARED.findall(text))
    stale = {
        str(path.relative_to(ROOT)): names
        for path, text in texts.items()
        if (names := stale_names(code_of(text), declared))
    }
    assert stale == {}


def test_an_old_or_misspelled_builtin_name_is_stale():
    text = "\n".join(
        [
            "Write `OpenSSL.Cipher.aes_256_gcm_encrypt(key, iv, data)`, `OpenSSL.Random.uuid` or `s.strip`.",
            "```agentica",
            "sealed = Cipher.aes_256_gcm_encrypt(key, iv, data)",
            "mac = OpenSSL.Hmac.sha256(key, data)",
            "digest = OpenSSL.Digest.sha257(data)",
            "```",
        ]
    )
    assert stale_names(code_of(text)) == [
        "Cipher.aes_256_gcm_encrypt",
        "OpenSSL.Digest.sha257",
        "OpenSSL.Hmac",
    ]
