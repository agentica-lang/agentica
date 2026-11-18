package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
)

var integer = regexp.MustCompile(`^-?[0-9]+$`)

type rawJSON string

func (r rawJSON) MarshalJSON() ([]byte, error) {
	return []byte(r), nil
}

func sendJSON(w http.ResponseWriter, status int, body any, allow string) {
	data, err := json.Marshal(body)
	if err != nil {
		status, data = 500, []byte(`{"error":"internal"}`)
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	if allow != "" {
		w.Header().Set("Allow", allow)
	}
	w.WriteHeader(status)
	_, _ = w.Write(data)
}

// bigInt accepts a JSON integer of any size; booleans and numbers such as 1.0 or 1e5 are not integers.
func bigInt(value any) (*big.Int, bool) {
	number, ok := value.(json.Number)
	if !ok {
		return nil, false
	}
	return new(big.Int).SetString(string(number), 10)
}

func statsBody(raw []byte) (int, any) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var root any
	if err := decoder.Decode(&root); err != nil {
		return 400, map[string]string{"error": "invalid json"}
	}
	if _, err := decoder.Token(); err != io.EOF {
		return 400, map[string]string{"error": "invalid json"}
	}
	invalid := map[string]string{"error": "values must be a non-empty array of integers"}
	object, _ := root.(map[string]any)
	values, ok := object["values"].([]any)
	if !ok || len(values) == 0 {
		return 400, invalid
	}
	sum := new(big.Int)
	var low, high *big.Int
	for _, value := range values {
		n, ok := bigInt(value)
		if !ok {
			return 400, invalid
		}
		sum.Add(sum, n)
		if low == nil || n.Cmp(low) < 0 {
			low = n
		}
		if high == nil || n.Cmp(high) > 0 {
			high = n
		}
	}
	return 200, struct {
		Count int     `json:"count"`
		Sum   rawJSON `json:"sum"`
		Min   rawJSON `json:"min"`
		Max   rawJSON `json:"max"`
	}{len(values), rawJSON(sum.String()), rawJSON(low.String()), rawJSON(high.String())}
}

// helloName is the first non-empty `name` parameter, as Python's parse_qs keeps it.
func helloName(r *http.Request) string {
	for _, name := range r.URL.Query()["name"] {
		if name != "" {
			return name
		}
	}
	return "world"
}

func handle(w http.ResponseWriter, r *http.Request) {
	raw, _ := io.ReadAll(r.Body)
	path := r.URL.EscapedPath()
	var allow string
	switch {
	case path == "/health", path == "/hello", strings.HasPrefix(path, "/double/"):
		allow = http.MethodGet
	case path == "/stats":
		allow = http.MethodPost
	default:
		sendJSON(w, 404, map[string]string{"error": "not found"}, "")
		return
	}
	if r.Method != allow {
		sendJSON(w, 405, map[string]string{"error": "method not allowed"}, allow)
		return
	}
	switch {
	case path == "/health":
		sendJSON(w, 200, map[string]string{"status": "ok"}, "")
	case path == "/stats":
		status, body := statsBody(raw)
		sendJSON(w, status, body, "")
	case path == "/hello":
		sendJSON(w, 200, map[string]string{"greeting": "hello, " + helloName(r)}, "")
	default:
		text := path[len("/double/"):]
		n, ok := new(big.Int).SetString(text, 10)
		if !integer.MatchString(text) || !ok {
			sendJSON(w, 400, map[string]string{"error": "not an integer"}, "")
			return
		}
		double := new(big.Int).Mul(n, big.NewInt(2))
		sendJSON(w, 200, map[string]rawJSON{"n": rawJSON(n.String()), "double": rawJSON(double.String())}, "")
	}
}

func main() {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Printf("listening %d\n", listener.Addr().(*net.TCPAddr).Port)
	if err := http.Serve(listener, http.HandlerFunc(handle)); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
