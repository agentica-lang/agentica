package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

var client = &http.Client{Timeout: 10 * time.Second}

func quote(base, item string, quantity int) string {
	body, _ := json.Marshal(map[string]any{"name": item, "qty": quantity})
	response, err := client.Post(base+"/quotes", "text/plain", bytes.NewReader(body))
	if err != nil {
		log.Fatal(err)
	}
	defer response.Body.Close()
	var reply map[string]any
	if err := json.NewDecoder(response.Body).Decode(&reply); err != nil {
		log.Fatal(err)
	}
	total, found := reply["total"]
	if !found {
		log.Fatalf("no total in %v", reply)
	}
	return fmt.Sprintf("%s: %v", item, total)
}

func main() {
	base := os.Args[1]
	sent, failed := 0, 0
	reader := bufio.NewReader(os.Stdin)
	for {
		raw, err := reader.ReadString('\n')
		if line := strings.TrimSpace(raw); line != "" {
			parts := strings.Split(line, " ")
			quantity, failure := strconv.Atoi(parts[len(parts)-1])
			if failure != nil {
				quantity = 0
			}
			if len(parts) != 2 || quantity < 1 {
				fmt.Printf("error: bad order: %s\n", line)
			} else {
				text := quote(base, parts[0], quantity)
				sent++
				if strings.HasPrefix(text, "error:") {
					failed++
					fmt.Printf("%s: %s\n", parts[0], text)
				} else {
					fmt.Println(text)
				}
			}
		}
		if err != nil {
			break
		}
	}
	fmt.Printf("orders: %d, failed: %d\n", sent, failed)
}
