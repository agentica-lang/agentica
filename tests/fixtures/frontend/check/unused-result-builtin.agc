def main() -> Void
  file = File.open("data.txt", "read", 1000).unwrap!
  File.close(file, 1000)
end
