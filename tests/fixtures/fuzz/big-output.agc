# A seed of make vm-libfuzz-run: 3.2 GB on stdout in a few hundred steps, which the
# fuzzer's comparison must hash, not keep (vm/fuzz_libfuzzer.c).
def main() -> Void
  line = "x"
  i = 0
  while i < 25
    line = line + line
    i += 1
  end
  i = 0
  while i < 100
    puts(line)
    i += 1
  end
end
