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
	ID     string
	Title  string
	Copies int
}

type Member struct {
	ID   string
	Name string
}

type Library struct {
	Books   map[string]Book
	Members map[string]Member
	Loans   map[string][]string
}

func newLibrary() *Library {
	return &Library{Books: map[string]Book{}, Members: map[string]Member{}, Loans: map[string][]string{}}
}

func badCommand() {
	fmt.Println("error: bad command")
}

func parseInt(text string) (int, bool) {
	n, err := strconv.Atoi(text)
	return n, err == nil
}

func validID(text, prefix string) bool {
	if !strings.HasPrefix(text, prefix) || len(text) <= 2 {
		return false
	}
	for _, c := range text[2:] {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

func invalidMember(id string) {
	fmt.Printf("error: invalid member id %s\n", id)
}

func invalidBook(id string) {
	fmt.Printf("error: invalid book id %s\n", id)
}

func onLoan(lib *Library, bookID string) int {
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
	memberID := args[0]
	if !validID(memberID, "M-") {
		invalidMember(memberID)
		return
	}
	member := Member{ID: memberID, Name: args[1]}
	fmt.Printf("member %s: %s\n", member.ID, member.Name)
	lib.Members[member.ID] = member
	lib.Loans[member.ID] = nil
}

func bookCommand(lib *Library, args []string) {
	if len(args) < 3 {
		badCommand()
		return
	}
	bookID := args[0]
	if !validID(bookID, "B-") {
		invalidBook(bookID)
		return
	}
	copies, okCopies := parseInt(args[1])
	if !okCopies || copies < 1 {
		badCommand()
		return
	}
	book := Book{ID: bookID, Title: strings.Join(args[2:], " "), Copies: copies}
	fmt.Printf("book %s: %s (%d)\n", book.ID, book.Title, book.Copies)
	lib.Books[book.ID] = book
}

func borrowCommand(lib *Library, args []string) {
	if len(args) != 2 {
		badCommand()
		return
	}
	mid, bid := args[0], args[1]
	if !validID(mid, "M-") {
		invalidMember(mid)
		return
	}
	if !validID(bid, "B-") {
		invalidBook(bid)
		return
	}
	member, found := lib.Members[mid]
	if !found {
		fmt.Printf("error: unknown member %s\n", mid)
		return
	}
	book, found := lib.Books[bid]
	if !found {
		fmt.Printf("error: unknown book %s\n", bid)
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
	mid, bid := args[0], args[1]
	if !validID(mid, "M-") {
		invalidMember(mid)
		return
	}
	if !validID(bid, "B-") {
		invalidBook(bid)
		return
	}
	member, found := lib.Members[mid]
	if !found {
		fmt.Printf("error: unknown member %s\n", mid)
		return
	}
	book, found := lib.Books[bid]
	if !found {
		fmt.Printf("error: unknown book %s\n", bid)
		return
	}
	if !slices.Contains(lib.Loans[mid], bid) {
		fmt.Println("error: not borrowed")
		return
	}
	var kept []string
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
	mid := args[0]
	if !validID(mid, "M-") {
		invalidMember(mid)
		return
	}
	member, found := lib.Members[mid]
	if !found {
		fmt.Printf("error: unknown member %s\n", mid)
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
		fmt.Printf("  %s %s\n", bid, lib.Books[bid].Title)
	}
}

func statusCommand(lib *Library) {
	ids := make([]string, 0, len(lib.Books))
	for bid := range lib.Books {
		ids = append(ids, bid)
	}
	sort.Strings(ids)
	for _, bid := range ids {
		book := lib.Books[bid]
		fmt.Printf("%s %s: %d/%d\n", book.ID, book.Title, book.Copies-onLoan(lib, bid), book.Copies)
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
