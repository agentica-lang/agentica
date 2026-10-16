import Reports from "lib/default_reports"

def main() -> Void
  puts(Reports.title("year"))
  puts(Reports.title("year", Reports.Level.Loud))
  puts(Reports.render)
  puts(Reports.render("custom", 3))
  Reports.each_row("rows") do |row|
    puts(row)
  end
end
