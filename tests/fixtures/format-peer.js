// The peer of tests/fixtures/vm/format.agc in Node: the same lines, with each conversion written by hand. A %f rounds
// the exact binary value half to even with BigInt, since toFixed rounds a tie up and stops at 100 digits.
"use strict";

const chars = (s) => [...s].length;

function pad(text, width, left, zero) {
  const missing = width - chars(text);
  if (missing <= 0) return text;
  if (left) return text + " ".repeat(missing);
  if (zero) {
    const sign = text.startsWith("-") ? "-" : "";
    return sign + "0".repeat(missing) + text.slice(sign.length);
  }
  return " ".repeat(missing) + text;
}

function int(n, base) {
  const big = BigInt(n);
  return big < 0n ? "-" + (-big).toString(base) : big.toString(base);
}

function fixed(x, digits) {
  if (Number.isNaN(x)) return "NaN";
  if (!Number.isFinite(x)) return x > 0 ? "Inf" : "-Inf";
  const view = new DataView(new ArrayBuffer(8));
  view.setFloat64(0, x);
  const bits = view.getBigUint64(0);
  const negative = bits >> 63n === 1n;
  const exponent = Number((bits >> 52n) & 0x7ffn);
  let mantissa = bits & ((1n << 52n) - 1n);
  let power = -1074;
  if (exponent > 0) {
    mantissa |= 1n << 52n;
    power = exponent - 1075;
  }
  let num = mantissa * 10n ** BigInt(digits);
  let den = 1n;
  if (power >= 0) num <<= BigInt(power);
  else den <<= BigInt(-power);
  let q = num / den;
  const twice = 2n * (num % den);
  if (twice > den || (twice === den && q % 2n === 1n)) q += 1n;
  const all = q.toString().padStart(digits + 1, "0");
  const whole = all.slice(0, all.length - digits);
  return (negative ? "-" : "") + (digits > 0 ? whole + "." + all.slice(all.length - digits) : whole);
}

// %[-][0][width][.digits]f; NaN and the infinities pad with spaces only.
function f(x, digits = 6, width = 0, left = false, zero = false) {
  return pad(fixed(x, digits), width, left, zero && Number.isFinite(x));
}

const row = (name, price, count) =>
  `${pad(name, 8, true)}|${f(price, 3, 8)}|${pad(int(count, 10), 4, false, true)}|${int(count, 16)}`;

const lines = [];
lines.push(row("apple", 2.5, 7));
lines.push(row("crème", -0.125, -255));
lines.push(`[42] [${pad("-42", 5)}] [${pad("-42", 5, true)}] [${pad("-42", 5, false, true)}] [${pad("42", 5, true)}] [7]`);
lines.push(`[ff] [${pad("-ff", 6)}] [${pad("beef", 6, true)}] [${pad("-1", 6, false, true)}] [0] ` +
  `[${int(-(2n ** 63n), 16)}]`);
lines.push(`[${pad(int(2n ** 63n - 1n, 10), 20)}] [${pad(int(-(2n ** 63n), 10), 21, true)}]`);
for (const x of [0.5, 1.5, 2.5, 2.675, 1.005, -0.5, -0.0, 0.125, 1e-7, 123456.789]) {
  lines.push([f(x), f(x, 0), f(x, 1), f(x, 2), f(x, 3), f(x, 4, 10), f(x, 1, 10, true), f(x, 2, 10, false, true)]
    .join("|"));
}
lines.push(f(0.1, 50));
lines.push(`${f(1 / 3, 17)}|${f(2 / 3, 20)}`);
lines.push(f(1.7976931348623157e308, 1));
lines.push(`${f(5e-324, 3)}|${f(1e22, 0)}`);
lines.push(`[${f(NaN)}] [${f(NaN, 2, 6)}] [${f(Infinity, 6, 6, true)}] [${f(Infinity, 6, 6, false, true)}] ` +
  `[${f(-Infinity)}] [${f(-Infinity, 1, 7, false, true)}]`);
lines.push(`[héllo] [${pad("héllo", 7)}] [${pad("日本", 7, true)}] [${pad("toolong", 3)}] [[1, 2]]`);
lines.push(`100% of x is ${f(99.95, 1, 5)}%`);
let n = 5;
n = chars(`${pad(int(n * 2, 10), 3)}|${n}`);
lines.push(String(n));
lines.push(`in ${pad(String(n), 3, false, true)} text`);
lines.push(f(3.14159, 2));
process.stdout.write(lines.join("\n") + "\n");
