// TCP front door for the host-side credential proxy, which listens on a
// bind-mounted unix socket (no host TCP exposure - see
// bin/dejima-anthropic-proxy). Deliberately no HTTP awareness in either
// mode: bytes in, bytes out.
//
// tls (default): terminates TLS for api.anthropic.com on :443, which
// entrypoint.sh points at loopback via /etc/hosts. Claude Code then needs no
// ANTHROPIC_BASE_URL and no placeholder token - it is configured exactly like
// a stock install, which is the point (see docs/security.md). ALPN is pinned
// to http/1.1 because the far end of the pipe is a Python http.server: let a
// client negotiate h2 and it would receive HTTP/2 frames nothing here parses.
//
// loopback: the original plaintext forwarder on :18300, reached via an
// explicit ANTHROPIC_BASE_URL. Kept as the documented fallback for the day
// certificate pinning makes the tls path unusable - the alternative would be
// disabling the credential proxy entirely, which is exactly what must never
// be the answer.
//
// Ports are repo constants (the container's network namespace is private, so
// nothing can collide); the env override exists only for host-side tests.
const net = require("net");
const tls = require("tls");
const fs = require("fs");

const socketPath = process.env.SANDBOX_ANTHROPIC_PROXY_SOCKET;
const transport = process.env.SANDBOX_ANTHROPIC_TRANSPORT || "tls";
const port = parseInt(
  process.env.SANDBOX_ANTHROPIC_PROXY_PORT || (transport === "tls" ? "443" : "18300"),
  10,
);
if (!socketPath) {
  console.error("anthropic-proxy-forwarder: SANDBOX_ANTHROPIC_PROXY_SOCKET not set");
  process.exit(1);
}

const pipe = (client) => {
  const upstream = net.connect(socketPath);
  client.pipe(upstream);
  upstream.pipe(client);
  client.on("error", () => upstream.destroy());
  upstream.on("error", () => client.destroy());
};

let server;
if (transport === "tls") {
  const certPath = process.env.SANDBOX_ANTHROPIC_TLS_CERT;
  const keyPath = process.env.SANDBOX_ANTHROPIC_TLS_KEY;
  if (!certPath || !keyPath) {
    console.error(
      "anthropic-proxy-forwarder: SANDBOX_ANTHROPIC_TLS_CERT/SANDBOX_ANTHROPIC_TLS_KEY not set",
    );
    process.exit(1);
  }
  server = tls.createServer(
    {
      cert: fs.readFileSync(certPath),
      key: fs.readFileSync(keyPath),
      ALPNProtocols: ["http/1.1"],
    },
    pipe,
  );
} else {
  server = net.createServer(pipe);
}
server.listen(port, "127.0.0.1");
