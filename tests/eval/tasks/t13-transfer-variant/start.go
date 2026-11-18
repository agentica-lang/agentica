package main

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
)

type Txn interface{ isTxn() }

type Deposit struct{ Amount int }
type Withdraw struct{ Amount int }
type Fee struct {
	Amount int
	Label  string
}

func (Deposit) isTxn()  {}
func (Withdraw) isTxn() {}
func (Fee) isTxn()      {}

type Stats struct {
	Inflow   int
	Outflow  int
	Fees     int
	Rejected int
}

func parseAmount(text string) (int, bool) {
	n, err := strconv.Atoi(text)
	return n, err == nil && n > 0
}

func parseTxn(line string) Txn {
	var parts []string
	for _, w := range strings.Split(line, " ") {
		if w != "" {
			parts = append(parts, w)
		}
	}
	if len(parts) == 2 && parts[0] == "deposit" {
		if amount, ok := parseAmount(parts[1]); ok {
			return Deposit{amount}
		}
		return nil
	}
	if len(parts) == 2 && parts[0] == "withdraw" {
		if amount, ok := parseAmount(parts[1]); ok {
			return Withdraw{amount}
		}
		return nil
	}
	if len(parts) == 3 && parts[0] == "fee" {
		if amount, ok := parseAmount(parts[1]); ok {
			return Fee{amount, parts[2]}
		}
		return nil
	}
	return nil
}

func describe(txn Txn) string {
	switch t := txn.(type) {
	case Deposit:
		return fmt.Sprintf("deposit %d", t.Amount)
	case Withdraw:
		return fmt.Sprintf("withdraw %d", t.Amount)
	case Fee:
		return fmt.Sprintf("fee %d (%s)", t.Amount, t.Label)
	}
	panic(fmt.Sprintf("unknown transaction %T", txn))
}

func category(txn Txn) string {
	switch txn.(type) {
	case Deposit:
		return "inflow"
	case Withdraw:
		return "outflow"
	case Fee:
		return "fee"
	}
	panic(fmt.Sprintf("unknown transaction %T", txn))
}

func applyTxn(balance int, txn Txn) (int, bool) {
	switch t := txn.(type) {
	case Deposit:
		return balance + t.Amount, true
	case Withdraw:
		return balance - t.Amount, t.Amount <= balance
	case Fee:
		return balance - t.Amount, t.Amount <= balance
	}
	panic(fmt.Sprintf("unknown transaction %T", txn))
}

func tally(stats Stats, txn Txn) Stats {
	switch t := txn.(type) {
	case Deposit:
		stats.Inflow += t.Amount
	case Withdraw:
		stats.Outflow += t.Amount
	case Fee:
		stats.Fees += t.Amount
	default:
		panic(fmt.Sprintf("unknown transaction %T", txn))
	}
	return stats
}

func main() {
	balance := 0
	stats := Stats{}
	reader := bufio.NewReader(os.Stdin)
	for {
		raw, err := reader.ReadString('\n')
		if line := strings.TrimSpace(raw); line != "" {
			txn := parseTxn(line)
			if txn == nil {
				fmt.Printf("invalid: %s\n", line)
			} else if applied, ok := applyTxn(balance, txn); ok {
				balance = applied
				stats = tally(stats, txn)
				fmt.Printf("%s: %s -> %d\n", category(txn), describe(txn), balance)
			} else {
				stats.Rejected++
				fmt.Printf("rejected: %s (insufficient funds)\n", describe(txn))
			}
		}
		if err != nil {
			break
		}
	}
	fmt.Printf("balance: %d\n", balance)
	fmt.Printf("inflow: %d\n", stats.Inflow)
	fmt.Printf("outflow: %d\n", stats.Outflow)
	fmt.Printf("fees: %d\n", stats.Fees)
	fmt.Printf("rejected: %d\n", stats.Rejected)
}
