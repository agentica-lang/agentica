import CacheFiles from "../../../compiler/io/cache_files"

# The C compiler that the bytecode cache keys, then what a start of the same name runs, as a native build starts it:
# the probe's line, or "error" and why (tests/test_prop_cache_compiler.py).
def main() -> Void
  system = System.os()
  puts(CacheFiles.compiler_path(system))
  name = CacheFiles.compiler_words(system)[0]
  case Process.spawn_captured(name, [])
    ok(child) ->
      output = Process.output(child, 10000)
      Process.close(child)
      if output.ok?
        puts("ran #{output.unwrap!.stdout.strip}")
      else
        puts("error #{output.message}")
      end
    error(message) -> puts("error #{message}")
  end
end
