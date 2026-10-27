# A seed of make vm-libfuzz-run: one 32 MB line on stdout, past the part the fuzzer's
# comparison hashes, which it must count, not keep (vm/fuzz_libfuzzer.c).
def main() -> Void
  line = "x"
  i = 0
  while i < 25
    line = line + line
    i += 1
  end
  puts(line)
end
