package main

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
)

type Command interface{ isCommand() }

type Credit struct{ Amount int }
type Debit struct{ Amount int }
type Show struct{}
type Reset struct{}

func (Credit) isCommand() {}
func (Debit) isCommand()  {}
func (Show) isCommand()   {}
func (Reset) isCommand()  {}

func parseCommand(line string) (Command, bool) {
	words := strings.Split(strings.TrimSpace(line), " ")
	if len(words) == 1 && words[0] == "show" {
		return Show{}, true
	}
	if len(words) == 1 && words[0] == "reset" {
		return Reset{}, true
	}
	if len(words) != 2 || (words[0] != "credit" && words[0] != "debit") {
		return nil, false
	}
	amount, err := strconv.Atoi(words[1])
	if err != nil || amount < 0 || amount > 1_000_000 {
		return nil, false
	}
	if words[0] == "credit" {
		return Credit{amount}, true
	}
	return Debit{amount}, true
}

func main() {
	balance := 0
	reader := bufio.NewReader(os.Stdin)
	for {
		line, err := reader.ReadString('\n')
		if line != "" {
			command, ok := parseCommand(line)
			if !ok {
				fmt.Println("error")
			} else {
				switch c := command.(type) {
				case Credit:
					balance += c.Amount
					fmt.Printf("balance: %d\n", balance)
				case Debit:
					if c.Amount > balance {
						fmt.Println("error")
					} else {
						balance -= c.Amount
						fmt.Printf("balance: %d\n", balance)
					}
				case Show:
					fmt.Printf("balance: %d\n", balance)
				case Reset:
					balance = 0
					fmt.Println("balance: 0")
				}
			}
		}
		if err != nil {
			break
		}
	}
	fmt.Printf("final: %d\n", balance)
}
