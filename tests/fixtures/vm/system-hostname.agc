def main() -> Void
  name = System.hostname().unwrap!
  puts(name.length > 0)
  puts(System.hostname().unwrap! == name)
end
