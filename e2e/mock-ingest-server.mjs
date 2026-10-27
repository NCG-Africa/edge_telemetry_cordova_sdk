import { createServer } from 'node:http';

const PORT = Number(process.env.MOCK_INGEST_PORT ?? 4319);

const state = {
  payloads: [],
  requests: [],
};

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, X-API-Key',
};

function writeJson(res, status, body) {
  res.writeHead(status, {
    ...CORS_HEADERS,
    'Content-Type': 'application/json',
  });
  res.end(JSON.stringify(body));
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`);

  if (req.method === 'OPTIONS') {
    res.writeHead(204, CORS_HEADERS);
    res.end();
    return;
  }

  if (req.method === 'POST' && url.pathname === '/collector/telemetry') {
    const apiKey = req.headers['x-api-key'];
    const contentType = req.headers['content-type'];
    const rawBody = await readBody(req);

    let parsed = null;
    let parseError = null;
    try {
      parsed = JSON.parse(rawBody);
    } catch (err) {
      parseError = err.message;
    }

    state.requests.push({
      method: req.method,
      path: url.pathname,
      headers: {
        'x-api-key': typeof apiKey === 'string' ? apiKey : null,
        'content-type': typeof contentType === 'string' ? contentType : null,
      },
      rawBody,
      parsed,
      parseError,
      receivedAt: new Date().toISOString(),
    });

    if (parsed !== null) {
      state.payloads.push(parsed);
    }

    if (typeof apiKey !== 'string' || apiKey.length === 0) {
      writeJson(res, 401, { error: 'missing X-API-Key' });
      return;
    }

    writeJson(res, 200, { ok: true });
    return;
  }

  if (req.method === 'GET' && url.pathname === '/__state') {
    writeJson(res, 200, state);
    return;
  }

  if (req.method === 'GET' && url.pathname === '/__payloads') {
    writeJson(res, 200, { payloads: state.payloads });
    return;
  }

  if (req.method === 'GET' && url.pathname === '/__requests') {
    writeJson(res, 200, { requests: state.requests });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/__reset') {
    state.payloads = [];
    state.requests = [];
    writeJson(res, 200, { ok: true });
    return;
  }

  if (req.method === 'GET' && url.pathname === '/__health') {
    writeJson(res, 200, { ok: true });
    return;
  }

  writeJson(res, 404, { error: 'not found' });
});

server.listen(PORT, () => {
  console.log(`[mock-ingest] listening on http://localhost:${PORT}`);
});
