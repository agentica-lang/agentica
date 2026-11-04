# A loop that only calls Profile.measure stops at the step limit: each call of the block counts a step.
def main() -> Void
  puts("start")
  _total = 0
  while true
    _total = Profile.measure("spin") do _total + 1 end
  end
end
