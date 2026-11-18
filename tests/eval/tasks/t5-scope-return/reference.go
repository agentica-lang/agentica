package main

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
)

func classify(n int) string {
	switch {
	case n < 0:
		return "negative"
	case n == 0:
		return "zero"
	default:
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
		n, err := strconv.Atoi(line)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		label := classify(n)
		fmt.Println(label)
		if label == "negative" {
			negatives++
		}
	}
	fmt.Println("negatives: " + strconv.Itoa(negatives))
}
