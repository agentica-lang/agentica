package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

func lineTotal(quantity int, price float64) float64 {
	return quantity * price
}

func main() {
	var total int = 0.0
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		parts := strings.Split(line, " ")
		quantity := parts[1]
		price := parts[2]
		amount := lineTotal(quantity, price)
		fmt.Println(parts[0] + ": " + amount)
		total = total + amount
	}
	fmt.Println("total: " + total)
}
