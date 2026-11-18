package main

import (
	"bufio"
	"fmt"
	"log"
	"os"
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

func addRow(dept Dept, name string, salary int) Dept {
	if dept.Rows == 0 || salary > dept.TopSalary {
		return Dept{dept.Rows + 1, dept.Total + salary, name, salary}
	}
	return Dept{dept.Rows + 1, dept.Total + salary, dept.TopName, dept.TopSalary}
}

func main() {
	depts := map[string]Dept{}
	header := true
	reader := bufio.NewReader(os.Stdin)
	for {
		raw, err := reader.ReadString('\n')
		line := strings.TrimSpace(raw)
		if header {
			header = false
		} else if line != "" {
			fields := strings.Split(line, ",")
			name := strings.TrimSpace(fields[0])
			dept := strings.TrimSpace(fields[1])
			salary, failure := strconv.Atoi(strings.TrimSpace(fields[2]))
			if failure != nil {
				log.Fatal(failure)
			}
			depts[dept] = addRow(depts[dept], name, salary)
		}
		if err != nil {
			break
		}
	}
	if len(depts) == 0 {
		fmt.Println("no rows")
		return
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
}
