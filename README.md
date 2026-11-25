# dexcom-g7-ns-uploader

Uploads Dexcom G7 readings to [Nightscout](https://nightscout.github.io/) straight from the Dexcom Share cloud. You don't need a phone running xDrip.

It talks to the same Dexcom Share API that [pydexcom](https://github.com/gagebenne/pydexcom) and the Home Assistant Dexcom integration use. If those work for your account, this will too. It's one bash script that needs only `curl` and `jq`.

```
G7 sensor ──► Dexcom G7 app (with Share on) ──► Dexcom Share cloud ──► this script ──► Nightscout
```

## Before you start

1. **Turn on Share in the Dexcom G7 app** (Connections → Share). You need at least one follower, or at least an invite sent. Without this, the cloud never gets readings.
2. Use the Dexcom account of the person **wearing** the sensor, not a follower's account.
3. **Username format:** use an email, a phone number in international format (`+15551234567`), or the Dexcom account ID (a UUID). If phone login fails, try the account ID. pydexcom's docs show how to find it.
4. Pick your region: `us`, `ous` (outside the US) or `jp`.

## Quick start (setup script)

```bash
git clone https://github.com/pandaboy6621/dexcom-g7-ns-uploader.git
cd dexcom-g7-ns-uploader
./install.sh
```

The script walks you through four steps:

1. **Checks for `curl` and `jq`**, and offers to install them if they're missing.
2. **Asks for your settings:** Dexcom username, password and region, then your Nightscout URL and API_SECRET or access token. Passwords are typed hidden, and everything is saved to `.env`, which only your user can read.
3. **Tests both logins** without uploading anything. If a login fails, it tells you which one and lets you re-enter.
4. **Starts it in the background.** It uses a systemd service on Linux (starts on boot), a launchd agent on macOS (runs while you're logged in and the Mac is awake), or Docker.

To change settings later, run `./install.sh` again. To stop and remove the background service:

```bash
./install.sh --uninstall
```

## Manual start

If you'd rather set it up yourself:

```bash
cp .env.example .env              # then edit .env
./dexcom-ns-uploader.sh --check   # test both logins, uploads nothing
./dexcom-ns-uploader.sh --once    # one sync
./dexcom-ns-uploader.sh           # run forever (polls every POLL_INTERVAL seconds)
```

## Run it in the background (manually)

### Docker (easiest on a homelab box)

```bash
cp .env.example .env   # edit it
docker compose up -d --build
docker compose logs -f
```

### systemd (any Linux box, including a Raspberry Pi)

```bash
sudo apt install curl jq    # or your distro's equivalent
sudo install -Dm755 dexcom-ns-uploader.sh /opt/dexcom-g7-ns-uploader/dexcom-ns-uploader.sh
sudo install -Dm600 .env /etc/dexcom-ns-uploader.env
sudo cp dexcom-ns-uploader.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now dexcom-ns-uploader
journalctl -u dexcom-ns-uploader -f
```

### cron / n8n / anything else that runs commands

Use `--once`. It does one sync and exits with status 0 on success and 1 on failure:

```cron
*/2 * * * * ENV_FILE=/path/to/.env /path/to/dexcom-ns-uploader.sh --once >> /var/log/dexcom-ns.log 2>&1
```

## Configuration

| Variable | Default | Notes |
|---|---|---|
| `DEXCOM_USERNAME` | — | Email, `+<country><number>`, or account UUID |
| `DEXCOM_PASSWORD` | — | |
| `DEXCOM_REGION` | `us` | `us`, `ous`, `jp` |
| `NIGHTSCOUT_URL` | — | e.g. `https://my-ns.example.com` |
| `NIGHTSCOUT_API_SECRET` | — | Plain or SHA-1 hashed. Sent as the `api-secret` header |
| `NIGHTSCOUT_TOKEN` | — | Use this instead of the API secret: an access token whose subject has `readable` plus a role with `api:entries:create` (see below) |
| `POLL_INTERVAL` | `120` | Seconds between checks in loop mode (min 60) |
| `BACKFILL_MINUTES` | `1440` | How far back to fill gaps (Dexcom Share keeps 24 h max) |
| `DEVICE_NAME` | `dexcom-g7-ns-uploader` | Shown as the device on each entry |
| `LOG_LEVEL` | `info` | `debug` for more detail |
| `ENV_FILE` | `./.env` next to the script | Path to the env file to load |

## Nightscout access token

You can use your `API_SECRET`, or create a separate access token so you can revoke it later.
Nightscout has no built-in role that can upload entries except `admin`, so add one:

1. In Nightscout, open **Admin Tools** → **Add new Role**. Name: `entries-upload`. Permissions: `api:entries:create`.
2. **Add new Subject**. Name: `dexcom-uploader`. Roles: `readable, entries-upload`.
3. Copy the subject's access token into `NIGHTSCOUT_TOKEN`.

`readable` lets the uploader find the newest entry, and `entries-upload` lets it add new ones.
Giving the subject `admin` also works, but admin can change or delete anything in Nightscout.

## How it works

On each run, the script:

1. Asks Nightscout for its newest SGV entry.
2. Asks Dexcom Share only for readings since then, plus a 10-minute margin and up to 24 h. This fills gaps automatically after an outage.
3. Uploads only readings newer than Nightscout's newest entry, so it never sends duplicates.
4. Reuses the Dexcom session and logs in again only when the session expires.
5. Backs off when errors repeat (up to 30 min), so a wrong password doesn't get your Dexcom account locked.

## Retiring the xDrip phone

Run `--check`, then start the service. Once you see `Uploaded N reading(s)` in the logs, turn off xDrip's Nightscout upload (or the whole phone). For a short overlap both can run, because the script skips readings Nightscout already has.

## Troubleshooting

- **`AccountPasswordInvalid` / invalid id:** wrong username, password or region. Phone numbers need the `+` and country code.
- **Logged in but 0 readings:** Share is off in the G7 app, or the phone running the G7 app is offline.
- **Nightscout HTTP 401:** wrong API secret, or the token's subject is missing a role with `api:entries:create`.
