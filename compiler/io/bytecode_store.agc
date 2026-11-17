## Keeping a compiled program in the bytecode cache (io/bytecode_cache.agc, which says what an entry holds and reads
## one): the lines of an entry are made here from the linked modules, and the entry is written. This half needs the
## linker, so a start that only reads an entry does not load it.

import Declarations from "../modules/declarations"
import Paths from "../modules/import_path"
import Env from "../modules/link_env"
import Linker from "../modules/linker"
import Resolve from "../modules/resolve_import"
import Workspace from "../modules/workspace"
import NativePrebuilt from "../packages/native_prebuilt"
import PackageCache from "../packages/package_cache"
import Ast from "../syntax/ast"
import BytecodeCache from "bytecode_cache"
import CacheFiles from "cache_files"
import RandomName from "random_name"

## Keeps `program`, which was compiled from `modules`, as the entry of the plan. It gives false when it could not (a
## folder that is not safe or not writable); the run goes on either way. The probes are taken here, after the compile,
## so a file that appears between the two is the one gap: it is seen as present, not as absent.
def store(plan: BytecodeCache.Plan, settings: Env.Settings, modules: List[Linker.LinkedModule], program: Bytes) -> Bool
  case plan
    BytecodeCache.Plan.Off -> false
    BytecodeCache.Plan.On(entry) ->
      sources = modules.filter do |module: Linker.LinkedModule| !Resolve.embedded?(module.key) end
      probes = probe_lines(settings, entry.libs_dir, sources)
      return false if !probes.ok?

      # A module block (`module Raw ... end`) is linked as a module of its own, keyed `FILE#Raw`, which is no file: the
      # line of its file covers it.
      files = sources.select do |module: Linker.LinkedModule| module.block == "" end
      lines = files.map do |module: Linker.LinkedModule| source_line(module) end
      built = built_libraries(settings, sources, BUILD_FOLDER)
      fetched = built_libraries(settings, sources, NativePrebuilt.CACHE_FOLDER)
      libraries = library_lines(settings.workspace, sources, built.concat(fetched))
      return false if !libraries.ok?

      lines = lines.concat(libraries.unwrap!)
      if built.size > 0
        lines = lines.push(compiler_of(entry, settings))
      end

      text = [entry.key, "program #{CacheFiles.digest(program)}"].concat(lines).concat(probes.unwrap!).join("\n")
      publish(entry, text, program)
  end
end

private

# The folder of the package cache that holds the native builds (io/native_build.agc).
BUILD_FOLDER = "native-build"

def source_line(module: Linker.LinkedModule) -> String
  "#{BytecodeCache.SOURCE_WORD}#{CacheFiles.digest(module.text.bytes)} #{module.key}"
end

# One `source` line for each file that a native library of the program may come from or load (the manifest that names
# it and every file of native/), and one `tree` line for each package folder, with a digest of the names of its native/
# files, so a change or an added file makes the entry miss and the build (which hashes the package against the lock)
# runs again. A path that a `system` list of candidates chose by (module.probed) is not read: it gets the line of an
# import place, so the entry misses when the library appears, goes away or leads elsewhere, and the pick is made again.
def library_lines(
  workspace: Workspace.Workspace,
  modules: List[Linker.LinkedModule],
  built: List[String],
) -> Result[List[String]]
  paths = built
  probed: List[String] = []
  for module in modules
    paths = paths.concat(module.watched)
    probed = probed.concat(module.probed)
  end

  lines: List[String] = []
  for path in probed.uniq
    lines = lines.push(try probe(workspace, path))
  end

  for path in paths.uniq
    return error("the path has a line feed, a tab or a NUL") if !plain?(path)

    if workspace.directory_exists.call(path)
      lines = lines.push("#{BytecodeCache.TREE_WORD}#{BytecodeCache.names_digest(workspace, path)} #{path}")
    else
      read = try workspace.read_bytes.call(path)
      lines = lines.push("#{BytecodeCache.SOURCE_WORD}#{CacheFiles.digest(read)} #{path}")
    end
  end

  ok(lines)
end

