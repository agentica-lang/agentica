package main

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
)

func digits(text string) bool {
	if text == "" {
		return false
	}
	for i := 0; i < len(text); i++ {
		if text[i] < '0' || text[i] > '9' {
			return false
		}
	}
	return true
}

// atLeast compares a digit string with a bound; a number too big for 64 bits is above any bound.
func atLeast(text string, bound uint64) bool {
	n, err := strconv.ParseUint(text, 10, 64)
	return errors.Is(err, strconv.ErrRange) || (err == nil && n >= bound)
}

func main() {
	file, err := os.Open(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	out := bufio.NewWriter(os.Stdout)
	defer out.Flush()
	for scanner.Scan() {
		parts := strings.Split(strings.TrimSuffix(scanner.Text(), "\r"), " ")
		if len(parts) != 6 || !digits(parts[0]) || !digits(parts[4]) || !digits(parts[5]) {
			continue
		}
		if parts[1] == "" || parts[2] == "" || parts[3] == "" {
			continue
		}
		if atLeast(parts[4], 500) && atLeast(parts[5], 800) {
			fmt.Fprintf(out, "%s %s %s\n", parts[0], parts[1], parts[5])
		}
	}
	if err := scanner.Err(); err != nil {
		out.Flush()
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
