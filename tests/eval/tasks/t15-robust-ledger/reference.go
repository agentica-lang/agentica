package main

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

type Summary struct {
	Balances map[string]int64
	Total    int64
	Rejected int
}

var (
	accountPattern = regexp.MustCompile(`^[a-z][a-z0-9_]{0,15}$`)
	amountPattern  = regexp.MustCompile(`^[-+]?[0-9]+$`)
)

func applyLine(summary *Summary, line string) error {
	parts := strings.Split(line, " ")
	if len(parts) != 2 {
		return errors.New("expected 2 fields")
	}
	account := parts[0]
	if !accountPattern.MatchString(account) {
		return errors.New("bad account")
	}
	if !amountPattern.MatchString(parts[1]) {
		return errors.New("bad amount")
	}
	amount, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil || amount > 1000000 || amount < -1000000 {
		return errors.New("amount out of range")
	}
	summary.Balances[account] += amount
	summary.Total += amount
	return nil
}

func main() {
	summary := &Summary{Balances: map[string]int64{}}
	reader := bufio.NewReader(os.Stdin)
	for number := 1; ; number++ {
		raw, err := reader.ReadString('\n')
		if line := strings.TrimSpace(raw); line != "" && !strings.HasPrefix(line, "#") {
			if problem := applyLine(summary, line); problem != nil {
				fmt.Printf("line %d: %s\n", number, problem)
				summary.Rejected++
			}
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
	fmt.Printf("rejected: %d\n", summary.Rejected)
}
