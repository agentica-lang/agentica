package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"sort"
	"strconv"
	"strings"
)

func sendText(w http.ResponseWriter, status int, body any) {
	data, _ := json.Marshal(body)
	w.Header().Set("Content-Type", "text/plain")
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	w.WriteHeader(status)
	_, _ = w.Write(data)
}

func stats(raw []byte) map[string]int {
	var body struct{ Values []int }
	if err := json.Unmarshal(raw, &body); err != nil {
		panic(err)
	}
	ordered := append([]int(nil), body.Values...)
	sort.Ints(ordered)
	sum := 0
	for _, v := range body.Values {
		sum += v
	}
	return map[string]int{"count": len(body.Values), "total": sum, "min": ordered[len(ordered)-1], "max": ordered[0]}
}

func handle(w http.ResponseWriter, r *http.Request) {
	path := r.URL.RequestURI()
	switch r.Method {
	case http.MethodGet:
		switch {
		case path == "/health":
			sendText(w, 200, map[string]string{"status": "ok"})
		case path == "/hello":
			sendText(w, 200, map[string]string{"greeting": "hello, world"})
		case strings.HasPrefix(path, "/double/"):
			n, err := strconv.Atoi(path[len("/double/"):])
			if err != nil {
				panic(err)
			}
			sendText(w, 200, map[string]int{"n": n, "double": n * 2})
		default:
			sendText(w, 200, map[string]string{"error": "not found"})
		}
	case http.MethodPost:
		raw, _ := io.ReadAll(r.Body)
		if path == "/stats" {
			sendText(w, 200, stats(raw))
		} else {
			sendText(w, 200, map[string]string{"error": "not found"})
		}
	default:
		http.Error(w, "Unsupported method", http.StatusNotImplemented)
	}
}

func main() {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		panic(err)
	}
	fmt.Println("listening 0")
	panic(http.Serve(listener, http.HandlerFunc(handle)))
}
