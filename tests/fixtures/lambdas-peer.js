// The peer of tests/fixtures/vm/lambdas.agc in Node: the same function values, as arrow functions and closures.
const add = (a, b, c) => a + b + c;
const applyTwice = (f, x) => f(f(x));
const compose = (f, g, x) => g(f(x));
const adder = (n) => (x) => x + n;
const toI = (text) => (/^-?\d+$/.test(text) ? ["ok", Number(text)] : ["error", `cannot convert "${text}" to Int`]);

const parseDouble = (text) => {
  const doubled = (s) => {
    const result = toI(s);
    return result[0] === "error" ? result : ["ok", result[1] * 2];
  };
  return doubled(text);
};

const shown = (result) => (result[0] === "ok" ? `ok(${result[1]})` : `error("${result[1].replaceAll('"', '\\"')}")`);

const sign = (x) => {
  if (x < 0) return "negative";
  return "not negative";
};

const lines = [];
const c = 100;
const f = (a, b) => add(a, b, c);
lines.push(f(1, 2));
const base = 10;
const inc = (x) => x + base;
lines.push(inc(5));
const answer = () => 42;
lines.push(answer());
const gen = { name: "next", make: (seed) => seed + 1 };
lines.push(`${gen.name} ${gen.make(1)}`);
const ops = { add: (a, b) => a + b, sub: (a, b) => a - b };
lines.push(ops.add(2, 3));
lines.push(ops.sub(2, 3));
const steps = [(x) => x + 1, (x) => x * 3];
lines.push(`[${steps.map((step) => step(2)).join(", ")}]`);
lines.push(applyTwice((x) => x * x, 3));
lines.push(compose((n) => `${n}!`, (s) => s.length, 12345));
lines.push(adder(7)(1));
lines.push(sign(-3));
lines.push(sign(4));
const curried = (a) => (b) => a * 10 + b;
lines.push(curried(4)(2));
const labels = [1, 2].map((n) => {
  const label = (suffix) => `${n}${suffix}`;
  return label("st");
});
lines.push(`[${labels.map((text) => `"${text}"`).join(", ")}]`);
lines.push(shown(parseDouble("21")));
lines.push(shown(parseDouble("x")));
const xs = [1, 2, 3];
lines.push(xs.map((x) => x * 2).reduce((acc, x) => acc + x, 0));
lines.push(xs.map((x) => x * 2).filter((x) => x > 2).reduce((acc, x) => acc + x, 0));
xs.forEach((x) => lines.push(x * c));
lines.push(xs.reduce((acc, x) => acc + x, 0));
Object.entries({ a: 1, b: 2 }).forEach(([key, value]) => lines.push(`${key}=${value}`));
// The program's own first wins over the method of that name.
const first = (list) => `first of ${list.length}`;
lines.push(first(xs));
lines.push(xs[0]);
process.stdout.write(lines.join("\n") + "\n");
