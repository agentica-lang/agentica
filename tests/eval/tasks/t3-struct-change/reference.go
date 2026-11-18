package main

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
)

type Item struct {
	Name     string
	Price    int
	Quantity int
}

func describe(item Item) string {
	return fmt.Sprintf("%s: %d x %d = %d", item.Name, item.Price, item.Quantity, item.Price*item.Quantity)
}

func main() {
	total := 0
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		parts := strings.Split(line, " ")
		price, _ := strconv.Atoi(parts[1])
		quantity, _ := strconv.Atoi(parts[2])
		item := Item{Name: parts[0], Price: price, Quantity: quantity}
		fmt.Println(describe(item))
		total += item.Price * item.Quantity
	}
	fmt.Println("total: " + strconv.Itoa(total))
}
