# Spexregister Deploy

Docker Compose setup for running Spexregister (server, web, Keycloak, MySQL) on a single host, published
through a Cloudflare Tunnel. The host needs no open inbound ports and no reverse proxy: `cloudflared` dials
out to Cloudflare, which terminates TLS and forwards each public hostname to a container.

```
Browser ──https──▶ Cloudflare ──tunnel──▶ cloudflared ─┬─▶ web:3000        (WEB_HOST)
                                                       ├─▶ keycloak:8080   (AUTH_HOST)
                                                       ├─▶ app:8080        (API_HOST, optional)
                                                       └─▶ mailpit:8025    (MAIL_HOST, staging only)

web ──http──▶ app:8080 ──▶ mysql-app
              app ──http──▶ keycloak:8080 ──▶ mysql-keycloak
```

The web talks to the API over the internal Docker network. Only Keycloak has to be public for login. The API
hostname is needed only for MCP clients and `/docs`.

## Files

| File                          | Purpose                                                                    |
|-------------------------------|----------------------------------------------------------------------------|
| `compose.yaml`                | Services shared by every environment, configured entirely from `.env`      |
| `compose.tunnel.yaml`         | `cloudflared` connector, for hosts published through a Cloudflare Tunnel   |
| `compose.staging.yaml`        | Staging additions: Mailpit catches all outgoing mail                       |
| `staging.env.example`         | Template for `.env` on the staging host                                    |
| `bin/init-secrets.sh`         | Generates random secrets into `secrets/` (never overwrites existing ones)  |
| `bin/configure-keycloak.sh`   | Sets client secrets, frontend URL and sample user passwords in Keycloak   |

`COMPOSE_FILE` in `.env` selects the overlays, so plain `docker compose ...` commands work on each host.

Every service runs from a published image, so the host needs only this repo:

| `.env` variable  | Image                          | Source repo            |
|------------------|--------------------------------|------------------------|
| `APP_IMAGE`      | `bloomper/spexregister-server` | `spexregister-server`  |
| `WEB_IMAGE`      | `bloomper/spexregister-web`    | `spexregister-web`     |
| `KEYCLOAK_IMAGE` | `bloomper/fgv-keycloak`        | `fgv-keycloak`         |

The Keycloak image contains the SPI providers, the FGV theme and the realm import file `fgv.json`.

## 1. Host

Ubuntu Server 26.04 LTS (or Debian 13) on the server. Install without a desktop, enable OpenSSH, then:

```shell
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"            # log out and in again
sudo apt install -y unattended-upgrades git
```

In BIOS, set *Power → After Power Loss* to *Power On* so the box comes back after a power cut. All containers
use `restart: unless-stopped`.

## 2. Cloudflare

The domain's DNS must be hosted on Cloudflare. Use single-level subdomains such as
`register-staging.example.org`. A name like `api.register.example.org` is two levels deep, and the free
Universal SSL certificate doesn't cover it.

1. Networking → Tunnels → *Create a tunnel* → Cloudflared. Name it e.g. `spexregister-staging`.
2. Copy the token from the install command (the long string after `--token`).
3. On the tunnel's **Routes** tab, select *Add route* → *Published application* once for each row below.
   Enter the hostname as subdomain plus domain, and the service in **Service URL**. Cloudflare creates the
   DNS records itself.

   | Hostname     | Service URL            |
   |--------------|------------------------|
   | `WEB_HOST`   | `http://web:3000`      |
   | `AUTH_HOST`  | `http://keycloak:8080` |
   | `API_HOST`   | `http://app:8080`      |
   | `MAIL_HOST`  | `http://mailpit:8025`  |

4. Restrict who can reach staging with Cloudflare Access. See *Cloudflare Access* below.

### Cloudflare Access

Access puts a Cloudflare login in front of a hostname or path before any request reaches the tunnel. The Free
plan covers up to 50 users. Visitors log in with a one-time PIN sent to their email, so they need no account.

**One-time setup:** open **Zero Trust** in the dashboard. On first use you're asked for a team name (becomes
`<team>.cloudflareaccess.com`) and a plan; choose Free. A payment method may be required even on Free. Check
that **One-time PIN** is listed as a login method under **Integrations → Identity providers**, and add it if
not.

**Applications:** go to **Zero Trust → Access controls → Applications → Add an application → Self-hosted**.
An application with no policy denies everyone.

