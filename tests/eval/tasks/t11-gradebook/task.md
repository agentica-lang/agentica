# Task: extend a gradebook

`start.agc` (or `start.py` for Python) reads scores from standard input until
EOF and prints each student's average. Each line is `student subject score`,
separated by single spaces (leading and trailing whitespace is allowed, blank
lines are ignored). `score` is an integer from 0 to 100. A student can have
several scores, also in the same subject. Averages drop the fraction (integer
division). With no scores at all the program prints `no scores`.

Change the program to add the three features below, and save the result as
`solution.agc` (or `solution.py`). Keep every other behavior as it is.

1. Weights. A line `weight SUBJECT W` (`W` is a positive integer) gives a
   subject a weight. Such a line can come anywhere in the input, also after the
   scores, and the last weight given for a subject counts for all of its scores.
   A subject without a weight has weight 1. An average is now `sum(score *
   weight) / sum(weight)` over a student's scores, with integer division. The
   class average is the same formula over all scores of all students.
2. Ranking. Print the students from the highest average to the lowest, students
   with equal averages ordered by name. Each line starts with the rank: `1. ana:
   85`. Ranks are 1, 2, 3, ... with no sharing for ties.
3. Letter grades. Each student line ends with a letter for the average: `A` for
   90 or more, `B` for 80 or more, `C` for 70 or more, `D` for 60 or more, `F`
   below 60. So a line is `1. ana: 85 B`. The `class:` line stays `class:
   <average>`, with no rank and no letter.

Example input:

```text
weight math 3
ana math 90
ana art 70
bob art 95
bob math 60
cy art 70
```

Example output:

```text
1. ana: 85 B
2. cy: 70 C
3. bob: 68 D
class: 76
```

Test it with your own input before you finish, including empty input.
