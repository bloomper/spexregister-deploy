# Spexregister Deploy

Docker Compose setup for running Spexregister (server, web, MySQL) on a single host, published through a
Cloudflare Tunnel. The host needs no open inbound ports and no reverse proxy: `cloudflared` dials out to
Cloudflare, which terminates TLS and forwards each public hostname to a container.

Keycloak runs from [fgv-infra-deploy][1] on the same host, because Nyuppsättning logs in through the same realm.
Set it up first.

```
Browser ──https──▶ Cloudflare ──tunnel──▶ cloudflared ─┬─▶ spexregister-web:3000   (WEB_HOST)
                                                       └─▶ spexregister-api:8080   (API_HOST, optional)

spexregister-web ──http──▶ spexregister-api:8080 ──▶ spexregister-mysql
                           spexregister-api ──http──▶ keycloak-server:8080   (network fgv-<DEPLOY_ENV>)
fgv-revival-deploy's revival-api ──http──▶ spexregister-api:8080     (same network)
```

The web talks to the API over this project's default network. The API also joins the network `fgv-<DEPLOY_ENV>`,
which `fgv-infra-deploy` creates, to reach Keycloak's signing keys and admin API and, on staging, Mailpit. FGV
Revival's server reads spexes from the API there as `spexregister-api`. Browsers and the web reach Keycloak at its
public `KEYCLOAK_HOST`. The API hostname is needed only for MCP clients and `/docs`.

Every service is named after its application and role, as in `fgv-infra-deploy` and `fgv-revival-deploy`, so
names on the shared network say where they come from.

## Files

| File                          | Purpose                                                                    |
|-------------------------------|----------------------------------------------------------------------------|
| `compose.yaml`                | Services shared by every environment, configured entirely from `.env`      |
| `compose.tunnel.yaml`         | `cloudflared` connector, for hosts published through a Cloudflare Tunnel   |
| `staging.env.example`         | Template for `.env` on the staging host                                    |
| `production.env.example`      | Template for `.env` on the production host                                 |
| `bin/init-secrets.sh`         | Generates random secrets into `secrets/` and copies the client secrets from `fgv-infra-deploy` (never overwrites existing ones) |
| `bin/backup-db.sh`            | Dumps the database into `backups/`, pruning dumps older than 14 days       |

`COMPOSE_FILE` in `.env` selects the overlays, so plain `docker compose ...` commands work on each host.

Every service runs from a published image, so the host needs only this repo:

| `.env` variable  | Image                          | Source repo            |
|------------------|--------------------------------|------------------------|
| `API_IMAGE`      | `bloomper/spexregister-server` | `spexregister-server`  |
| `WEB_IMAGE`      | `bloomper/spexregister-web`    | `spexregister-web`     |

## 1. Host

Set up the host and Keycloak as [fgv-infra-deploy][1] describes. Keycloak must be running before the first start
below.

## 2. Cloudflare

The domain's DNS must be hosted on Cloudflare. Use single-level subdomains such as
`register-staging.example.org`. A name like `api.register.example.org` is two levels deep, and the free
Universal SSL certificate doesn't cover it.

1. Networking → Tunnels → *Create a tunnel* → Cloudflared. Name it e.g. `fgv-spexregister-staging`.
   Keycloak has its own tunnel.
2. Copy the token from the install command (the long string after `--token`).
3. On the tunnel's **Routes** tab, select *Add route* → *Published application* once for each row below.
   Enter the hostname as subdomain plus domain, and the service in **Service URL**. Cloudflare creates the
   DNS records itself.

   | Hostname     | Service URL                     |
   |--------------|---------------------------------|
   | `WEB_HOST`   | `http://spexregister-web:3000`  |
   | `API_HOST`   | `http://spexregister-api:8080`  |

4. Restrict who can reach staging with Cloudflare Access. See *Cloudflare Access* below.

### Cloudflare Access

Access puts a Cloudflare login in front of a hostname or path before any request reaches the tunnel. The one-time
setup of Zero Trust is described in `fgv-infra-deploy`'s README.

**Applications:** go to **Zero Trust → Access controls → Applications → Add an application → Self-hosted**.
An application with no policy denies everyone.

| Application            | Destinations                                | Allow policy                          |
|------------------------|---------------------------------------------|---------------------------------------|
| Spexregister staging   | `WEB_HOST`                                  | *Emails*: testers, or *Emails ending in*: a domain |

Leave `API_HOST` unprotected: MCP clients can't complete an Access login, and the API already requires a Keycloak
token.

Testers then go through two logins: the Access PIN for `WEB_HOST`, then their Keycloak user.

## 3. Checkout and configuration

```shell
git clone https://github.com/bloomper/spexregister-deploy.git
cd spexregister-deploy

cp staging.env.example .env               # set the hostnames and email addresses
bin/init-secrets.sh                       # copies the client secrets from ../fgv-infra-deploy
nano secrets/cloudflared.env              # TUNNEL_TOKEN=<token from step 2>
mkdir -p data/api/log_data data/api/index_data data/api/impex_data
sudo chown -R 1000:1000 data/api
```

