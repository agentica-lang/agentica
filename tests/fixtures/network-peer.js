const net = require('node:net');
const tls = require('node:tls');
const http = require('node:http');
const https = require('node:https');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

const certs = path.join(__dirname, 'tls');
const credentials = () => ({
  cert: fs.readFileSync(path.join(certs, 'server.pem')),
  key: fs.readFileSync(path.join(certs, 'server-key.pem')),
});

function echo(socket) {
  socket.on('error', () => {});
  socket.on('data', data => data.equals(Buffer.from('EOF')) ? socket.end() : socket.write(data));
}

let connection = 0;
let stalledConnections = 0;
const stalledSockets = new Set();
function handler(req, res) {
  req.on('error', () => {});
  res.on('error', () => {});
  req.socket.peerId ??= ++connection;
  res.setHeader('X-Connection', String(req.socket.peerId));
  res.setHeader('Set-Cookie', ['one=1', 'two=2']);
  if (req.url === '/pending-tls') {
    const timer = setTimeout(() => res.end(`${stalledConnections}:${stalledSockets.size}`), 250);
    res.on('close', () => clearTimeout(timer));
  } else if (req.url === '/chunked') {
    res.write('ñ');
    res.addTrailers({ 'X-Trailer': 'finished' });
    res.end('😀');
  } else if (req.url === '/echo') {
    req.pipe(res);
  } else if (req.url === '/early') {
    res.writeHead(413, { 'Connection': 'close' });
    res.end('too big');
  } else if (req.url === '/duplex') {
    req.once('data', () => res.write('first'));
    req.on('end', () => res.end('last'));
    req.resume();
  } else if (req.url === '/empty') {
    res.writeHead(204);
    res.end();
  } else if (req.url === '/close') {
    res.setHeader('Connection', 'close');
    res.end('close');
  } else if (req.url === '/slow') {
    const timer = setTimeout(() => res.end('late'), 1000);
    res.on('close', () => clearTimeout(timer));
  } else if (req.url === '/stalled') {
    res.flushHeaders();
    const timer = setTimeout(() => res.end('late'), 1000);
    res.on('close', () => clearTimeout(timer));
  } else {
    const body = 'hello';
    res.setHeader('Content-Length', Buffer.byteLength(body));
    res.end(body);
  }
}

async function listen(server) {
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  return server.address().port;
}

async function peers() {
  const tcp = net.createServer(echo);
  const secureTcp = tls.createServer(credentials(), echo);
  const web = http.createServer(handler);
  const secureWeb = https.createServer(credentials(), handler);
  secureTcp.on('tlsClientError', () => {});
  secureWeb.on('tlsClientError', () => {});
  const raw = net.createServer(socket => {
    socket.on('error', () => {});
    socket.once('data', data => {
      const route = data.toString('latin1').split(' ')[1];
      const messages = {
        '/ambiguous': 'HTTP/1.1 200 OK\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n',
        '/truncated': 'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhi',
        '/version': 'HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n',
        '/eof': 'HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nuntil eof',
      };
      socket.end(messages[route] || 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n');
    });
  });
  const ports = {};
  for (const [name, server] of Object.entries({ tcp, tls: secureTcp, http: web, https: secureWeb, raw })) {
    ports[name] = await listen(server);
  }
  let accepted = 0;
  const delayedTls = net.createServer(socket => {
    socket.on('error', () => {});
    if (++accepted === 1) {
      const upstream = net.connect(ports.https, '127.0.0.1');
      upstream.on('error', () => socket.destroy());
      socket.on('close', () => upstream.destroy());
      socket.pipe(upstream).pipe(socket);
    } else {
      stalledConnections++;
      stalledSockets.add(socket);
      socket.on('close', () => stalledSockets.delete(socket));
      socket.resume();
    }
  });
  ports.delayedTls = await listen(delayedTls);
  console.log(JSON.stringify(ports));
}

function request(port, secure, route, body, agent, method = 'GET') {
  return new Promise((resolve, reject) => {
    const req = (secure ? https : http).request({
      host: '127.0.0.1', port, path: route,
      method: body === undefined ? method : 'POST', agent,
      servername: 'localhost', ca: fs.readFileSync(path.join(certs, 'ca.pem')),
    }, res => {
      const localPort = req.socket.localPort;
      const chunks = [];
      res.on('data', data => chunks.push(data));
      res.on('error', reject);
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8'),
                                   trailers: res.trailers, port: localPort }));
    });
    req.on('error', error => reject(new Error(`${route}: ${error.message}`, { cause: error })));
    if (body !== undefined) req.write(body);
    req.end();
  });
}

