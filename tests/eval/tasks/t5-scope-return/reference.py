import sys

negatives = 0
for line in sys.stdin.read().split("\n"):
    if not line.strip():
        continue
    n = int(line)
    label = "negative" if n < 0 else "zero" if n == 0 else "positive"
    print(label)
    if label == "negative":
        negatives += 1
print("negatives: " + str(negatives))
