package main

import (
	"bufio"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
)

type Entry struct {
	Student string
	Subject string
	Score   int
}

type Totals struct {
	Sum    int
	Weight int
}

func average(totals Totals) int {
	return totals.Sum / totals.Weight
}

func addScore(totals Totals, score, weight int) Totals {
	return Totals{Sum: totals.Sum + score*weight, Weight: totals.Weight + weight}
}

func letter(avg int) string {
	switch {
	case avg >= 90:
		return "A"
	case avg >= 80:
		return "B"
	case avg >= 70:
		return "C"
	case avg >= 60:
		return "D"
	}
	return "F"
}

func main() {
	var entries []Entry
	weights := map[string]int{}
	reader := bufio.NewReader(os.Stdin)
	for {
		raw, err := reader.ReadString('\n')
		if line := strings.TrimSpace(raw); line != "" {
			parts := strings.Split(line, " ")
			value, _ := strconv.Atoi(parts[2])
			if parts[0] == "weight" {
				weights[parts[1]] = value
			} else {
				entries = append(entries, Entry{Student: parts[0], Subject: parts[1], Score: value})
			}
		}
		if err != nil {
			break
		}
	}
	if len(entries) == 0 {
		fmt.Println("no scores")
		return
	}
	students := map[string]Totals{}
	everyone := Totals{}
	for _, entry := range entries {
		w, found := weights[entry.Subject]
		if !found {
			w = 1
		}
		students[entry.Student] = addScore(students[entry.Student], entry.Score, w)
		everyone = addScore(everyone, entry.Score, w)
	}
	names := make([]string, 0, len(students))
	for name := range students {
		names = append(names, name)
	}
	sort.Slice(names, func(i, j int) bool {
		a, b := average(students[names[i]]), average(students[names[j]])
		if a != b {
			return a > b
		}
		return names[i] < names[j]
	})
	for rank, name := range names {
		avg := average(students[name])
		fmt.Printf("%d. %s: %d %s\n", rank+1, name, avg, letter(avg))
	}
	fmt.Printf("class: %d\n", average(everyone))
}
