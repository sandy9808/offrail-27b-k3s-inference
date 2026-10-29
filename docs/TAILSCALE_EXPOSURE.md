# Tailscale exposure and the private HTTPS proxy

This note records how the Odysseus site on this machine was published, and
where the private credentials live. It does not contain OAuth secrets, proxy
passwords, or GitHub tokens. Those values stay in the gitignored `.env` file
at the repository root. Copy `.env.example` to `.env` on a new machine and
fill it in locally.

## What is public

- Tailnet and Funnel URL: `https://odysseus.tail8b5da9.ts.net`
- That URL terminates TLS with a Let's Encrypt certificate and proxies to the
  Odysseus app at `http://127.0.0.1:7011`.
- The Offrail inference API stays on `http://127.0.0.1:8899`. It is not
  published through Funnel.

## Private proxy

An outbound HTTP proxy is used to check the public site from outside this
network. Its HTTPS port is:

`https://40.27.109.219:59101`

The host, ports, username, and password are `PROXY_HOST`, `PROXY_HTTPS_PORT`,
`PROXY_HTTP_PORT`, `PROXY_USERNAME`, and `PROXY_PASSWORD` in `.env`. Port
`59100` is the same proxy's HTTP listener. Port `59101` is the listener used
for HTTPS `CONNECT`. A browser that opens `https://40.27.109.219:59101`
directly talks to the proxy, not to Odysseus. To fetch the site through it:

```bash
set -a
source .env
set +a
curl -sk --http1.1 \
  -x "http://${PROXY_USERNAME}:${PROXY_PASSWORD}@${PROXY_HOST}:${PROXY_HTTPS_PORT}" \
  "https://odysseus.tail8b5da9.ts.net/login"
```

A successful check returns the Odysseus login page.

## How Tailscale was attached

1. Tailscale was already logged in on the host as `pop-os`
   (`100.103.98.22`). The OAuth client id and secret for the Kubernetes
   operator live in `.env` as `TAILSCALE_OAUTH_CLIENT_ID` and
   `TAILSCALE_OAUTH_CLIENT_SECRET`. The same pair is mounted into the
   operator from the `operator-oauth` secret in the `tailscale` namespace.
   Do not copy that secret into git.
2. The Tailscale Kubernetes operator (`tailscale/k8s-operator:v1.104.2`) was
   already running in the `tailscale` namespace and had joined the tailnet as
   `tailscale-operator`.
3. Nginx was listening on `0.0.0.0:443`, so `tailscaled` could not bind the
   tailnet address on port 443 and Funnel returned Traefik's certificate or
   nothing. Nginx was changed to listen on `192.168.1.148:443`,
   `127.0.0.1:443`, and `0.0.0.0:59101`. Port 59101 is the local HTTPS
   listener for Odysseus and proxies to `127.0.0.1:7011`. Traefik's
   ServiceLB port 443 was removed so it would not take the port back.
4. The node hostname was set to `odysseus` after the unused operator
   load-balancer device of that name was deleted:

   ```bash
   sudo tailscale set --hostname=odysseus
   sudo tailscale funnel reset
   sudo tailscale funnel --bg --https=443 http://127.0.0.1:7011
   ```

5. Funnel had to be enabled once in the Tailscale admin console for this
   node. After that, `tailscaled` obtained a certificate for
   `odysseus.tail8b5da9.ts.net` and started listening on
   `100.103.98.22:443`.

Check the exposure with:

```bash
sudo tailscale funnel status
curl -fsS https://odysseus.tail8b5da9.ts.net/login -o /dev/null -w '%{http_code}\n'
```

The login page is HTTP 200. The inference API remains local:

```bash
curl -fsS http://127.0.0.1:8899/health
```
