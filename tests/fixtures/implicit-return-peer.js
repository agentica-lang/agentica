// The peer of tests/fixtures/vm/implicit-return.agc in Node: the same functions, as arrow functions whose body is the
// value, which is the rule of the fixture.
const area = (shape) =>
  shape[0] === "square" ? shape[1] * shape[1]
    : shape[0] === "rect" ? shape[1] * shape[2]
      : area(shape[1]) + area(shape[2]);

const label = (n) => {
  if (n === 0) return "none";
  return n === 1 ? "one"
    : n < 0 ? (n === -1 ? "minus one" : n < -100 ? "far below" : "below")
      : `${n} items`;
};

const fib = (n) => (n < 2 ? n : fib(n - 1) + fib(n - 2));
const twice = (item) => [item, item];
const parsed = (text) => (/^-?\d+$/.test(text) ? ["ok", Number(text) + 1] : ["error", null]);
const shown = (result) => (result[0] === "ok" ? `ok ${result[1]}` : "error");
const square = (n) => n * n;

const lines = [area(["square", 3]), area(["pair", ["rect", 2, 5], ["square", 1]])];
for (const n of [0, 1, -1, -5, -500, 7]) lines.push(label(n));
lines.push(fib(15), twice("ab").join(","), shown(parsed("41")), shown(parsed("x")), square(12), "say done");
process.stdout.write(lines.join("\n") + "\n");