| Application            | Destinations                                | Allow policy                          |
|------------------------|---------------------------------------------|---------------------------------------|
| Spexregister admin     | `MAIL_HOST`, `AUTH_HOST` with path `auth/admin` | *Emails*: your own address        |
| Spexregister staging   | `WEB_HOST`                                  | *Emails*: testers, or *Emails ending in*: a domain |

Leave the rest of `AUTH_HOST` and all of `API_HOST` unprotected:

- **`AUTH_HOST` outside `/auth/admin`:** the `web` container calls Keycloak's token and userinfo endpoints
  server-side through `https://AUTH_HOST`. It has no Access cookie, so login breaks if Access covers those
  paths.
- **`API_HOST`:** MCP clients can't complete an Access login. The API already requires a Keycloak token.

Testers then go through two logins: the Access PIN for `WEB_HOST`, then their Keycloak user.

## 3. Checkout and configuration

```shell
git clone https://github.com/bloomper/spexregister-deploy.git
cd spexregister-deploy

cp staging.env.example .env               # set the hostnames and email addresses
bin/init-secrets.sh
nano secrets/cloudflared.env              # TUNNEL_TOKEN=<token from step 2>
```

## 4. First start

```shell
docker compose up -d keycloak             # also starts mysql-keycloak and mailpit
docker compose ps keycloak                # wait for "healthy"
bin/configure-keycloak.sh
docker compose up -d                      # starts the rest
docker compose logs -f app                # sample data import takes a while
```

Keycloak imports `fgv.json` only when the realm doesn't exist yet. Then `configure-keycloak.sh` makes these
changes:

- sets the `fgv-admin` client secret to `secrets/APP_KEYCLOAK_ADMIN_CLIENT_SECRET`
- points the `spexregister` client at `https://WEB_HOST`
- selects `KEYCLOAK_THEME` as the realm's login and account theme
- replaces the passwords of `SAMPLE_USERS`, which are public in `fgv.json`, with `secrets/SAMPLE_USER_PASSWORD`

You can run it again safely.

Keycloak admin console: `https://AUTH_HOST/auth/admin`, user `KEYCLOAK_ADMIN`, password in
`secrets/KEYCLOAK_ADMIN_PASSWORD`.

## Updating

```shell
git pull
docker compose pull
docker compose up -d
```

Containers whose image changed are recreated. A new `fgv.json` in the Keycloak image doesn't change an existing
realm, because Keycloak imports it only when the realm doesn't exist yet.

## Resetting staging data

```shell
docker compose down -v                    # removes all volumes: databases, index, Keycloak realm
```

Then repeat *First start*. The secrets in `secrets/` are kept and reused.

## Production

`compose.yaml` holds everything that isn't staging-specific. Add `compose.tunnel.yaml` to `COMPOSE_FILE` if
production also goes through a Cloudflare Tunnel, using its own tunnel and token. Leave it out if production
sits behind its own reverse proxy instead. A production host would differ in these ways:

- `production.env.example` with `DEPLOY_ENV=production`, `APP_IMPORT_SAMPLE_DATA=false`,
  `APP_SEED_AUDIT_DATA=false`, a real SMTP relay instead of Mailpit and `SAMPLE_USERS` left empty
- `compose.production.yaml` for production-only services, such as scheduled database dumps to off-host storage
- `APP_IMAGE`, `WEB_IMAGE` and `KEYCLOAK_IMAGE` pinned to release versions, e.g.
  `bloomper/spexregister-server:2.0.0`, instead of `develop`

Running both databases in one MySQL server would mean pointing `KC_DB_URL` at `mysql-app` and creating the
Keycloak database and user with an init script. Two servers keep the realm and application data independently
restorable.

## Image tags

CI in each source repo publishes its image with these tags:

| Trigger              | Tags                                   |
|----------------------|----------------------------------------|
| push to `develop`    | `develop`, `sha-<commit>`              |
| push of tag `vX.Y.Z` | `X.Y.Z`, `latest`, `sha-<commit>`      |

To release, set the version in that repo (`build.gradle` in `spexregister-server`, `package.json` in
`spexregister-web`) to `X.Y.Z`, merge to `main`, then tag and push:

```shell
git tag vX.Y.Z && git push origin vX.Y.Z
```

The build fails if the tag doesn't match the version or if `X.Y.Z` is already on Docker Hub, so release tags
are never overwritten. `fgv-keycloak` has no version file: its tag is the version.
