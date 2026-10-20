# A terminal with no callback gives way to other tasks: the spawned pipeline never ends, main still gets its turns,
# and the end of main cancels the pipeline.
def endless(skip: Int) -> Result[List[Int]]
  return (0..9000000000000000000).lazy.drop(skip).to_a
end

def main() -> Void
  t = Task.spawn(&endless, 9000000000000000000)
  total = 0
  i = 0
  while i < 3000
    total += i
    i += 1
  end
  puts("main ran beside the pipeline: #{total}")
end
