// Minimal HTTP server — listens on port 8080
const http = require('http');

const server = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({
    status: 'ok', path: req.url, microvm: {
      image_name: process.env.AWS_LAMBDA_MICROVM_IMAGE_NAME || 'n/a',
      image_version: process.env.AWS_LAMBDA_MICROVM_IMAGE_VERSION || 'n/a'
  } }));
});

server.listen(8080, () => {
  console.log('Listening on port 8080');
  // console.log(process.env)
});

// --- Lifecycle hook server (port 9000) ------------------------------------
// Lambda MicroVMs POSTs to /aws/lambda-microvms/runtime/v1/{ready,validate,
// run,resume,suspend,terminate}. We log each call (and the body for /run,
// which carries runHookPayload) and return 200 so transitions proceed.
const HOOK_PORT = 9000;
const HOOK_PREFIX = '/aws/lambda-microvms/runtime/v1/';

const hooks = http.createServer((req, res) => {
  const name = req.url.startsWith(HOOK_PREFIX)
    ? req.url.slice(HOOK_PREFIX.length)
    : req.url;

  let body = '';
  req.on('data', (chunk) => { body += chunk; });
  req.on('end', () => {
    console.log(JSON.stringify({
      hook: name,
      method: req.method,
      at: new Date().toISOString(),
      payload: body || undefined,
    }));
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, hook: name }));
  });
});

// Bind to 0.0.0.0 — Lambda reaches hooks over the guest network namespace.
hooks.listen(HOOK_PORT, '0.0.0.0', () => {
  console.log(`Lifecycle hooks listening on port ${HOOK_PORT}`);
});
