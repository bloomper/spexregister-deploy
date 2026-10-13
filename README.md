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
| `production.env.example`      | Template for `.env` on the production host                                 |
| `bin/init-secrets.sh`         | Generates random secrets into `secrets/` (never overwrites existing ones)  |
| `bin/configure-keycloak.sh`   | Sets client secrets, frontend URL, theme, mail settings and sample user passwords in Keycloak |
| `bin/backup-db.sh`            | Dumps both databases into `backups/`, pruning dumps older than 14 days     |

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
- selects `KEYCLOAK_THEME` as the realm's login, account and email theme
- sets the realm's mail settings from the `SMTP_*` variables, `MAIL_FROM` and `secrets/SMTP_PASSWORD`
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

When an update adds a secret or a variable, compare `.env` with the example file, then run `bin/init-secrets.sh`
and `bin/configure-keycloak.sh` again. Neither overwrites an existing secret.

## Mail

Keycloak sends all mail: email verification, password reset and the approval notifications. Staging sends it to
Mailpit. For a real relay, set these in `.env` and run `bin/configure-keycloak.sh`:

| Variable        | Purpose                                                                  |
|-----------------|--------------------------------------------------------------------------|
| `SMTP_HOST`     | SMTP server                                                              |
| `SMTP_PORT`     | Usually `587` with STARTTLS, `465` with implicit TLS, `25` without       |
| `SMTP_AUTH`     | `true` to log in with `SMTP_USER` and the password in `secrets/SMTP_PASSWORD` |
| `SMTP_USER`     | SMTP user                                                                |
| `SMTP_STARTTLS` | `true` to upgrade the connection with STARTTLS                           |
| `SMTP_SSL`      | `true` to connect with implicit TLS                                      |
| `MAIL_FROM`     | Sender address                                                           |

`bin/init-secrets.sh` creates `secrets/SMTP_PASSWORD` empty. Write the password into it without a trailing
newline, e.g. `printf '%s' '<password>' > secrets/SMTP_PASSWORD`. Check the result with *Test connection* under
*Realm settings → Email* in the admin console.

## Data and backups

| Location                    | Contents                                   | Backup                                  |
|-----------------------------|--------------------------------------------|-----------------------------------------|
| volume `mysql_app_db_data`  | Application database                       | `bin/backup-db.sh`                      |
| volume `mysql_keycloak_db_data` | Keycloak database (realm, users)       | `bin/backup-db.sh`                      |
| `data/app/impex_data`       | Import and export files                    | copy the directory                      |
| `data/app/log_data`         | Application logs                           | not needed                              |
| `data/app/index_data`       | Search index, rebuilt from the database    | not needed                              |

The databases stay in named volumes: copying the files of a running MySQL server doesn't give a consistent
backup. `bin/backup-db.sh` uses `mysqldump --single-transaction` instead, which is consistent without stopping
anything. Run it nightly from the host user's crontab (`crontab -e`):

```
30 2 * * * /home/<user>/spexregister-deploy/bin/backup-db.sh >> /home/<user>/spexregister-deploy/backups/backup.log 2>&1
```

`BACKUP_KEEP_DAYS` sets how many days of dumps to keep (default 14). Copy `backups/` off the host as well, e.g.
with `rclone` or `rsync`; a backup on the same disk doesn't survive losing the disk.

To restore a dump:

```shell
gunzip -c backups/<timestamp>/mysql-app.sql.gz | docker compose exec -T mysql-app \
  sh -c 'MYSQL_PWD=$(cat /run/secrets/MYSQL_APP_ROOT_PASSWORD) mysql -uroot "$MYSQL_DATABASE"'
```

Use `mysql-keycloak` and `MYSQL_KEYCLOAK_ROOT_PASSWORD` for the Keycloak dump.

Apart from the app's own files in `data/app/log_data`, every service logs to the console only; read it with
`docker compose logs -f <service>`. Each service keeps at most 5 × 10 MB of console output (`x-logging` in the
compose files), so logs can't fill the disk.

To force a new search index, either call `POST /api/admin/index/spexare` as an administrator, or stop `app`,
empty `data/app/index_data` and start `app` again; it rebuilds an empty index on startup.

### Moving from named volumes

Hosts set up before `data/` existed keep the app's files in the volumes `app_log_data`, `app_index_data` and
`app_impex_data`. Copy the import and export files over once, after `git pull`:

```shell
docker compose stop app
mkdir -p data/app
docker run --rm -v spexregister-${DEPLOY_ENV}_app_impex_data:/from -v "$PWD/data/app/impex_data":/to alpine cp -a /from/. /to/
docker compose up -d app                  # rebuilds the index, logs start afresh
docker volume rm spexregister-${DEPLOY_ENV}_app_log_data spexregister-${DEPLOY_ENV}_app_index_data spexregister-${DEPLOY_ENV}_app_impex_data
```

Set `DEPLOY_ENV` in the shell first, or write the volume names out (`docker volume ls`).

## Resetting staging data

```shell
docker compose down -v                    # removes the volumes: databases, Keycloak realm, Mailpit
rm -rf data/app                           # index, logs, import and export files
```

Then repeat *First start*. The secrets in `secrets/` and the dumps in `backups/` are kept.

## Production

`compose.yaml` holds everything that isn't staging-specific. Add `compose.tunnel.yaml` to `COMPOSE_FILE` if
production also goes through a Cloudflare Tunnel, using its own tunnel and token. Leave it out if production
sits behind its own reverse proxy instead. A production host would differ in these ways:

- `.env` copied from `production.env.example`: `DEPLOY_ENV=production`, `APP_IMPORT_SAMPLE_DATA=false`,
  `APP_SEED_AUDIT_DATA=false`, a real SMTP relay instead of Mailpit (see *Mail*; the values in the example are
  placeholders) and `SAMPLE_USERS` left empty
- `bin/backup-db.sh` scheduled in cron, with `backups/` copied to off-host storage
- `APP_IMAGE`, `WEB_IMAGE` and `KEYCLOAK_IMAGE` pinned to release versions, e.g.
  `bloomper/spexregister-server:2.0.0`, instead of `develop`, and `CLOUDFLARED_VERSION` pinned instead of
  `latest`, so that an update happens only when `.env` changes

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
