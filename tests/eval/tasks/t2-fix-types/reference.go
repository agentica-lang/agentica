package main

import (
	"bufio"
	"fmt"
	"math"
	"os"
	"strconv"
	"strings"
)

// decimal prints a float the way Python's repr does: 5.0, 0.25, 1e+16.
func decimal(f float64) string {
	if f != 0 && (math.Abs(f) >= 1e16 || math.Abs(f) < 1e-4) {
		return strconv.FormatFloat(f, 'e', -1, 64)
	}
	s := strconv.FormatFloat(f, 'f', -1, 64)
	if !strings.Contains(s, ".") {
		s += ".0"
	}
	return s
}

func main() {
	total := 0.0
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		parts := strings.Split(line, " ")
		quantity, err := strconv.Atoi(parts[1])
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		price, err := strconv.ParseFloat(parts[2], 64)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		amount := float64(quantity) * price
		fmt.Println(parts[0] + ": " + decimal(amount))
		total += amount
	}
	fmt.Println("total: " + decimal(total))
}
