package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

func main() {
	counts := map[string]int{}
	var order []string
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		for _, word := range strings.Split(strings.ToLower(line), " ") {
			if _, seen := counts[word]; !seen {
				order = append(order, word)
			}
			counts[word]++
		}
	}
	for _, word := range order {
		fmt.Printf("%s %d\n", word, counts[word])
	}
}
