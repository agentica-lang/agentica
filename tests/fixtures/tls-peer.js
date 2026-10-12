const net = require('node:net');
const tls = require('node:tls');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

const say = text => process.stdout.write(`${text}\n`);
const certs = path.join(__dirname, 'tls');
const read = name => fs.readFileSync(path.join(certs, name));
const pair = name => ({ cert: read(`${name}.pem`), key: read(`${name}-key.pem`) });

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

const secure = {
  echo: [pair('server'), socket => {
    lines(socket, line => socket.write(`${line}\n`));
    socket.on('end', () => socket.end());
  }],
  fragments: [pair('server'), socket => {
    const bytes = [...Buffer.from('ñ😀\n'), ...Buffer.from('tail')];
    let at = 0;
    const next = () => {
      if (socket.destroyed) return;
      if (at === bytes.length) return socket.end();
      socket.write(Buffer.from([bytes[at++]]), next);
    };
    next();
  }],
  abrupt: [pair('server'), (socket, raw) => {
    socket.write('abc\npartial', () => raw.destroy());
  }],
  reset: [pair('server'), (socket, raw) => {
    socket.once('data', () => raw.resetAndDestroy());
  }],
  big: [pair('server'), socket => {
    lines(socket, line => socket.write(`${line.length} ${line === 'b'.repeat(line.length)}\n`));
    socket.write(`${'a'.repeat(100000)}\n`);
    socket.on('end', () => socket.end());
  }],
  long: [pair('server'), socket => {
    socket.write(Buffer.alloc(1048577, 'a'));
    socket.resume();
  }],
  silent: [pair('server'), socket => socket.pause()],
  wrong: [pair('wrong-host'), socket => socket.end()],
  expired: [pair('expired'), socket => socket.end()],
  self: [pair('self-signed'), socket => socket.end()],
  old: [{ ...pair('server'), minVersion: 'TLSv1', maxVersion: 'TLSv1.1', ciphers: 'DEFAULT@SECLEVEL=0' }, socket => socket.end()],
};

const plain = {
  stall: socket => socket.pause(),
  plain: socket => {
    socket.write('hello\n');
    socket.resume();
  },
};

async function listen(server) {
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  return server.address().port;
}

async function servers() {
  const ports = {};
  for (const [name, [options, handler]] of Object.entries(secure)) {
    const secureContext = tls.createSecureContext(options);
    ports[name] = await listen(net.createServer(raw => {
      raw.on('error', () => {});
      const socket = new tls.TLSSocket(raw, { isServer: true, secureContext });
      socket.on('error', () => {});
      socket.once('secure', () => handler(socket, raw));
    }));
  }
  for (const [name, handler] of Object.entries(plain)) {
    ports[name] = await listen(net.createServer(socket => {
      socket.on('error', () => {});
      handler(socket);
    }));
  }
  say(JSON.stringify(ports));
}

function client(port, name, rounds, options) {
  return new Promise((resolve, reject) => {
    const socket = tls.connect({ port, host: '127.0.0.1', servername: 'localhost', ca: read('ca.pem'), ...options });
    const replies = [];
    socket.on('error', reject);
    lines(socket, line => {
      replies.push(line);
      if (replies.length < rounds) {
        const text = `${name}-${replies.length}\n`;
        socket.write(text.slice(0, 2), () => socket.write(text.slice(2)));
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
    socket.once('secureConnect', () => {
      assert.equal(socket.authorized, true);
      socket.write(`${name}-0\n`);
    });
  });
}

function untrusting(port) {
  return new Promise(resolve => {
    const socket = tls.connect({ port, host: '127.0.0.1', servername: 'localhost' });
    socket.on('error', error => resolve(error.code));
    socket.on('secureConnect', () => resolve('connected'));
  });
}

async function clients(port) {
  await Promise.all([client(port, 'one', 20, {}), client(port, 'two', 20, { maxVersion: 'TLSv1.2' })]);
  say('clients ok');
  say(`untrusting ${await untrusting(port)}`);
}

const [mode, port] = process.argv.slice(2);
const action = mode === 'clients' ? clients(Number(port)) : servers();
action.catch(error => { console.error(error); process.exitCode = 1; });
