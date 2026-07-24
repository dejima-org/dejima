// TCP -> unix-socket byte pipe: Claude Code needs an http://127.0.0.1 base
// URL, but the host-side credential proxy listens on a bind-mounted unix
// socket (no host TCP exposure - see bin/claude-sandbox-anthropic-proxy).
// Deliberately no HTTP awareness: bytes in, bytes out. Port 18300 is a repo
// constant (the container's network namespace is private, so nothing can
// collide with it); the env override exists only for host-side tests.
const net = require("net");

const socketPath = process.env.SANDBOX_ANTHROPIC_PROXY_SOCKET;
const port = parseInt(process.env.SANDBOX_ANTHROPIC_PROXY_PORT || "18300", 10);
if (!socketPath) {
  console.error("anthropic-proxy-forwarder: SANDBOX_ANTHROPIC_PROXY_SOCKET not set");
  process.exit(1);
}

net.createServer((client) => {
  const upstream = net.connect(socketPath);
  client.pipe(upstream);
  upstream.pipe(client);
  client.on("error", () => upstream.destroy());
  upstream.on("error", () => client.destroy());
}).listen(port, "127.0.0.1");
