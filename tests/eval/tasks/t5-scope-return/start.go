package main

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
)

func classify(n int) string {
	if n < 0 {
		return "negative"
	} else if n == 0 {
		return "zero"
	} else if n > 0 {
		return "positive"
	}
}

func main() {
	negatives := 0
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		n, _ := strconv.Atoi(line)
		label := classify(n)
		fmt.Println(label)
		if label == "negative" {
			negatives = negatives + 1
			negatives := negatives
		}
		last := n
	}
	fmt.Println("negatives: " + strconv.Itoa(negatives))
	fmt.Println(last)
}
