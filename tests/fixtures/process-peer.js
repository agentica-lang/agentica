const mode = process.argv[2];
const args = process.argv.slice(3);
if (mode === "probe") {
  try { process.kill(Number(args[0]), 0); process.exit(0); }
  catch { process.exit(1); }
} else if (mode === "args") {
  process.stdout.write(JSON.stringify(args) + "\n");
} else if (mode === "echo") {
  process.stderr.write("peer stderr\n");
  process.stdin.pipe(process.stdout);
} else if (mode === "exit") {
  process.stdout.write("done\r\nlast", () => process.exit(7));
} else if (mode === "invalid") {
  process.stdout.write(Buffer.from([255, 10]));
  process.stdout.write("valid\n");
} else if (mode === "oversized") {
  process.stdout.write(Buffer.alloc(1048577, 65));
  process.stdout.write("\n");
} else if (mode === "flood") {
  process.stdout.write(Buffer.alloc(2097152, 65), () => process.exit(0));
} else if (mode === "stderr") {
  process.stderr.write(Buffer.alloc(2097152, 115), () => process.exit(0));
} else if (mode === "stubborn") {
  process.on("SIGTERM", () => {});
  process.stdout.write(String(process.pid) + "\n");
  setInterval(() => {}, 1000);
} else if (mode === "hold" || mode === "release") {
  process.stdout.write(String(process.pid) + "\n");
  setInterval(() => {}, 1000);
  if (mode === "release") {
    process.stdin.on("data", () => process.exit(3));
  }
} else {
  process.exit(2);
}
