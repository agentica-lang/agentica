OPEN = [1].map do |n|
  jobs: Channel[Int] = Channel.new(n)
  Channel.closed?(jobs)
end

def main() -> Void
  puts(OPEN)
end
