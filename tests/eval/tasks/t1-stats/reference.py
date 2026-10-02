import sys

nums = [int(line) for line in sys.stdin.read().split("\n") if line.strip()]
print("count: " + str(len(nums)))
print("sum: " + str(sum(nums)))
print("max: " + str(max(nums)))
