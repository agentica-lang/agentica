package main

import (
	"bufio"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
)

type Item struct {
	Name  string
	Qty   int
	Price int
}

type Shop struct {
	Items   map[string]Item
	Spent   map[string]int
	Revenue int
}

func newShop() *Shop {
	return &Shop{Items: map[string]Item{}, Spent: map[string]int{}}
}

func words(line string) []string {
	var out []string
	for _, w := range strings.Split(strings.TrimSpace(line), " ") {
		if w != "" {
			out = append(out, w)
		}
	}
	return out
}

func parseCount(text string) (int, bool) {
	n, err := strconv.Atoi(text)
	if err != nil || n < 0 {
		return 0, false
	}
	return n, true
}

func badCommand() {
	fmt.Println("error: bad command")
}

func unknownItem(name string) {
	fmt.Printf("error: unknown item %s\n", name)
}

func addCommand(shop *Shop, args []string) {
	if len(args) != 3 {
		badCommand()
		return
	}
	qty, okQty := parseCount(args[1])
	price, okPrice := parseCount(args[2])
	if !okQty || !okPrice {
		badCommand()
		return
	}
	name := args[0]
	total := shop.Items[name].Qty + qty
	fmt.Printf("added %s: %d (now %d)\n", name, qty, total)
	shop.Items[name] = Item{Name: name, Qty: total, Price: price}
}

func lineTotal(item Item, qty int) int {
	return item.Price * qty
}

func orderCommand(shop *Shop, args []string) {
	if len(args) != 3 {
		badCommand()
		return
	}
	qty, ok := parseCount(args[2])
	if !ok || qty == 0 {
		badCommand()
		return
	}
	customer, name := args[0], args[1]
	item, found := shop.Items[name]
	if !found {
		fmt.Printf("rejected %s %s: unknown item\n", customer, name)
		return
	}
	if item.Qty < qty {
		fmt.Printf("rejected %s %s: only %d in stock\n", customer, name, item.Qty)
		return
	}
	total := lineTotal(item, qty)
	fmt.Printf("sold %s %s %d for %d\n", customer, name, qty, total)
	item.Qty -= qty
	shop.Items[name] = item
	shop.Spent[customer] += total
	shop.Revenue += total
}

func priceCommand(shop *Shop, args []string) {
	if len(args) != 2 {
		badCommand()
		return
	}
	price, ok := parseCount(args[1])
	if !ok {
		badCommand()
		return
	}
	name := args[0]
	item, found := shop.Items[name]
	if !found {
		unknownItem(name)
		return
	}
	fmt.Printf("price %s: %d\n", name, price)
	item.Price = price
	shop.Items[name] = item
}

func stockCommand(shop *Shop, args []string) {
	if len(args) != 1 {
		badCommand()
		return
	}
	name := args[0]
	item, found := shop.Items[name]
	if !found {
		unknownItem(name)
		return
	}
	fmt.Printf("%s: %d\n", name, item.Qty)
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for key := range m {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func customersCommand(shop *Shop) {
	if len(shop.Spent) == 0 {
		fmt.Println("no customers")
		return
	}
	for _, customer := range sortedKeys(shop.Spent) {
		fmt.Printf("%s: %d\n", customer, shop.Spent[customer])
	}
}

func reportCommand(shop *Shop) {
	for _, name := range sortedKeys(shop.Items) {
		item := shop.Items[name]
		fmt.Printf("%s %d x %d\n", item.Name, item.Qty, item.Price)
	}
	fmt.Printf("revenue: %d\n", shop.Revenue)
}

func runCommand(shop *Shop, line string) {
	parts := words(line)
	command, args := parts[0], parts[1:]
	switch command {
	case "add":
		addCommand(shop, args)
	case "order":
		orderCommand(shop, args)
	case "price":
		priceCommand(shop, args)
	case "stock":
		stockCommand(shop, args)
	case "customers":
		customersCommand(shop)
	case "report":
		reportCommand(shop)
	default:
		badCommand()
	}
}

func main() {
	shop := newShop()
	reader := bufio.NewReader(os.Stdin)
	for {
		raw, err := reader.ReadString('\n')
		if line := strings.TrimSpace(raw); line != "" {
			runCommand(shop, line)
		}
		if err != nil {
			break
		}
	}
}
