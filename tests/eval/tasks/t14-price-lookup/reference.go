package main

import (
	"bufio"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
)

type State struct {
	Prices  map[string]int
	Unknown int
}

func findPrice(prices map[string]int, item string) (int, bool) {
	price, found := prices[item]
	return price, found
}

func badCommand() {
	fmt.Println("error: bad command")
}

func parseCents(text string) (int, bool) {
	n, err := strconv.Atoi(text)
	return n, err == nil && n >= 0
}

func priceCommand(state *State, args []string) {
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
	if old, found := findPrice(state.Prices, item); found {
		fmt.Printf("updated %s: %d -> %d\n", item, old, cents)
	} else {
		fmt.Printf("added %s: %d\n", item, cents)
	}
	state.Prices[item] = cents
}

func quoteCommand(state *State, args []string) {
	if len(args) != 1 {
		badCommand()
		return
	}
	price, found := findPrice(state.Prices, args[0])
	if !found {
		fmt.Printf("error: unknown item %s\n", args[0])
		state.Unknown++
		return
	}
	fmt.Printf("%s: %d\n", args[0], price)
}

func costCommand(state *State, args []string) {
	if len(args) < 3 || len(args)%2 != 1 {
		badCommand()
		return
	}
	var quantities []int
	for i := 2; i < len(args); i += 2 {
		qty, ok := parseCents(args[i])
		if !ok || qty < 1 {
			badCommand()
			return
		}
		quantities = append(quantities, qty)
	}
	total := 0
	for n, qty := range quantities {
		item := args[1+2*n]
		price, found := findPrice(state.Prices, item)
		if !found {
			fmt.Printf("%s: unknown item %s\n", args[0], item)
			state.Unknown++
			return
		}
		total += price * qty
	}
	fmt.Printf("%s: %d\n", args[0], total)
}

func cheapestCommand(state *State, args []string) {
	if len(args) < 1 {
		badCommand()
		return
	}
	best, bestPrice, found := "", 0, false
	for _, item := range args {
		price, known := findPrice(state.Prices, item)
		if !known {
			state.Unknown++
		} else if !found || price < bestPrice {
			best, bestPrice, found = item, price, true
		}
	}
	if found {
		fmt.Printf("cheapest: %s (%d)\n", best, bestPrice)
	} else {
		fmt.Println("error: no known items")
	}
}

func reportCommand(state *State) {
	items := make([]string, 0, len(state.Prices))
	for item := range state.Prices {
		items = append(items, item)
	}
	sort.Strings(items)
	for _, item := range items {
		fmt.Printf("%s %d\n", item, state.Prices[item])
	}
}

func main() {
	state := &State{Prices: map[string]int{}}
	reader := bufio.NewReader(os.Stdin)
	for {
		raw, err := reader.ReadString('\n')
		if line := strings.TrimSpace(raw); line != "" {
			parts := strings.Fields(line)
			args := parts[1:]
			switch parts[0] {
			case "price":
				priceCommand(state, args)
			case "quote":
				quoteCommand(state, args)
			case "cost":
				costCommand(state, args)
			case "cheapest":
				cheapestCommand(state, args)
			case "report":
				reportCommand(state)
			default:
				badCommand()
			}
		}
		if err != nil {
			break
		}
	}
	fmt.Printf("unknown: %d\n", state.Unknown)
}
