package main

import (
	"bufio"
	"fmt"
	"os"
	"slices"
	"sort"
	"strconv"
	"strings"
)

type Book struct {
	ID     int
	Title  string
	Copies int
}

type Member struct {
	ID   int
	Name string
}

type Library struct {
	Books   map[int]Book
	Members map[int]Member
	Loans   map[int][]int
}

func newLibrary() *Library {
	return &Library{Books: map[int]Book{}, Members: map[int]Member{}, Loans: map[int][]int{}}
}

func badCommand() {
	fmt.Println("error: bad command")
}

func parseInt(text string) (int, bool) {
	n, err := strconv.Atoi(text)
	return n, err == nil
}

func onLoan(lib *Library, bookID int) int {
	count := 0
	for _, books := range lib.Loans {
		if slices.Contains(books, bookID) {
			count++
		}
	}
	return count
}

func memberCommand(lib *Library, args []string) {
	if len(args) != 2 {
		badCommand()
		return
	}
	memberID, ok := parseInt(args[0])
	if !ok {
		badCommand()
		return
	}
	member := Member{ID: memberID, Name: args[1]}
	fmt.Printf("member %d: %s\n", member.ID, member.Name)
	lib.Members[member.ID] = member
	lib.Loans[member.ID] = nil
}

func bookCommand(lib *Library, args []string) {
	if len(args) < 3 {
		badCommand()
		return
	}
	bookID, okID := parseInt(args[0])
	copies, okCopies := parseInt(args[1])
	if !okID || !okCopies || copies < 1 {
		badCommand()
		return
	}
	book := Book{ID: bookID, Title: strings.Join(args[2:], " "), Copies: copies}
	fmt.Printf("book %d: %s (%d)\n", book.ID, book.Title, book.Copies)
	lib.Books[book.ID] = book
}

func borrowCommand(lib *Library, args []string) {
	if len(args) != 2 {
		badCommand()
		return
	}
	mid, okMember := parseInt(args[0])
	bid, okBook := parseInt(args[1])
	if !okMember || !okBook {
		badCommand()
		return
	}
	member, found := lib.Members[mid]
	if !found {
		fmt.Printf("error: unknown member %d\n", mid)
		return
	}
	book, found := lib.Books[bid]
	if !found {
		fmt.Printf("error: unknown book %d\n", bid)
		return
	}
	if slices.Contains(lib.Loans[mid], bid) {
		fmt.Println("error: already borrowed")
		return
	}
	if onLoan(lib, bid) >= book.Copies {
		fmt.Println("error: no copies left")
		return
	}
	fmt.Printf("%s borrowed %s\n", member.Name, book.Title)
	lib.Loans[mid] = append(lib.Loans[mid], bid)
}

func returnCommand(lib *Library, args []string) {
	if len(args) != 2 {
		badCommand()
		return
	}
	mid, okMember := parseInt(args[0])
	bid, okBook := parseInt(args[1])
	if !okMember || !okBook {
		badCommand()
		return
	}
	member, found := lib.Members[mid]
	if !found {
		fmt.Printf("error: unknown member %d\n", mid)
		return
	}
	book, found := lib.Books[bid]
	if !found {
		fmt.Printf("error: unknown book %d\n", bid)
		return
	}
	if !slices.Contains(lib.Loans[mid], bid) {
		fmt.Println("error: not borrowed")
		return
	}
	var kept []int
	for _, b := range lib.Loans[mid] {
		if b != bid {
			kept = append(kept, b)
		}
	}
	fmt.Printf("%s returned %s\n", member.Name, book.Title)
	lib.Loans[mid] = kept
}

func loansCommand(lib *Library, args []string) {
	if len(args) != 1 {
		badCommand()
		return
	}
	mid, ok := parseInt(args[0])
	if !ok {
		badCommand()
		return
	}
	member, found := lib.Members[mid]
	if !found {
		fmt.Printf("error: unknown member %d\n", mid)
		return
	}
	ids := slices.Clone(lib.Loans[mid])
	slices.Sort(ids)
	if len(ids) == 0 {
		fmt.Printf("%s has no loans\n", member.Name)
		return
	}
	fmt.Printf("%s:\n", member.Name)
	for _, bid := range ids {
		fmt.Printf("  %d %s\n", bid, lib.Books[bid].Title)
	}
}

func statusCommand(lib *Library) {
	ids := make([]int, 0, len(lib.Books))
	for bid := range lib.Books {
		ids = append(ids, bid)
	}
	sort.Ints(ids)
	for _, bid := range ids {
		book := lib.Books[bid]
		fmt.Printf("%d %s: %d/%d\n", book.ID, book.Title, book.Copies-onLoan(lib, bid), book.Copies)
	}
}

func runCommand(lib *Library, line string) {
	var parts []string
	for _, w := range strings.Split(line, " ") {
		if w != "" {
			parts = append(parts, w)
		}
	}
	args := parts[1:]
	switch parts[0] {
	case "member":
		memberCommand(lib, args)
	case "book":
		bookCommand(lib, args)
	case "borrow":
		borrowCommand(lib, args)
	case "return":
		returnCommand(lib, args)
	case "loans":
		loansCommand(lib, args)
	case "status":
		statusCommand(lib)
	default:
		badCommand()
	}
}

func main() {
	lib := newLibrary()
	reader := bufio.NewReader(os.Stdin)
	for {
		raw, err := reader.ReadString('\n')
		if line := strings.TrimSpace(raw); line != "" {
			runCommand(lib, line)
		}
		if err != nil {
			break
		}
	}
}
