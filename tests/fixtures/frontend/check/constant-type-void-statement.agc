NOTHING = [1].map do |n|
  [n].each do |m| m end
  n
end

def main() -> Void
  puts(NOTHING)
end
