import sys

counts = {}
for line in sys.stdin.read().split("\n"):
    line = line.strip()
    if not line:
        continue
    for word in line.lower().split(" "):
        counts[word] = counts.get(word, 0) + 1
for word, n in counts.items():
    print(word + " " + str(n))
