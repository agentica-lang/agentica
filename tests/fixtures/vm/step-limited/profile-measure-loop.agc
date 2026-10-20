# A loop that only calls Profile.measure stops at the step limit: each call of the block counts a step.
def main() -> Void
  puts("start")
  total = 0
  while true
    total = Profile.measure("spin") do total + 1 end
  end
end