# The libraries of a folder of the package cache that the extern functions of the program name: of the build cache
# (io/native_build.agc) or of the prebuilt files (io/native_prebuilt.agc). A removed or changed library makes the entry
# miss, so the module is built, or its prebuilt file checked, again.
def built_libraries(settings: Env.Settings, modules: List[Linker.LinkedModule], folder: String) -> List[String]
  base = Paths.join(PackageCache.root(settings.env), "#{folder}/")
  found: List[String] = []
  return found if base == "#{folder}/"

  for module in modules
    for decl in module.declarations
      case decl
        Ast.Decl.Function(node) ->
          case node.native
            some(native) ->
              if native.library.start_with?(base)
                found = found.push(native.library)
              end

            none -> next
          end

        _ -> next
      end
    end
  end

  found
end

# The compiler line of a program that names a built library. No other program needs it: a module that was not built
# stores no entry (NativeBuild.unbuilt_path), and without a build cache the key changes when one appears.
def compiler_of(entry: BytecodeCache.Entry, settings: Env.Settings) -> String
  return entry.compiler if entry.compiler != ""

  CacheFiles.compiler_line(settings.env.os)
end

# What the resolver looked at for the imports of `modules`, as lines of the entry: for a `pkg/` import, every place of
# the search (a place that holds a file is `present`, with its real path); for any other import, the path written
# beside the importing file and the real path it leads to (a link may be retargeted). std/ imports are in the binary.
# More places than the resolver took are listed (it stops at the first), which can only cost a miss.
def probe_lines(settings: Env.Settings, libs_dir: String, modules: List[Linker.LinkedModule]) -> Result[List[String]]
  workspace = settings.workspace
  roots: List[String] = []
  searched = false
  lines: List[String] = []
  for module in modules
    for decl in Declarations.imports_of(module.parsed.declarations)
      file = "#{decl.path}.agc"
      if file.start_with?("std/")
        next
      elsif file.start_with?("pkg/")
        if !searched
          roots = try Resolve.search_roots(settings, libs_dir)
          searched = true
        end

        for root in roots
          lines = lines.push(try probe(workspace, Paths.join(root, file.slice(4, file.length - 4))))
        end
      else
        lines = lines.push(try probe(workspace, Paths.join(Paths.directory_of(module.key), file)))
      end
    end
  end

  ok(lines.uniq)
end

# The line for one place. A path with a line feed or a tab would break the lines; it keeps the entry from being made.
def probe(workspace: Workspace.Workspace, path: String) -> Result[String]
  return error("the path has a line feed, a tab or a NUL") if !plain?(path)

  return ok("#{BytecodeCache.ABSENT_WORD}#{path}") if !workspace.file_exists.call(path)

  real = try workspace.real_path.call(path)
  return error("the path has a line feed, a tab or a NUL") if !plain?(real)

  ok("#{BytecodeCache.PRESENT_WORD}#{path}\t#{real}")
end

def plain?(path: String) -> Bool
  !path.include?("\n") and !path.include?("\t") and !path.include?(String.from_code(0))
end

# Writes the entry to a new private file beside its place under a name nobody can guess, and renames it there. A
# rename never replaces (Path.rename), so the old entry is removed first: a reader that comes in between finds none,
# which is a miss, and a run that dies in between leaves no entry. A file system that cannot rename without replacing
# (the rename then fails) never gets an entry; the run is not affected. A `_build/` made by the cache gets a
# .gitignore of its own, so the bytecode is not committed by mistake.
def publish(entry: BytecodeCache.Entry, text: String, program: Bytes) -> Bool
  return false if !prepare_folder(entry).ok?

  CacheFiles.sweep(entry.folder)
  suffix = RandomName.hex()
  return false if !suffix.ok?

  body = text.bytes
  data = Bytes.concat([BytecodeCache.head(body.size).bytes, body, program])
  temporary = Paths.join(entry.folder, "#{Paths.last_part(entry.file)}.tmp-#{suffix.unwrap!}")
  CacheFiles.install(temporary, data, entry.file)
end

# Both folders must be ones this program may trust (private_kind), or be made now. The .gitignore goes in `_build/`
# when the cache makes it there.
def prepare_folder(entry: BytecodeCache.Entry) -> Result[Void]
  user = try CacheFiles.own_user()
  made = try CacheFiles.private_folder(entry.build, user)
  if made and entry.beside
    _ = CacheFiles.write_private(Paths.join(entry.build, ".gitignore"), "*\n".bytes)
  end

  try CacheFiles.private_folder(entry.folder, user)
  ok()
end
