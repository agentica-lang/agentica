package main

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"
)

type Customer struct {
	Name   string `json:"name"`
	Orders int    `json:"orders"`
	Total  int    `json:"total"`
}

type Row struct {
	Customer string
	Quantity int
	Cents    int
}

func parseRow(line string) (Row, bool) {
	fields := strings.Split(line, ";")
	for i := range fields {
		fields[i] = strings.TrimSpace(fields[i])
	}
	if len(fields) != 5 {
		return Row{}, false
	}
	if fields[0] == "" || fields[1] == "" || fields[2] == "" {
		return Row{}, false
	}
	quantity, err := strconv.Atoi(fields[3])
	if err != nil {
		return Row{}, false
	}
	cents, err := strconv.Atoi(fields[4])
	if err != nil {
		return Row{}, false
	}
	if quantity < 1 || cents < 0 {
		return Row{}, false
	}
	return Row{Customer: fields[1], Quantity: quantity, Cents: cents}, true
}

func main() {
	source := os.Args[1]
	data, err := os.ReadFile(source)
	if err != nil {
		log.Fatal(err)
	}
	totals := map[string]Customer{}
	var order []string
	rows, skipped := 0, 0
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		row, ok := parseRow(line)
		if !ok {
			skipped++
			continue
		}
		before, seen := totals[row.Customer]
		if !seen {
			order = append(order, row.Customer)
			before = Customer{Name: row.Customer}
		}
		totals[row.Customer] = Customer{row.Customer, before.Orders + 1, before.Total + row.Cents}
		rows++
	}
	customers := []Customer{}
	for _, name := range order {
		customers = append(customers, totals[name])
	}
	report, err := json.Marshal(map[string]any{"customers": customers, "skipped": skipped})
	if err != nil {
		log.Fatal(err)
	}
	if err := os.WriteFile(source, report, 0o644); err != nil {
		log.Fatal(err)
	}
	fmt.Printf("rows: %d\n", rows)
	fmt.Printf("skipped: %d\n", skipped)
}
