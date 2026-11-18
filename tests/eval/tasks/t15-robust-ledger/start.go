package main

import (
	"bufio"
	"fmt"
	"log"
	"os"
	"sort"
	"strconv"
	"strings"
)

type Summary struct {
	Balances map[string]int
	Total    int
}

func applyLine(summary *Summary, line string) {
	parts := strings.Split(line, " ")
	account := parts[0]
	amount, err := strconv.Atoi(parts[1])
	if err != nil {
		log.Fatal(err)
	}
	summary.Balances[account] += amount
	summary.Total += amount
}

func main() {
	summary := &Summary{Balances: map[string]int{}}
	reader := bufio.NewReader(os.Stdin)
	for {
		raw, err := reader.ReadString('\n')
		if line := strings.TrimSpace(raw); line != "" && !strings.HasPrefix(line, "#") {
			applyLine(summary, line)
		}
		if err != nil {
			break
		}
	}
	accounts := make([]string, 0, len(summary.Balances))
	for account := range summary.Balances {
		accounts = append(accounts, account)
	}
	sort.Strings(accounts)
	for _, account := range accounts {
		fmt.Printf("%s: %d\n", account, summary.Balances[account])
	}
	fmt.Printf("total: %d\n", summary.Total)
}
