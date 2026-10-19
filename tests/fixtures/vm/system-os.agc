def main() -> Void
  os = System.os()
  puts(os == "linux" or os == "macos" or os == "windows")
  puts(System.os() == os)
  puts(String.downcase(os) == os)
end
