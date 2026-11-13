import Lib from "lib"
import {MAX, NAMES, LEVELS as TABLE, CONFIG} from "lib"

## The seconds of a day.
SECONDS: Int = 60 * 60 * 24

private

LIMIT = MAX + 1

def main() -> Void
  puts("#{LIMIT} #{MAX} #{Lib.double(MAX)}")
  NAMES.each do |name|
    puts(name)
  end
  puts("#{NAMES.size} #{NAMES.include?("a")} #{TABLE.get("x", 0)} #{CONFIG.port} #{TABLE["x"]}")
end
