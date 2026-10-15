CONFIG = Config(port: 80)

struct Config
  port: Int
end

def main() -> Void
  updated = CONFIG.with()
end
