# Maintaining saml-proxy

This document is for whoever owns this repository after the original maintainer. It explains
what the moving parts are, how a request flows through them, how images are built and
released, and the non-obvious things worth knowing before you change anything.

For user-facing usage (env vars, mounted files, examples) see [README.md](README.md).

## What this actually is

There is **no application code**. The whole project is:

* a **Dockerfile** that installs Apache `httpd` and a few modules on Fedora,
* an **entrypoint script** (`configure`) that renders Apache config from environment
  variables at container start,
* an Apache config **template** (`proxy.conf`) that wires up SAML auth + reverse proxy,
* a **helper script** (`mellon_create_metadata.sh`) that generates the SAML SP key/cert/metadata.

Everything is glued together with `mod_auth_mellon` (SAML) and `mod_proxy` (reverse proxy).
If you understand those two Apache modules, you understand this project.

## Files

| File | Role |
|------|------|
| `Dockerfile` | Builds the image on `fedora-minimal`. Installs httpd + Mellon + supporting modules, patches httpd to run non-root on unprivileged ports, sets ownership so uid 48 (`apache`) can write what it needs. |
| `configure` | The `ENTRYPOINT`. Validates required inputs, generates the SP cert/metadata if not mounted, expands env vars into `proxy.conf`, generates a self-signed TLS cert for `mod_ssl`, then execs `httpd -DFOREGROUND`. |
| `proxy.conf` | Template for the Apache virtual host. Contains `$VAR` placeholders filled in by `envsubst` in `configure`. This is where the SAML protection and proxying rules live. |
| `mellon_create_metadata.sh` | Stand-alone script (also copied into the image) that produces `saml_sp.key`, `saml_sp.cert`, and `saml_sp.xml` for a given entity ID + endpoint URL. |
| `proxy.conf` placeholders | `$SCHEMA`, `$HOST`, `$COOKIE`, `$ENCODED_SLASHES`, `$BACKEND_OPTIONS`, `$BACKEND`, `$MELLON_PATH`, `$REQUEST_HEADERS` — all exported by `configure` and substituted at startup. |
| `.github/workflows/docker-image.yml` | CI that builds (does **not** push) the image. See [Releases / CI](#releases--ci). |
| `examples/grafana/kubernetes.md` | Worked Kubernetes example. |

## Startup flow (`configure`)

When the container starts, `configure` runs in this order:

1. **Validate inputs.** Fails fast if `/etc/httpd/conf.d/saml_idp.xml` is missing or
   `BACKEND` is unset, printing usage.
2. **Derive config.** Computes `HOST` (`PROXY_HOST` or the container's FQDN), `SCHEMA`
   (default `https`), `MELLON_PATH` (default `mellon`), `COOKIE` (default `cookie`), and a
   Kerberos-style `realm` (leftover from the upstream lineage; harmless).
3. **SP metadata.** If any of `saml_sp.{key,cert,xml}` are mounted, all three must be
   present or it exits. If none are mounted, it calls `mellon_create_metadata.sh` to
   generate a fresh set — meaning **the SP certificate changes on every restart unless you
   mount your own**. Mount them for anything long-lived.
4. **Header mappings.** Iterates over every `SAML_MAP_*` env var and builds
   `RequestHeader set …` lines, collected into `$REQUEST_HEADERS`.
5. **RabbitMQ special-case.** If `BACKEND_IS_RABBITMQ` is set, switches on
   `nocanon` + `AllowEncodedSlashes NoDecode` (the management UI breaks otherwise).
6. **Render config.** `envsubst` expands the whitelisted variables in `proxy.conf.template`
   into the live `proxy.conf`. Only the listed variables are substituted, so literal `$`
   in Apache config (e.g. `%{MELLON_...}e`) survives.
7. **TLS cert.** `sscg` generates a self-signed cert into `/etc/httpd/tls/…` for `mod_ssl`
   on 8443.
8. **Exec Apache** in the foreground.

## How `proxy.conf` protects and proxies

The rendered vhost has two location blocks:

* `<Location />` enables Mellon in **"info"** mode across the whole site and points at the
  SP key/cert/metadata and the IdP metadata. It also sets the Mellon cookie name,
  `MellonSecureCookie On`, and `MellonCookieSameSite None` (needed so the cookie survives
  the cross-site POST-back from the IdP — see
  [mod_auth_mellon#47](https://github.com/latchset/mod_auth_mellon/issues/47)).
* `<LocationMatch "^\/(?!<mellon-path>)">` enables Mellon in **"auth"** mode (i.e. requires
  a session) for everything *except* the Mellon endpoint path, and `ProxyPass`es matched
  requests to `BACKEND`. The negative-lookahead is what keeps the SSO callback endpoints
  themselves unauthenticated so login can complete.

Inside the auth block, `<If>`/`<Else>` and `MellonSetEnv` map SAML attributes to the
`Remote-User*` headers, and `$REQUEST_HEADERS` injects the `SAML_MAP_*` headers.

## Non-root design

Recent history converted the image to run as **uid 48 (`apache`)**:

* httpd's default `Listen 80` is stripped and `mod_ssl` is repointed from 443 → 8443 and
  from `/etc/pki/tls/...` to `/etc/httpd/tls/...` (writable by the apache group).
* `proxy.conf` listens on **8080**.
* Directories the process must write (`/run/httpd`, `/var/log/httpd`,
  `/etc/httpd/conf.d`, `/etc/httpd/tls`) are `chown`ed to `apache:0` and made group-writable
  so the entrypoint can render config and generate certs at runtime.

If you ever need to add a runtime-writable path, remember to fix its ownership/permissions
in the Dockerfile the same way — a path only root can write will break startup.

## Releases / CI

`.github/workflows/docker-image.yml` builds the image tagged
`priitrent/saml-proxy:<base>-<date>-<run>`.

Two things to know:

* **It only builds, it does not push.** There is no registry login or `docker push` step.
  Whoever takes over should decide where images are published (Docker Hub `priitrent/…`,
  GHCR, an internal registry) and add the login + push steps.
* **It only runs on manual dispatch.** The `push`/`pull_request` triggers are set to
  `branches: none`, so nothing builds automatically — use the *Run workflow* button, or
  wire up real branch triggers.
* Keep `BASE_VERSION` in the workflow in sync with the Fedora version in the `Dockerfile`
  (currently 43). The workflow value only affects the image tag; the actual base image is
  hardcoded in the Dockerfile's `FROM`, so a mismatch produces a misleading tag.

### Bumping the Fedora base

1. Change `FROM registry.fedoraproject.org/fedora-minimal:<N>` in the `Dockerfile`.
2. Update `BASE_VERSION` in the workflow to match.
3. Build locally and smoke-test (see README → *Local build & test*): confirm the container
   starts, redirects to the IdP, and proxies after login. Package names/paths occasionally
   shift between Fedora releases, so a build that succeeds is not proof it runs.

## Gotchas & things that have bitten people

* **SP cert regenerates on restart** unless you mount `saml_sp.*`. If SSO suddenly breaks
  after a redeploy, this is the first thing to check.
* **`SameSite=None` + `SecureCookie`** are required for the IdP POST-back. Do not "tidy"
  them away.
* **`SCHEMA` is about SAML URLs, not the listener.** The proxy always speaks plain HTTP on
  8080; `SCHEMA` only controls how public URLs (entity ID, endpoints) are written. If the
  IdP round-trip lands on `http://` when it should be `https://`, `SCHEMA` is wrong.
* **Cookie collisions** between multiple proxies on the same parent domain — give each a
  distinct `COOKIE`.
* **RabbitMQ** (and anything with encoded slashes in URLs) needs `BACKEND_IS_RABBITMQ=1`.
* **Kerberos leftovers.** `mod_auth_gssapi` is installed and a `realm` is computed but SAML
  is the only auth path actually wired up. This is upstream lineage, not a feature in use.

## Upstream & attribution

This repository is a fork of [saml-proxy by Barnabas Sudy](https://github.com/bsudy/saml-proxy)
(barnabas.sudy@gmail.com). **The core of the project is his work** — the SAML auth via
`mod_auth_mellon`, the reverse-proxy design, the env-var-driven entrypoint pattern, the
`proxy.conf` template, and the SP-metadata tooling (`mellon_create_metadata.sh`, which itself
originates from the [mod_auth_mellon project](https://github.com/latchset/mod_auth_mellon)).

What this fork changed on top of that is comparatively small: non-root operation, configurable
`COOKIE` and `MELLON_PATH`, extra `Remote-User-*` identity headers, `BACKEND_IS_RABBITMQ`, and
tracking current Fedora base images. When attributing this project, credit the original author
for the design and the bulk of the code.

Neither this repository nor upstream carries a LICENSE file, so the original work is
"all rights reserved" by its author by default. This is worth resolving with Barnabas Sudy
before treating the code as freely reusable.
