package main

import (
	"bufio"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

type Dept struct {
	Rows      int
	Total     int
	TopName   string
	TopSalary int
}

type Row struct {
	Name   string
	Dept   string
	Salary int
}

var integer = regexp.MustCompile(`^[+-]?[0-9]+$`)

func addRow(dept Dept, name string, salary int) Dept {
	if dept.Rows == 0 || salary > dept.TopSalary {
		return Dept{dept.Rows + 1, dept.Total + salary, name, salary}
	}
	return Dept{dept.Rows + 1, dept.Total + salary, dept.TopName, dept.TopSalary}
}

func parseRow(line string) (Row, error) {
	fields := strings.Split(line, ",")
	if len(fields) != 3 {
		return Row{}, fmt.Errorf("expected 3 fields, got %d", len(fields))
	}
	name := strings.TrimSpace(fields[0])
	dept := strings.TrimSpace(fields[1])
	text := strings.TrimSpace(fields[2])
	if name == "" {
		return Row{}, fmt.Errorf("empty name")
	}
	if dept == "" {
		return Row{}, fmt.Errorf("empty department")
	}
	salary, err := strconv.Atoi(text)
	if !integer.MatchString(text) || err != nil {
		return Row{}, fmt.Errorf("bad salary \"%s\"", text)
	}
	if salary < 0 {
		return Row{}, fmt.Errorf("negative salary")
	}
	return Row{name, dept, salary}, nil
}

func main() {
	depts := map[string]Dept{}
	rejected := 0
	reader := bufio.NewReader(os.Stdin)
	for number := 1; ; number++ {
		raw, err := reader.ReadString('\n')
		if line := strings.TrimSpace(raw); number > 1 && line != "" {
			row, problem := parseRow(line)
			if problem != nil {
				fmt.Printf("line %d: %s\n", number, problem)
				rejected++
			} else {
				depts[row.Dept] = addRow(depts[row.Dept], row.Name, row.Salary)
			}
		}
		if err != nil {
			break
		}
	}
	if len(depts) == 0 {
		fmt.Println("no rows")
	}
	names := make([]string, 0, len(depts))
	for name := range depts {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		d := depts[name]
		fmt.Printf("%s: %d rows, total %d, average %d, top %s\n", name, d.Rows, d.Total, d.Total/d.Rows, d.TopName)
	}
	fmt.Printf("rejected: %d\n", rejected)
}
