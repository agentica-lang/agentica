import Logger from "std/logger"

# time_text halts on an instant before the year 1, as Time.at_us(...).unwrap! does.
def main() -> Void
  puts(Logger.time_text(-62135596800000))
  puts(Logger.time_text(-62135596800001))
end
