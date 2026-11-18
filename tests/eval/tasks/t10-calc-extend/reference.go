package main

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
)

type Kind int

const (
	Num Kind = iota
	Ident
	Sym
)

type Token struct {
	Kind  Kind
	Value int
	Name  string
	Char  rune
}

type Parsed struct {
	Value int
	Pos   int
}

func isDigit(c rune) bool {
	return '0' <= c && c <= '9'
}

func isLetter(c rune) bool {
	return ('a' <= c && c <= 'z') || c == '_'
}

func isSym(token Token, char rune) bool {
	return token.Kind == Sym && token.Char == char
}

func tokenize(text string) ([]Token, error) {
	var tokens []Token
	chars := []rune(text)
	n := len(chars)
	i := 0
	for i < n {
		c := chars[i]
		switch {
		case c == ' ':
			i++
		case strings.ContainsRune("+-*/%^()=", c):
			tokens = append(tokens, Token{Kind: Sym, Char: c})
			i++
		case isDigit(c):
			j := i
			for j < n && isDigit(chars[j]) {
				j++
			}
			value, err := strconv.Atoi(string(chars[i:j]))
			if err != nil {
				return nil, err
			}
			tokens = append(tokens, Token{Kind: Num, Value: value})
			i = j
		case isLetter(c):
			j := i
			for j < n && isLetter(chars[j]) {
				j++
			}
			tokens = append(tokens, Token{Kind: Ident, Name: string(chars[i:j])})
			i = j
		default:
			return nil, fmt.Errorf("bad character '%c'", c)
		}
	}
	return tokens, nil
}

func truncDiv(a, b int) int {
	return a / b
}

func parseAtom(env map[string]int, tokens []Token, pos int) (Parsed, error) {
	if pos >= len(tokens) {
		return Parsed{}, errors.New("unexpected end of input")
	}
	token := tokens[pos]
	switch {
	case token.Kind == Num:
		return Parsed{token.Value, pos + 1}, nil
	case token.Kind == Ident:
		value, found := env[token.Name]
		if !found {
			return Parsed{}, fmt.Errorf("unknown variable %s", token.Name)
		}
		return Parsed{value, pos + 1}, nil
	case isSym(token, '('):
		inner, err := parseExpr(env, tokens, pos+1)
		if err != nil {
			return Parsed{}, err
		}
		if inner.Pos >= len(tokens) || !isSym(tokens[inner.Pos], ')') {
			return Parsed{}, errors.New("expected )")
		}
		return Parsed{inner.Value, inner.Pos + 1}, nil
	}
	return Parsed{}, errors.New("unexpected token")
}

func power(base, exponent int) int {
	result := 1
	for range exponent {
		result *= base
	}
	return result
}

func parseUnary(env map[string]int, tokens []Token, pos int) (Parsed, error) {
	if pos >= len(tokens) {
		return Parsed{}, errors.New("unexpected end of input")
	}
	if isSym(tokens[pos], '-') {
		inner, err := parseUnary(env, tokens, pos+1)
		if err != nil {
			return Parsed{}, err
		}
		return Parsed{-inner.Value, inner.Pos}, nil
	}
	return parsePower(env, tokens, pos)
}

func parsePower(env map[string]int, tokens []Token, pos int) (Parsed, error) {
	base, err := parseAtom(env, tokens, pos)
	if err != nil || base.Pos >= len(tokens) || !isSym(tokens[base.Pos], '^') {
		return base, err
	}
	exponent, err := parseUnary(env, tokens, base.Pos+1)
	if err != nil {
		return Parsed{}, err
	}
	if exponent.Value < 0 {
		return Parsed{}, errors.New("negative exponent")
	}
	return Parsed{power(base.Value, exponent.Value), exponent.Pos}, nil
}

func parseTerm(env map[string]int, tokens []Token, pos int) (Parsed, error) {
	left, err := parseUnary(env, tokens, pos)
	if err != nil {
		return Parsed{}, err
	}
	value, p := left.Value, left.Pos
	for p < len(tokens) {
		token := tokens[p]
		if isSym(token, '*') {
			right, err := parseUnary(env, tokens, p+1)
			if err != nil {
				return Parsed{}, err
			}
			value, p = value*right.Value, right.Pos
		} else if isSym(token, '/') {
			right, err := parseUnary(env, tokens, p+1)
			if err != nil {
				return Parsed{}, err
			}
			if right.Value == 0 {
				return Parsed{}, errors.New("division by zero")
			}
			value, p = truncDiv(value, right.Value), right.Pos
		} else if isSym(token, '%') {
			right, err := parseUnary(env, tokens, p+1)
			if err != nil {
				return Parsed{}, err
			}
			if right.Value == 0 {
				return Parsed{}, errors.New("division by zero")
			}
			value, p = value-right.Value*truncDiv(value, right.Value), right.Pos
		} else {
			break
		}
	}
	return Parsed{value, p}, nil
}

func parseExpr(env map[string]int, tokens []Token, pos int) (Parsed, error) {
	left, err := parseTerm(env, tokens, pos)
	if err != nil {
		return Parsed{}, err
	}
	value, p := left.Value, left.Pos
	for p < len(tokens) {
		token := tokens[p]
		if isSym(token, '+') {
			right, err := parseTerm(env, tokens, p+1)
			if err != nil {
				return Parsed{}, err
			}
			value, p = value+right.Value, right.Pos
		} else if isSym(token, '-') {
			right, err := parseTerm(env, tokens, p+1)
			if err != nil {
				return Parsed{}, err
			}
			value, p = value-right.Value, right.Pos
		} else {
			break
		}
	}
	return Parsed{value, p}, nil
}

func finish(env map[string]int, tokens []Token, start int) (Parsed, error) {
	parsed, err := parseExpr(env, tokens, start)
	if err != nil {
		return Parsed{}, err
	}
	if parsed.Pos < len(tokens) {
		return Parsed{}, errors.New("unexpected token")
	}
	return parsed, nil
}

func isAssignment(tokens []Token) bool {
	return len(tokens) >= 2 && tokens[0].Kind == Ident && isSym(tokens[1], '=')
}

func evaluate(env map[string]int, line string) (string, error) {
	tokens, err := tokenize(line)
	if err != nil {
		return "", err
	}
	if isAssignment(tokens) {
		parsed, err := finish(env, tokens, 2)
		if err != nil {
			return "", err
		}
		env[tokens[0].Name] = parsed.Value
		return fmt.Sprintf("%s = %d", tokens[0].Name, parsed.Value), nil
	}
	parsed, err := finish(env, tokens, 0)
	if err != nil {
		return "", err
	}
	return strconv.Itoa(parsed.Value), nil
}

func main() {
	env := map[string]int{}
	reader := bufio.NewReader(os.Stdin)
	for {
		raw, err := reader.ReadString('\n')
		if line := strings.TrimSpace(raw); line != "" {
			text, failure := evaluate(env, line)
			if failure != nil {
				fmt.Printf("error: %s\n", failure)
			} else {
				fmt.Println(text)
			}
		}
		if err != nil {
			break
		}
	}
}