async function clients(port, secure) {
  const agent = new (secure ? https : http).Agent({ keepAlive: true, maxSockets: 1 });
  try {
    const first = await request(port, secure, '/stream', undefined, agent);
    const second = await request(port, secure, '/stream', undefined, agent);
    assert.equal(first.body, 'ñ😀');
    assert.equal(first.trailers['x-trailer'], 'finished');
    assert.equal(first.port, second.port);
    const head = await request(port, secure, '/stream', undefined, agent, 'HEAD');
    assert.equal(head.body, '');
    const missing = await request(port, secure, '/missing', undefined, agent);
    assert.equal(missing.status, 404);
    assert.equal(missing.body, 'missing');
    assert.equal(missing.port, first.port);
    const echo = await request(port, secure, '/echo', 'upload ñ😀', agent);
    assert.equal(echo.body, 'upload ñ😀');
    const empty = await request(port, secure, '/empty', undefined, agent);
    assert.equal(empty.status, 204);
    assert.equal(empty.body, '');
    const transport = secure ? https : http;
    const options = { host: '127.0.0.1', port, path: '/echo', method: 'POST',
      servername: 'localhost', ca: fs.readFileSync(path.join(certs, 'ca.pem')) };
    await new Promise((resolve, reject) => {
      const req = transport.request(options, res => {
        let text = '';
        let finished = false;
        res.on('data', chunk => {
          text += chunk.toString('utf8');
          if (!finished && text === 'first') {
            finished = true;
            req.end('last');
          }
        });
        res.on('error', reject);
        res.on('end', () => {
          try { assert.equal(text, 'firstlast'); resolve(); } catch (error) { reject(error); }
        });
      });
      req.on('error', reject);
      req.write('first');
    });
    await new Promise((resolve, reject) => {
      const req = transport.request(options, res => {
        let text = '';
        res.on('data', chunk => { text += chunk.toString('utf8'); });
        res.on('end', () => {
          try { assert.equal(text, 'released'); resolve(); } catch (error) { reject(error); }
        });
        res.on('error', reject);
      });
      req.on('error', reject);
      req.flushHeaders();
      request(port, secure, '/stream', undefined, agent).then(() => req.end('released'), reject);
    });
    for (const [message, status] of [
      ['GET / HTTP/1.0\r\nHost: localhost\r\n\r\n', 505],
      ['GET / HTTP/1.1\r\n\r\n', 400],
      ['POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n', 400],
      ['POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n', 400],
      ['POST /echo HTTP/1.1\r\nHost: localhost\r\nExpect: magic\r\nContent-Length: 0\r\n\r\n', 417],
    ]) {
      const text = await rawRequest(port, secure, message);
      assert.ok(text.startsWith(`HTTP/1.1 ${status} `), text);
    }
    assert.equal((await request(port, secure, '/stream', undefined, agent)).body, 'ñ😀');
    console.log('clients ok');
  } finally {
    agent.destroy();
  }
}

function rawRequest(port, secure, message) {
  return new Promise((resolve, reject) => {
    const socket = secure
      ? tls.connect({ host: '127.0.0.1', port, servername: 'localhost', ca: fs.readFileSync(path.join(certs, 'ca.pem')) })
      : net.connect(port, '127.0.0.1');
    let text = '';
    socket.on('error', reject);
    socket.on('data', data => { text += data.toString('latin1'); });
    socket.on('end', () => resolve(text));
    socket.once(secure ? 'secureConnect' : 'connect', () => socket.write(message));
  });
}

async function tcpClient(port, secure) {
  await new Promise((resolve, reject) => {
    const socket = secure
      ? tls.connect({ host: '127.0.0.1', port, servername: 'localhost', ca: fs.readFileSync(path.join(certs, 'ca.pem')) })
      : net.connect(port, '127.0.0.1');
    let data = Buffer.alloc(0);
    socket.on('error', reject);
    socket.on('data', chunk => { data = Buffer.concat([data, chunk]); });
    socket.on('end', () => {
      try { assert.equal(data.toString('utf8'), 'ñ😀\n'); resolve(); } catch (error) { reject(error); }
    });
    socket.once(secure ? 'secureConnect' : 'connect', () => {
      const bytes = Buffer.from('ñ😀\n');
      socket.write(bytes.subarray(0, 1));
      setImmediate(() => socket.write(bytes.subarray(1)));
    });
  });
  console.log('tcp client ok');
}

const [mode, port, secure] = process.argv.slice(2);
const action = mode === 'client' ? clients(Number(port), secure === 'tls')
  : mode === 'tcp-client' ? tcpClient(Number(port), secure === 'tls') : peers();
action.catch(error => { console.error(error); process.exitCode = 1; });
