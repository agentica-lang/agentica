package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
)

type Customer struct {
	Customer   string `json:"customer"`
	Rows       int    `json:"rows"`
	Items      int    `json:"items"`
	TotalCents int    `json:"total_cents"`
}

type Report struct {
	Customers []Customer `json:"customers"`
	Skipped   int        `json:"skipped"`
}

type Row struct {
	Customer string
	Quantity int
	Cents    int
}

func parseRow(line string) (Row, bool) {
	fields := strings.Split(line, ",")
	for i := range fields {
		fields[i] = strings.TrimSpace(fields[i])
	}
	if len(fields) != 5 || fields[0] == "" || fields[1] == "" || fields[2] == "" {
		return Row{}, false
	}
	quantity, err := strconv.Atoi(fields[3])
	if err != nil || quantity < 1 {
		return Row{}, false
	}
	cents, err := strconv.Atoi(fields[4])
	if err != nil || cents < 0 {
		return Row{}, false
	}
	return Row{Customer: fields[1], Quantity: quantity, Cents: cents}, true
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}

func main() {
	source, target := os.Args[1], os.Args[2]
	data, err := os.ReadFile(source)
	if err != nil {
		fail(err)
	}
	totals := map[string]Customer{}
	rows, skipped := 0, 0
	for _, line := range strings.Split(string(data), "\n")[1:] {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		row, ok := parseRow(line)
		if !ok {
			skipped++
			continue
		}
		before := totals[row.Customer]
		totals[row.Customer] = Customer{row.Customer, before.Rows + 1, before.Items + row.Quantity,
			before.TotalCents + row.Quantity*row.Cents}
		rows++
	}
	report := Report{Customers: []Customer{}, Skipped: skipped}
	for _, customer := range totals {
		report.Customers = append(report.Customers, customer)
	}
	sort.Slice(report.Customers, func(i, j int) bool {
		return report.Customers[i].Customer < report.Customers[j].Customer
	})
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(report); err != nil {
		fail(err)
	}
	if err := os.WriteFile(target, buffer.Bytes(), 0o644); err != nil {
		fail(err)
	}
	fmt.Printf("rows: %d\n", rows)
	fmt.Printf("skipped: %d\n", skipped)
}
