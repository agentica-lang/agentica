"use strict";

const http = require("node:http");

function server() {
  const body = Buffer.from("hello\n");
  const missing = Buffer.from("not found\n");
  const s = http.createServer((req, res) => {
    const found = req.method === "GET" && req.url === "/";
    const text = found ? body : missing;
    res.writeHead(found ? 200 : 404, { "Content-Type": "text/plain; charset=utf-8", "Content-Length": text.length });
    res.end(text);
  });
  s.keepAliveTimeout = 30000;
  s.listen(0, "127.0.0.1", () => console.log(s.address().port));
}

function client(port, connections, requests) {
  const agent = new http.Agent({ keepAlive: true, maxSockets: connections });
  const each = Math.floor(requests / connections);
  const latencies = new Float64Array(each * connections);
  let at = 0;
  let failures = 0;
  let newSockets = 0;

  function once() {
    return new Promise((resolve, reject) => {
      const started = process.hrtime.bigint();
      const req = http.request({ host: "127.0.0.1", port, path: "/", agent }, (res) => {
        if (req.reusedSocket === false) newSockets++;
        let size = 0;
        res.on("data", (part) => (size += part.length));
        res.on("end", () => {
          if (res.statusCode !== 200 || size !== 6) failures++;
          latencies[at++] = Number(process.hrtime.bigint() - started) / 1e6;
          resolve();
        });
        res.on("error", reject);
      });
      req.on("error", reject);
      req.end();
    });
  }

  async function loop() {
    for (let k = 0; k < each; k++) await once();
  }

  const cpu = process.cpuUsage();
  const started = process.hrtime.bigint();
  Promise.all(Array.from({ length: connections }, loop)).then(
    () => {
      const seconds = Number(process.hrtime.bigint() - started) / 1e9;
      const used = process.cpuUsage(cpu);
      agent.destroy();
      console.log(JSON.stringify({
        requests: at,
        failures,
        new_sockets: newSockets,
        seconds,
        cpu: (used.user + used.system) / 1e6 / seconds,
        latencies: Array.from(latencies.subarray(0, at)),
      }));
    },
    (error) => {
      console.error(error);
      process.exit(1);
    },
  );
}

if (process.argv[2] === "server") {
  server();
} else {
  client(Number(process.argv[3]), Number(process.argv[4]), Number(process.argv[5]));
}
