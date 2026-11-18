package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

var client = &http.Client{Timeout: 10 * time.Second}

func decode(text []byte) (map[string]any, bool) {
	decoder := json.NewDecoder(bytes.NewReader(text))
	decoder.UseNumber()
	var parsed any
	if decoder.Decode(&parsed) != nil {
		return nil, false
	}
	if _, err := decoder.Token(); err != io.EOF {
		return nil, false
	}
	object, ok := parsed.(map[string]any)
	return object, ok
}

func isInt(value any) bool {
	number, ok := value.(json.Number)
	if !ok {
		return false
	}
	_, err := strconv.ParseInt(string(number), 10, 64)
	return err == nil
}

func failureText(text []byte) string {
	parsed, ok := decode(text)
	if !ok {
		return "error: bad response"
	}
	message, ok := parsed["error"].(string)
	if !ok {
		return "error: bad response"
	}
	return "error: " + message
}

func quote(base, item string, quantity int) string {
	body, err := json.Marshal(struct {
		Item     string `json:"item"`
		Quantity int    `json:"quantity"`
	}{item, quantity})
	if err != nil {
		return "error: bad response"
	}
	response, err := client.Post(base+"/quote", "application/json", bytes.NewReader(body))
	if err != nil {
		return "error: no response"
	}
	defer response.Body.Close()
	text, err := io.ReadAll(response.Body)
	if err != nil {
		return "error: no response"
	}
	switch response.StatusCode {
	case http.StatusOK:
		reply, ok := decode(text)
		_, named := reply["item"].(string)
		if !ok || !named || !isInt(reply["unit_cents"]) || !isInt(reply["total_cents"]) {
			return "error: bad response"
		}
		return fmt.Sprintf("%s: %s", item, reply["total_cents"])
	case http.StatusBadRequest, http.StatusNotFound:
		return failureText(text)
	}
	return "error: bad response"
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
