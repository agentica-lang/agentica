package main

import (
	"bufio"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
)

func findPrice(prices map[string]int, item string) int {
	if price, found := prices[item]; found {
		return price
	}
	return -1
}

func badCommand() {
	fmt.Println("error: bad command")
}

func parseCents(text string) (int, bool) {
	n, err := strconv.Atoi(text)
	return n, err == nil && n >= 0
}

func priceCommand(prices map[string]int, args []string) {
	if len(args) != 2 {
		badCommand()
		return
	}
	cents, ok := parseCents(args[1])
	if !ok {
		badCommand()
		return
	}
	item := args[0]
	old := findPrice(prices, item)
	if old == -1 {
		fmt.Printf("added %s: %d\n", item, cents)
	} else {
		fmt.Printf("updated %s: %d -> %d\n", item, old, cents)
	}
	prices[item] = cents
}

func quoteCommand(prices map[string]int, args []string) {
	if len(args) != 1 {
		badCommand()
		return
	}
	fmt.Printf("%s: %d\n", args[0], findPrice(prices, args[0]))
}

func costCommand(prices map[string]int, args []string) {
	if len(args) < 3 || len(args)%2 != 1 {
		badCommand()
		return
	}
	total := 0
	for i := 1; i < len(args); i += 2 {
		qty, ok := parseCents(args[i+1])
		if !ok || qty < 1 {
			badCommand()
			return
		}
		total += findPrice(prices, args[i]) * qty
	}
	fmt.Printf("%s: %d\n", args[0], total)
}

func cheapestCommand(prices map[string]int, args []string) {
	if len(args) < 1 {
		badCommand()
		return
	}
	best := args[0]
	bestPrice := findPrice(prices, best)
	for _, item := range args[1:] {
		if price := findPrice(prices, item); price < bestPrice {
			best, bestPrice = item, price
		}
	}
	fmt.Printf("cheapest: %s (%d)\n", best, bestPrice)
}

func reportCommand(prices map[string]int) {
	items := make([]string, 0, len(prices))
	for item := range prices {
		items = append(items, item)
	}
	sort.Strings(items)
	for _, item := range items {
		fmt.Printf("%s %d\n", item, prices[item])
	}
}

func main() {
	prices := map[string]int{}
	reader := bufio.NewReader(os.Stdin)
	for {
		raw, err := reader.ReadString('\n')
		if line := strings.TrimSpace(raw); line != "" {
			parts := strings.Fields(line)
			args := parts[1:]
			switch parts[0] {
			case "price":
				priceCommand(prices, args)
			case "quote":
				quoteCommand(prices, args)
			case "cost":
				costCommand(prices, args)
			case "cheapest":
				cheapestCommand(prices, args)
			case "report":
				reportCommand(prices)
			default:
				badCommand()
			}
		}
		if err != nil {
			break
		}
	}
}
