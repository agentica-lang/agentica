def main() -> Void
  me = System.pid()
  puts(me > 0)
  puts(System.pid() == me)
  puts(String.from_int(me).length > 0)
end
