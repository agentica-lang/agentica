package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
)

var errInvalid = errors.New("invalid catalog")

// nonnegativeInt accepts a JSON integer in 0..2^63-1; booleans and numbers such as 3.0 are not integers.
func nonnegativeInt(value any) (int64, error) {
	number, ok := value.(json.Number)
	if !ok {
		return 0, errInvalid
	}
	n, err := strconv.ParseInt(string(number), 10, 64)
	if err != nil || n < 0 {
		return 0, errInvalid
	}
	return n, nil
}

func encodeString(s string) string {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	_ = encoder.Encode(s)
	return string(bytes.TrimRight(buffer.Bytes(), "\n"))
}

func filterCatalog(input io.Reader) (string, error) {
	decoder := json.NewDecoder(input)
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
	products, ok := object["products"].([]any)
	if !ok {
		return "", errInvalid
	}
	minimum, err := nonnegativeInt(object["minimum"])
	if err != nil {
		return "", err
	}
	var output bytes.Buffer
	for _, item := range products {
		product, ok := item.(map[string]any)
		if !ok {
			return "", errInvalid
		}
		name, ok := product["name"].(string)
		if !ok {
			return "", errInvalid
		}
		stock, err := nonnegativeInt(product["stock"])
		if err != nil {
			return "", err
		}
		if stock >= minimum {
			fmt.Fprintf(&output, "{\"name\":%s,\"stock\":%d}\n", encodeString(name), stock)
		}
	}
	return output.String(), nil
}

func main() {
	output, err := filterCatalog(os.Stdin)
	if err != nil {
		output = "{\"error\":\"invalid catalog\"}\n"
	}
	fmt.Print(output)
}
