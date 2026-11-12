def main() -> Void
  me = System.pid()
  puts(me > 0)
  puts(System.pid() == me)
  puts(me.to_s.length > 0)
end
