# SAML Proxy

A small, self-contained reverse proxy that puts **SAML 2.0 single sign-on in front of
any HTTP service that has no SAML support of its own**. It authenticates the user
against your Identity Provider (IdP), then forwards the request to a backend with the
authenticated identity injected as HTTP request headers (`Remote-User`, `X-WEBAUTH-USER`,
etc.).

It is an Apache `httpd` container using [`mod_auth_mellon`](https://github.com/latchset/mod_auth_mellon)
for the SAML handshake and Apache's `mod_proxy` for reverse proxying. All configuration is
done through environment variables and a handful of mounted files — there is no application
code to build, only a container image.

## Credits & origins

This project is a **fork of [saml-proxy by Barnabas Sudy](https://github.com/bsudy/saml-proxy)**
(barnabas.sudy@gmail.com). The original author designed and wrote the core of it — the SAML
authentication via `mod_auth_mellon`, the reverse-proxy setup, the env-var-driven entrypoint,
and the SAML SP metadata tooling. **Most of the code in this repository is his.**

This fork adds only incremental changes on top: non-root operation, current Fedora base
images, a configurable Mellon cookie name and endpoint path, extra `Remote-User-*` identity
headers, and RabbitMQ support.

No license file exists in this repository or upstream; the original work remains the
copyright of Barnabas Sudy.

See [MAINTAINING.md](MAINTAINING.md) for architecture and maintenance notes.

## How it works

```
                 (1) request
   Browser  ─────────────────────▶  saml-proxy (Apache + mod_auth_mellon)
      ▲                                 │
      │ (2) no session → redirect       │ (5) authenticated: proxy the request,
      │     to IdP for SSO              │     inject Remote-User* headers
      │                                 ▼
   Identity Provider  ◀───────┐     Backend service (Grafana, RabbitMQ UI, …)
   (Auth0, Azure AD, …)       │
                              └── (3) user logs in, (4) SAML assertion POSTed back
```

1. A request arrives for a protected path.
2. If there is no valid Mellon session cookie, the user is redirected to the IdP.
3. The user authenticates at the IdP.
4. The IdP POSTs a SAML assertion back to `/<mellon-path>/postResponse`; Mellon validates
   it and sets a session cookie.
5. On subsequent requests the proxy forwards to `BACKEND`, adding headers derived from SAML
   attributes so the backend knows who the user is.

The proxy terminates **no TLS of its own for production** — it expects to sit behind an
ingress/load balancer that does TLS termination (see `SCHEMA` below). A self-signed
certificate is generated at startup only so Apache's `mod_ssl` can offer HTTPS on 8443 for
local testing.

## Ports

The container runs as a **non-root** user (Apache uid `48`), so it binds unprivileged ports:

| Port   | Purpose                                              |
|--------|------------------------------------------------------|
| `8080` | HTTP proxying (the port you normally route traffic to) |
| `8443` | HTTPS with the auto-generated self-signed cert (local testing) |

> **Note:** Older documentation and the upstream image used port 80. Since this fork runs
> non-root, the HTTP listener is **8080**, not 80.

## Configuration

Configuration is entirely via environment variables and mounted files.

### Environment variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `BACKEND` | **yes** | – | URL requests are proxied to once authenticated, e.g. `http://grafana` or `https://api.example.com:8443`. |
| `PROXY_HOST` | no | container hostname (`hostname -f`) | The public hostname the proxy is reached at. Used to build the SAML entity ID and endpoints. Equivalent to passing `-h` to `docker run`. |
| `SCHEMA` | no | `https` | The scheme the proxy is publicly reached at. Used only to build SAML URLs — it is **not** the protocol the proxy accepts. TLS termination is expected to happen in front of this container. |
| `MELLON_PATH` | no | `mellon` | Path prefix for the Mellon endpoints (login/logout/postResponse). The SAML endpoints live under `/<MELLON_PATH>/…`. |
| `COOKIE` | no | `cookie` | Mellon session cookie name (the actual cookie is `mellon-<COOKIE>`). Set a distinct value when running several proxies on the same parent domain to avoid cookie collisions. |
| `BACKEND_IS_RABBITMQ` | no | unset | When set to any non-empty value, enables `ProxyPass nocanon` and `AllowEncodedSlashes NoDecode`, which the RabbitMQ management UI requires (its URLs contain encoded slashes). |
| `REMOTE_USER_SAML_ATTRIBUTE` | no | uses SAML `NAME_ID` | Which SAML attribute to use as the value of the `Remote-User` header. If unset, the SAML `NAME_ID` is used. |
| `REMOTE_USER_NAME_SAML_ATTRIBUTE` | no | – | SAML attribute to expose as the `Remote-User-Name` header. |
| `REMOTE_USER_EMAIL_SAML_ATTRIBUTE` | no | – | SAML attribute to expose as the `Remote-User-Email` header. |
| `REMOTE_USER_PREFERRED_USERNAME_SAML_ATTRIBUTE` | no | – | SAML attribute to expose as the `Remote-User-Preferred-Username` header. |
| `SAML_MAP_<attr>` | no | – | Maps SAML attribute `<attr>` to an arbitrary request header. E.g. `SAML_MAP_EmailAddress=X-WEBAUTH-USER` sets header `X-WEBAUTH-USER` from the `EmailAddress` SAML attribute. Any number may be defined. |

#### Headers injected into the backend request

Depending on the variables above, the proxy sets these headers on the request it forwards:

| Header | Source |
|--------|--------|
| `Remote-User` | `REMOTE_USER_SAML_ATTRIBUTE` (or SAML `NAME_ID` if unset) |
| `Remote-User-Name` | `REMOTE_USER_NAME_SAML_ATTRIBUTE` |
| `Remote-User-Email` | `REMOTE_USER_EMAIL_SAML_ATTRIBUTE` |
| `Remote-User-Preferred-Username` | `REMOTE_USER_PREFERRED_USERNAME_SAML_ATTRIBUTE` |
| any header you name | each `SAML_MAP_<attr>` mapping |

### Mounted files

| Path | Required | Description |
|------|----------|-------------|
| `/etc/httpd/conf.d/saml_idp.xml` | **yes** | Your IdP's SAML metadata (download it from your IdP). |
| `/etc/httpd/conf.d/saml_sp.key` | no | SP private key. Generated at startup if not provided. |
| `/etc/httpd/conf.d/saml_sp.cert` | no | SP certificate. Generated at startup if not provided. |
| `/etc/httpd/conf.d/saml_sp.xml` | no | SP metadata. Generated at startup if not provided. |

> **All-or-nothing:** the three `saml_sp.*` files are treated as a set. If you provide any
> one of them you must provide all three, otherwise startup fails. Providing them yourself
> keeps the SP certificate stable across restarts (otherwise a fresh one is generated on
> every start, which changes the SP metadata you registered with the IdP).

You can pre-generate the SP files with
[`mellon_create_metadata.sh`](mellon_create_metadata.sh):

```
./mellon_create_metadata.sh https://auth.example.com https://auth.example.com/mellon
```

## Quick start (Docker)

```
docker run -ti \
  -p 8080:8080 \
  -h auth.example.com \
  -v "$(pwd)/saml_idp.xml:/etc/httpd/conf.d/saml_idp.xml" \
  -e BACKEND=https://api.example.com:8443 \
  -e SCHEMA=https \
  priitrent/saml-proxy
```

* `-p 8080:8080` — publish the proxy's HTTP port.
* `-h auth.example.com` — the public hostname; equivalent to `-e PROXY_HOST=auth.example.com`.
* `-v .../saml_idp.xml:...` — mount your IdP metadata (mandatory).
* `-e BACKEND=…` — where authenticated requests go.
* `-e SCHEMA=https` — the scheme the proxy is publicly reachable at.
* `-ti` — interactive, so `Ctrl+C` stops it.

### Docker Compose

```yaml
services:
  yourservice:
    # ...
  saml-proxy:
    image: priitrent/saml-proxy
    environment:
      BACKEND: "http://yourservice:port"
      PROXY_HOST: "auth.example.com"
    ports:
      - "8080:8080"
    volumes:
      - "./saml_idp.xml:/etc/httpd/conf.d/saml_idp.xml"
```

## Getting SAML metadata from your IdP

The proxy needs your IdP's metadata as `saml_idp.xml`, and the IdP needs to know the
proxy's callback URL and (optionally) audience/entity ID.

* **Callback / Assertion Consumer Service URL:** `https://<PROXY_HOST>/<MELLON_PATH>/postResponse`
  (default `https://auth.example.com/mellon/postResponse`)
* **Single Logout URL:** `https://<PROXY_HOST>/<MELLON_PATH>/logout`
* **Entity ID / Audience:** `https://<PROXY_HOST>`

### Auth0 (example)

Create an application at [auth0.com](https://auth0.com/) and edit its
*Addons → SAML2 Web App* settings:

* **Application Callback URL:** `https://auth.example.com/mellon/postResponse`
* **Settings:**
  ```json
  {
      "audience": "https://auth.example.com"
  }
  ```
* Download the **Identity Provider Metadata** XML and mount it as `saml_idp.xml`.

## Kubernetes

A complete, current example (Grafana behind the proxy) lives in
[`examples/grafana/kubernetes.md`](examples/grafana/kubernetes.md). In outline:

1. Store your IdP metadata in a `ConfigMap` and mount `saml_idp.xml` into the proxy pod.
2. Run the proxy `Deployment` with `BACKEND` pointing at your service's in-cluster address
   and whatever header mappings your backend expects.
3. Expose the proxy with a `Service` (targeting container port `8080`) and route external
   traffic to it with an `Ingress` that terminates TLS.

Because the proxy expects TLS to be terminated in front of it, the `Ingress` (or another
load balancer) is what provides HTTPS to users; set `SCHEMA=https` so SAML URLs are built
correctly.

## Local build & test

Build the image and run it against your metadata:

```
docker build -t saml-proxy .
docker run -ti -p 8080:8080 -p 8443:8443 \
  -h auth.example.com \
  -v "$(pwd)/saml_idp.xml:/etc/httpd/conf.d/saml_idp.xml" \
  -e BACKEND=http://host.docker.internal:3000 \
  -e SCHEMA=http \
  saml-proxy
```

Then browse to `http://auth.example.com:8080/` (add `auth.example.com` to your
`/etc/hosts` pointing at `127.0.0.1`). You should be redirected to your IdP.

See [MAINTAINING.md](MAINTAINING.md) for how the pieces fit together, how releases are
built, and the things worth knowing before you change the config templates.
