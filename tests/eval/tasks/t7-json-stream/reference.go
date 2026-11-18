package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
)

var errInvalid = errors.New("invalid request")

// asInt accepts a JSON integer that fits signed 64 bits; booleans and numbers such as 1.0 are not integers.
func asInt(value any) (int64, error) {
	number, ok := value.(json.Number)
	if !ok {
		return 0, errInvalid
	}
	return strconv.ParseInt(string(number), 10, 64)
}

func handleRequest(line string) (string, error) {
	decoder := json.NewDecoder(strings.NewReader(line))
	decoder.UseNumber()
	var root any
	if err := decoder.Decode(&root); err != nil {
		return "", err
	}
	if _, err := decoder.Token(); err != io.EOF {
		return "", errInvalid
	}
	object, ok := root.(map[string]any)
	if !ok {
		return "", errInvalid
	}
	values, ok := object["values"].([]any)
	if !ok {
		return "", errInvalid
	}
	id, err := asInt(object["id"])
	if err != nil {
		return "", err
	}
	var result int64
	switch object["op"] {
	case "count":
		result = int64(len(values))
	case "sum":
		for _, value := range values {
			n, err := asInt(value)
			if err != nil {
				return "", err
			}
			result += n
		}
	default:
		return "", errInvalid
	}
	return fmt.Sprintf("{\"id\":%d,\"result\":%d}", id, result), nil
}

func main() {
	reader := bufio.NewReader(os.Stdin)
	for {
		line, err := reader.ReadString('\n')
		if line != "" {
			reply, failure := handleRequest(line)
			if failure != nil {
				reply = "{\"error\":\"invalid request\"}"
			}
			fmt.Println(reply)
		}
		if err != nil {
			break
		}
	}
}
