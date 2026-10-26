const net = require('node:net');
const assert = require('node:assert/strict');

const say = text => process.stdout.write(`${text}\n`);

function lines(socket, onLine) {
  let pending = '';
  socket.setEncoding('utf8');
  socket.on('data', chunk => {
    pending += chunk;
    let at;
    while ((at = pending.indexOf('\n')) >= 0) {
      onLine(pending.slice(0, at));
      pending = pending.slice(at + 1);
    }
  });
}

const handlers = {
  echo(socket) {
    lines(socket, line => socket.write(`${line}\n`));
    socket.on('end', () => socket.end());
  },
  fragments(socket) {
    const bytes = [...Buffer.from('ñ😀\n'), ...Buffer.from('tail')];
    let at = 0;
    const next = () => {
      if (socket.destroyed) return;
      if (at === bytes.length) return socket.end();
      socket.write(Buffer.from([bytes[at++]]));
      setTimeout(next, 5);
    };
    next();
  },
  reset(socket) {
    socket.once('data', () => socket.resetAndDestroy());
  },
  partial(socket) {
    socket.write('partial', () => setTimeout(() => socket.resetAndDestroy(), 50));
  },
  long(socket) {
    socket.write(Buffer.alloc(1048577, 'a'));
    socket.resume();
  },
  silent(socket) {
    socket.pause();
  },
  watch(socket) {
    socket.resume();
    socket.on('close', () => say('closed watch'));
  },
  collect(socket) {
    const chunks = [];
    socket.pause();
    setTimeout(() => socket.resume(), 300);
    socket.on('data', chunk => chunks.push(chunk));
    socket.on('end', () => {
      const runs = [];
      for (const byte of Buffer.concat(chunks)) {
        const last = runs[runs.length - 1];
        if (last && last[0] === byte) last[1] += 1;
        else runs.push([byte, 1]);
      }
      say(`collect ${runs.map(([byte, count]) => `${String.fromCharCode(byte)}=${count}`).join(' ')}`);
      socket.end();
    });
  },
};

async function listen(handler) {
  const server = net.createServer(socket => {
    socket.on('error', () => {});
    handler(socket);
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  return server;
}

async function servers() {
  const ports = {};
  for (const [name, handler] of Object.entries(handlers)) {
    ports[name] = (await listen(handler)).address().port;
  }
  say(JSON.stringify(ports));
}

function client(port, name, rounds) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(port, '127.0.0.1');
    const replies = [];
    socket.on('error', reject);
    lines(socket, line => {
      replies.push(line);
      if (replies.length < rounds) {
        const text = `${name}-${replies.length}\n`;
        socket.write(text.slice(0, 2));
        setTimeout(() => socket.write(text.slice(2)), 2);
      } else {
        socket.end();
      }
    });
    socket.on('close', () => {
      try {
        assert.deepEqual(replies, Array.from({ length: rounds }, (_, k) => `hello ${name}-${k}`));
        resolve();
      } catch (error) {
        reject(error);
      }
    });
    socket.once('connect', () => socket.write(`${name}-0\n`));
  });
}

async function clients(port) {
  await Promise.all([client(port, 'one', 20), client(port, 'two', 20)]);
  say('clients ok');
}

const [mode, port] = process.argv.slice(2);
const action = mode === 'clients' ? clients(Number(port)) : servers();
action.catch(error => { console.error(error); process.exitCode = 1; });
