package main

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
)

type Item struct {
	Name  string
	Price int
}

func describe(item Item) string {
	return item.Name + ": " + strconv.Itoa(item.Price)
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
		item := Item{Name: parts[0], Price: price}
		fmt.Println(describe(item))
		total = total + item.Price
	}
	fmt.Println("total: " + strconv.Itoa(total))
}
