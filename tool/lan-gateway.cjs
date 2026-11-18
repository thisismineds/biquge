const http = require('node:http');
const { BlockList, isIPv4 } = require('node:net');
const { networkInterfaces } = require('node:os');
const { pipeline } = require('node:stream');

function findLanAddress(host) {
  return Object.values(networkInterfaces()).flat().find((entry) =>
    entry.family === 'IPv4' && !entry.internal && entry.address === host);
}

function replyError(response, status, error) {
  response.writeHead(status, {
    'Content-Type': 'application/json',
    'Cache-Control': 'no-store',
    Connection: 'close',
  });
  response.end(JSON.stringify({ error }));
}

function createGateway(upstreamPort = 8766, allowedClient) {
  const allowedPeers = new BlockList();
  if (allowedClient) {
    const [address, prefix] = allowedClient.split('/');
    if (prefix === undefined) allowedPeers.addAddress(address);
    else allowedPeers.addSubnet(address, Number(prefix));
  }
  return http.createServer({ requestTimeout: 10_000, connectionsCheckingInterval: 1000 }, (request, response) => {
    if (allowedClient && !allowedPeers.check(request.socket.remoteAddress)) {
      replyError(response, 403, 'Client address not allowed');
      return;
    }

    const { method, url, headers } = request;
    const health = method === 'GET' && url === '/health';
    const synthesize = method === 'POST' && url === '/synthesize';
    if (!health && !synthesize) {
      replyError(response, 404, 'Unknown endpoint');
      return;
    }

    const length = headers['content-length'];
    if (headers['transfer-encoding'] || (health && length && length !== '0')) {
      replyError(response, 400, 'Invalid body framing');
      return;
    }

    const upstreamHeaders = {};
    if (synthesize) {
      const contentType = headers['content-type'];
      if (contentType?.split(';', 1)[0].trim().toLowerCase() !== 'application/json') {
        replyError(response, 415, 'Expected application/json');
        return;
      }
      if (!length || !/^\d+$/.test(length)) {
        replyError(response, 400, 'Expected one valid Content-Length');
        return;
      }
      if (length.length > 4 || Number(length) > 4096) {
        replyError(response, 413, 'Request exceeds 4096 bytes');
        return;
      }
      upstreamHeaders['content-type'] = contentType;
      upstreamHeaders['content-length'] = length;
    }

    const upstream = http.request({
      hostname: '127.0.0.1', port: upstreamPort, method, path: url, headers: upstreamHeaders,
    });
    upstream.on('response', (result) => {
      response.setHeader('x-qingyue-service', 'tts');
      for (const name of ['content-type', 'content-length', 'cache-control', 'x-synthesis-seconds', 'x-audio-seconds']) {
        if (result.headers[name] !== undefined) response.setHeader(name, result.headers[name]);
      }
      response.writeHead(result.statusCode);
      pipeline(result, response, () => {});
    });
    upstream.on('error', () => {
      if (response.destroyed || response.writableEnded) return;
      if (response.headersSent) response.destroy();
      else replyError(response, 502, 'Local speech engine unavailable');
    });
    upstream.setTimeout(60_000, () => {
      if (!response.headersSent && !response.destroyed) {
        replyError(response, 504, 'Local speech engine timed out');
      }
      upstream.destroy();
    });
    response.on('close', () => {
      if (!response.writableFinished) upstream.destroy();
    });
    request.on('error', () => upstream.destroy());
    request.pipe(upstream);
  });
}

if (require.main === module) {
  const [host, portArg = '8767', allowedClient] = process.argv.slice(2);
  const port = Number(portArg);
  const lanAddress = findLanAddress(host);
  if (!lanAddress || !/^\d+$/.test(portArg) || port < 1 || port > 65535 ||
      (allowedClient !== undefined && !isIPv4(allowedClient))) {
    console.error('Usage: node lan-gateway.cjs <local LAN IPv4 address> [port] [allowed client IPv4 address]');
    process.exit(1);
  }

  const allowedPeers = allowedClient ?? lanAddress.cidr;
  if (!allowedPeers) {
    console.error('Could not determine the LAN subnet for the selected IPv4 address');
    process.exit(1);
  }
  const server = createGateway(undefined, allowedPeers);
  server.on('error', (error) => {
    console.error(`Could not start Qingyue LAN gateway (${error.code})`);
    process.exitCode = 1;
  });
  server.listen(port, host, () => {
    console.log(`Qingyue LAN gateway ready on http://${host}:${port} for ${allowedPeers}`);
  });
}

module.exports = { createGateway, findLanAddress };
