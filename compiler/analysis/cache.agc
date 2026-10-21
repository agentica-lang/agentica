## What `Analysis.refresh` (stdlib/analysis.agc) keeps in a session between questions: the files it parsed and the
## roots it linked and checked. The cache is an immutable value; `refresh` (front.agc) gives a new one, and a question
## only reads it. Nothing in it is trusted without a look at the files: a question walks the imports of its root again
## (Modules.load_with, which reads each file but parses only a file whose text changed), and the checked program is
## used only when the walk found the same modules with the same texts. So a cache that is stale, or that belongs to
## another lineage of the same session, costs time and never gives a wrong answer.
##
## Bounds: at most MAX_ROOTS checked roots, the least recently refreshed leaving first; the parsed files are kept only
## while a kept root reaches them.
##
## Node ids: a kept file keeps its tree and so its ids, and a file parsed later gets ids above the highest one in the
## cache, so the ranges of the files never overlap, leave gaps where a file changed, and are not in walk order. When
## the highest id passes twice the ids that live files hold, `crowded?` says so and the caller parses the program again
## from 0. The checker's tables are indexed by id, so gaps cost memory, bounded by that factor.

import Ast from "../syntax/ast"
import Checker from "../check/checker"
import Linker from "../modules/linker"
import Modules from "../modules/modules"

MAX_ROOTS = 16

## A root that linked, with what checking it gave (a program or its first problem). `loaded` and `fingerprint` say
## which modules it was made from; `used` is the clock of the refresh that last wanted it.
export struct Root
  loaded: Modules.Loaded
  fingerprint: String
  linked: Linker.Linked
  checking: Checker.Checking
  used: Int
end

## The roots by the canonical key of the root file, the parsed files and the counters of the work done. `checks` counts
## the roots that `refresh` linked and checked, and `parsed` the files it lexed and parsed (a test reads them to see
## what a refresh reused).
export struct Cache
  roots: Map[String, Root]
  parses: Modules.Parses
  clock: Int
  checks: Int
  parsed: Int
end

## Whether the cache holds the checked program of a walk.
export enum Found
  Hit(Root)
  Miss
end

## A cache that holds nothing.
export def empty() -> Cache
  return Cache(roots: {}, parses: Modules.no_parses(), clock: 0, checks: 0, parsed: 0)
end

## The root that was made from the modules of `loaded` with their texts, if the cache has it.
export def find(cache: Cache, loaded: Modules.Loaded) -> Found
  key = loaded.order[0]
  if !cache.roots.has_key?(key)
    return Found.Miss
  end
  root = cache.roots[key]
  if root.fingerprint == fingerprint(loaded) and same_texts?(root.loaded, loaded)
    return Found.Hit(root)
  end
  return Found.Miss
end

## The root of a program that `loaded` gave and that linked and checked.
export def solved(loaded: Modules.Loaded, linked: Linker.Linked, checking: Checker.Checking) -> Root
  return Root(loaded: loaded, fingerprint: fingerprint(loaded), linked: linked, checking: checking, used: 0)
end

## `cache` with the files of `loaded` among the parsed ones.
export def reaching(cache: Cache, loaded: Modules.Loaded) -> Cache
  kept = cache.parses.kept
  top = cache.parses.top
  for key in loaded.order
    module = loaded.modules[key]
    kept = kept.put(key, Modules.Kept(text: module.text, first_id: module.first_id, program: module.program))
    next = Ast.next_free_id(module.program)
    if next > top
      top = next
    end
  end
  return cache.with(parses: Modules.Parses(kept: kept, top: top))
end

## `cache` with no parsed file but those of `loaded`, which was parsed from id 0: the ids of the other files may
## overlap its own now.
export def restart(cache: Cache, loaded: Modules.Loaded) -> Cache
  return reaching(cache.with(parses: Modules.no_parses()), loaded)
end

## Whether the highest id in use is above twice the ids that the parsed files hold.
export def crowded?(cache: Cache) -> Bool
  live = 0
  for file in cache.parses.kept.values
    live += Ast.next_free_id(file.program) - file.first_id
  end
  return cache.parses.top > live * 2
end

## `cache` with `root` as the root that `loaded` made, the latest used. Roots over the limit and the files that no root
## reaches are dropped. `computed` is true when `root` was linked and checked for this call.
export def remember(cache: Cache, root: Root, loaded: Modules.Loaded, computed: Bool) -> Cache
  clock = cache.clock + 1
  roots = trimmed(cache.roots.put(loaded.order[0], root.with(used: clock)))
  return pruned(
    cache.with(
      roots: roots,
      clock: clock,
      checks: counted(cache.checks, computed),
      parsed: cache.parsed + loaded.parsed,
    ),
  )
end

def counted(count: Int, one: Bool) -> Int
  if one
    return count + 1
  end
  return count
end

# The roots without the least recently used ones beyond MAX_ROOTS.
def trimmed(roots: Map[String, Root]) -> Map[String, Root]
  if roots.size <= MAX_ROOTS
    return roots
  end
  oldest = roots.keys.sort_by do |key: String| roots[key].used end
  for key in oldest.take(roots.size - MAX_ROOTS)
    roots = roots.delete(key)
  end
  return roots
end

# Keeps the parsed files that some root reaches; top is recomputed, since the file with the highest ids may be gone.
def pruned(cache: Cache) -> Cache
  kept: Map[String, Modules.Kept] = {}
  top = 0
  for root in cache.roots.values
    for key in root.loaded.order
      if cache.parses.kept.has_key?(key) and !kept.has_key?(key)
        file = cache.parses.kept[key]
        kept = kept.put(key, file)
        next = Ast.next_free_id(file.program)
        if next > top
          top = next
        end
      end
    end
  end
  return cache.with(parses: Modules.Parses(kept: kept, top: top))
end

# What a program is made of apart from the texts: the root folder and, for each module in order, its key, stored name,
# prefix, package, the keys its aliases name and the names it imports. A change in one of these (a new agentica.toml, a
# file that appeared and shadows an import) changes what the program means even when no text did. Every piece is
# written with its length, so two different lists never give one text.
def fingerprint(loaded: Modules.Loaded) -> String
  parts = [piece(loaded.root_dir)]
  for key in loaded.order
    parts = parts.push(describe(loaded.modules[key]))
  end
  return parts.join("")
end

def describe(module: Modules.Module) -> String
  origin = module.origin
  pieces = [module.key, module.name, module.prefix, origin.package, origin.root, origin.label]
  pieces = pieces.push("#{module.aliases.size}")
  for alias in module.aliases.keys.sort
    pieces = pieces.push(alias).push(module.aliases[alias])
  end
  pieces = pieces.push("#{module.named.size}")
  for local in module.named.keys.sort
    pieces = pieces.push(local).push(module.named[local].target).push(module.named[local].name)
  end
  return pieces.map do |text: String| piece(text) end.join("")
end

def piece(text: String) -> String
  return "#{text.length}:#{text}"
end

def same_texts?(kept: Modules.Loaded, loaded: Modules.Loaded) -> Bool
  for key in loaded.order
    if kept.modules[key].text != loaded.modules[key].text
      return false
    end
  end
  return true
end
