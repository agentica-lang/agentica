// Runs a command as a child that owns a channel, the Node twin of channel-run.py for Windows (where Python cannot
// give a child two pipes at descriptors 3 and 4): node channel-run.js FEED COMMAND...
//
// FEED is a file of lines. The peer sends the first line to the channel, and each line the child answers brings the
// next one; after the last line it closes its end, so the child reads the end of its input. The stdout of the
// child is a file, which the peer copies to its own stdout whenever a line of the channel arrives, and at the end; each
// line of the channel is written as "channel> LINE" after the stdout that came before it (the reasons that the order is
// the true one: child_channel.js). The child's stdin and stderr are the ones of this program, and its exit status is
// the one of this program.
"use strict";
const fs = require("fs");
const { launch, watchdog, writeAll } = require("./child_channel.js");

const PREFIX = Buffer.from("channel> ");
const NEWLINE = Buffer.from("\n");

async function main(peers) {
  const [feedFile, ...command] = process.argv.slice(2);
  const pending = fs
    .readFileSync(feedFile)
    .toString("latin1")
    .split("\n")
    .filter((line) => line !== "")
    .map((line) => Buffer.from(line + "\n", "latin1"));
  watchdog(100000);
  const peer = launch(command, { stdin: "inherit", stderr: "inherit", stdout: "file" });
  peers.push(peer);

  // The input of the child ends after the last line, once the write is done: a destroy would drop what is queued.
  let closed = false;
  const feed = () => {
    if (closed) return;
    const sent = pending.length > 0 ? peer.send(pending.shift()) : Promise.resolve();
    if (pending.length === 0) {
      closed = true;
      sent.then(() => peer.endInput());
    }
  };

  let buffer = Buffer.alloc(0);
  peer.fromChild.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    for (let at = buffer.indexOf(10); at >= 0; at = buffer.indexOf(10)) {
      // The stdout written before the record, and then the record.
      writeAll(1, peer.takeStdout());
      writeAll(1, Buffer.concat([PREFIX, buffer.subarray(0, at), NEWLINE]));
      buffer = buffer.subarray(at + 1);
      feed();
    }
  });
  feed();

  const code = await peer.exited;
  writeAll(1, peer.takeStdout());
  if (buffer.length > 0) writeAll(1, Buffer.concat([PREFIX, buffer, NEWLINE]));
  peer.close();
  process.exitCode = code === null ? 128 + 9 : code;
}

// The VM that main started, for the catch below.
const started = [];
main(started).catch((error) => {
  console.error(error);
  for (const peer of started) peer.child.kill();
  process.exitCode = 1;
});
