def main() -> Void
  puts(Digest.sha256([1, 2]).size)
  puts(Digest.sha256([1, 256, 3]))
end
