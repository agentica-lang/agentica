import UI from "lib"

struct Config
  port: Int
end

def main() -> Void
  puts(UI.with(1))
  puts(UI.plain())
end