`bin/init-secrets.sh` copies the `fgv-admin` and `spexregister` client secrets from
`../fgv-infra-deploy/secrets/clients/`. Set `INFRA_DEPLOY` to its path if it is checked out elsewhere.

The `spexregister-api` container runs as user and group 1000, so it needs to own `data/api`. Create the directories
before the first start: Docker would otherwise create them owned by root, and the container couldn't write to them.

## 4. First start

```shell
docker compose up -d
docker compose logs -f spexregister-api   # sample data import takes a while
```

With `API_IMPORT_SAMPLE_DATA=true` the API replaces all data and all Keycloak users on every start. Besides
random users it creates `admin@fgv.nu`, `editor@fgv.nu` and `user@fgv.nu`, one for each role. Every sample user
has the password in `secrets/SAMPLE_USER_PASSWORD`.

## Updating

```shell
git pull
docker compose pull
docker compose up -d --remove-orphans
```

Containers whose image changed are recreated, and containers of services that were removed from `compose.yaml` are
deleted. When an update adds a secret or a variable, compare `.env` with the example file, then run
`bin/init-secrets.sh` again. It doesn't overwrite existing secrets.

Keycloak and its realm are updated with `fgv-infra-deploy`.

## Mail

The `spexregister-api` service sends removal requests from users to `ADMIN_NOTIFICATION_RECIPIENTS`. Staging sends
it to Mailpit, run by `fgv-infra-deploy` as `mailpit` on the shared network. For a real relay, set these in
`.env` and restart `spexregister-api`. Keycloak's own mail settings are in `fgv-infra-deploy`:

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
newline, e.g. `printf '%s' '<password>' > secrets/SMTP_PASSWORD`.

## Data and backups

| Location                    | Contents                                   | Backup                                  |
|-----------------------------|--------------------------------------------|-----------------------------------------|
| volume `mysql_data`         | Application database                       | `bin/backup-db.sh`                      |
| `data/api/impex_data`       | Import and export files                    | copy the directory                      |
| `data/api/log_data`         | Application logs                           | not needed                              |
| `data/api/index_data`       | Search index, rebuilt from the database    | not needed                              |

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
gunzip -c backups/<timestamp>/spexregister-mysql.sql.gz | docker compose exec -T spexregister-mysql \
  sh -c 'MYSQL_PWD=$(cat /run/secrets/MYSQL_ROOT_PASSWORD) mysql -uroot "$MYSQL_DATABASE"'
```

Apart from the app's own files in `data/api/log_data`, every service logs to the console only; read it with
`docker compose logs -f <service>`. Each service keeps at most 5 × 10 MB of console output (`x-logging` in the
compose files), so logs can't fill the disk.

To force a new search index, either run the GraphQL mutation `indexSpexare` or call `POST /api/admin/index/spexare`
as an administrator, or stop `spexregister-api`, empty `data/api/index_data` and start it again; it rebuilds an
empty index on startup.

## Resetting staging data

```shell
docker compose down -v                    # removes the database volume
rm -rf data/api                           # index, logs, import and export files
```

Then repeat *First start*. With `API_IMPORT_SAMPLE_DATA=true` the sample data import also replaces the Keycloak
users. To reset the realm as well, see `fgv-infra-deploy`. The secrets in `secrets/` and the dumps in `backups/`
are kept.

## Production

Staging and production use the same `compose.yaml`; they differ only in `.env`. Add `compose.tunnel.yaml` to `COMPOSE_FILE` if
production also goes through a Cloudflare Tunnel, using its own tunnel and token. Leave it out if production
sits behind its own reverse proxy instead. A production host would differ in these ways:

- `.env` copied from `production.env.example`: `DEPLOY_ENV=production`, `API_IMPORT_SAMPLE_DATA=false`,
  `API_SEED_AUDIT_DATA=false` and a real SMTP relay instead of Mailpit (see *Mail*; the values in the example are
  placeholders)
- no sample users: only the sample data import creates them
- `API_SEED_AUDIT_DATA=true` once the migrated data is in place and corrected, followed by
  `docker compose up -d spexregister-api`. That gives every existing row a baseline revision. The app seeds only while the
  change log is empty, so the flag can stay on afterwards
- `bin/backup-db.sh` scheduled in cron, with `backups/` copied to off-host storage
- `API_IMAGE` and `WEB_IMAGE` pinned to release versions, e.g.
  `bloomper/spexregister-server:2.0.0`, instead of `develop`, and `CLOUDFLARED_VERSION` pinned instead of
  `latest`, so that an update happens only when `.env` changes

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
are never overwritten.

[1]: https://github.com/bloomper/fgv-infra-deploy
