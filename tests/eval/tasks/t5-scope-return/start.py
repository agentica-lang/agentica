import sys


def classify(n):
    if n < 0:
        return "negative"
    elif n == 0:
        return "zero"
    elif n > 0:
        return "positive"


def main():
    negatives = 0
    for line in sys.stdin.read().split("\n"):
        if not line.strip():
            continue
        n = int(line)
        label = classify(n)
        print(label)
        if label == "negative":
            negatives += 1
            last = n
    print("negatives: " + str(negatives))
    print(last)


main()
