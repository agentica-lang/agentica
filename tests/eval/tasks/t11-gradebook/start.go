package main

import (
	"bufio"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
)

type Totals struct {
	Sum   int
	Count int
}

func average(totals Totals) int {
	return totals.Sum / totals.Count
}

func addScore(totals Totals, score int) Totals {
	return Totals{Sum: totals.Sum + score, Count: totals.Count + 1}
}

func main() {
	students := map[string]Totals{}
	everyone := Totals{}
	reader := bufio.NewReader(os.Stdin)
	for {
		raw, err := reader.ReadString('\n')
		if line := strings.TrimSpace(raw); line != "" {
			parts := strings.Split(line, " ")
			name := parts[0]
			score, _ := strconv.Atoi(parts[2])
			students[name] = addScore(students[name], score)
			everyone = addScore(everyone, score)
		}
		if err != nil {
			break
		}
	}
	if everyone.Count == 0 {
		fmt.Println("no scores")
		return
	}
	names := make([]string, 0, len(students))
	for name := range students {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		fmt.Printf("%s: %d\n", name, average(students[name]))
	}
	fmt.Printf("class: %d\n", average(everyone))
}
