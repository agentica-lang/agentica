"use strict";

const http = require("node:http");

const port = Number(process.argv[2]);
const limit = Number(process.argv[3]);

function call(options, write) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: "127.0.0.1", port, timeout: 10000, ...options }, (res) => {
      const parts = [];
      res.on("data", (part) => parts.push(part));
      res.on("end", () => resolve({ res, req, body: Buffer.concat(parts).toString("utf8") }));
      res.on("error", reject);
    });
    req.on("error", reject);
    req.on("timeout", () => req.destroy(new Error("timeout")));
    write(req);
  });
}

async function main() {
  const chunked = await call({ method: "POST", path: "/chunked", agent: false }, (req) => {
    req.write("ab");
    req.write("ñ");
    req.end("cd");
  });
  console.log("node-chunked", chunked.res.statusCode, chunked.req.chunkedEncoding, chunked.body);

  // A body that is not UTF-8, in chunks (no Content-Length): the handler gets the bytes as they are.
  const binary = await call({ method: "POST", path: "/binary", agent: false }, (req) => {
    req.write(Buffer.from([0xff]));
    req.end(Buffer.from([0x00, 0x80]));
  });
  console.log("node-binary", binary.res.statusCode, binary.req.chunkedEncoding, binary.body);

  let continued = false;
  const expect = await call(
    { method: "POST", path: "/expect", agent: false, headers: { Expect: "100-continue", "Content-Length": 5 } },
    (req) => {
      req.on("continue", () => {
        continued = true;
        req.end("hello");
      });
    },
  );
  console.log("node-expect", continued, expect.res.statusCode, expect.body);

  const agent = new http.Agent({ keepAlive: true, maxSockets: 1 });
  const first = await call({ path: "/first", agent }, (req) => req.end());
  const head = await call({ method: "HEAD", path: "/head", agent }, (req) => req.end());
  const again = await call({ path: "/again", agent }, (req) => req.end());
  console.log("node-keep-alive", first.body, again.body, head.req.reusedSocket, again.req.reusedSocket);
  console.log("node-head", head.res.statusCode, head.res.headers["content-length"], JSON.stringify(head.body));
  agent.destroy();

  const many = [];
  for (let k = 0; k <= limit; k++) {
    many.push(call({ path: `/many${k}`, agent: false, headers: { Connection: "close" } }, (req) => req.end()));
  }
  const done = await Promise.all(many);
  console.log("node-concurrent", done.length, done.every((r) => r.res.statusCode === 200));
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
