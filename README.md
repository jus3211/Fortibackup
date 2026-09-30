# Fortibackup

Backs up FortiGate configurations locally on a Debian probe, on a schedule, for multiple clients from a single config file. IT Glue upload is built in and ready to enable per client when needed.

## What it does

1. **`FortinetConfigBackupv1.sh`** — calls the FortiGate REST API to export the full running configuration (`POST /api/v2/monitor/system/config/backup`) and saves it locally with a timestamped filename. Keeps the last 7 backups per client, deletes older ones.
2. **`FortinetConfigUloadToITGlue.sh`** — uploads the most recent file in a folder as an attachment to an IT Glue document (EU pod). Not required — only runs for clients that have IT Glue credentials configured.
3. **`run_all_clients.sh`** — reads `clients.conf` and runs the backup (and, if configured, the upload) for every client listed. One client failing doesn't stop the others.
4. **`install.sh`** — installs everything to `/opt/fortibackup` on a Debian probe, walks through the client's FortiGate/IT Glue details in a `whiptail` text UI, and sets up a daily cron job + log rotation.
5. **`bootstrap.sh`** — one-command entry point that downloads this repo and runs `install.sh`.

Each probe is normally deployed for **one client**, but `clients.conf` supports multiple lines if you ever need to run several clients from one probe.

## Quick install

On a fresh Debian probe, as a user with `sudo` rights:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/jus3211/Fortibackup/main/bootstrap.sh)"
```

This downloads the repo, installs dependencies (`curl`, `python3`, `cron`, `whiptail`), copies the scripts to `/opt/fortibackup`, and walks you through a text-UI setup wizard:

- Client name
- FortiGate API base URL and API token (see [FortiGate API access](#fortigate-api-access) below)
- Whether to configure IT Glue upload now, or skip it for later
- Local backup folder
- Daily cron time

## Manual install

If you already have the repo locally (e.g. copied over `scp`):

```bash
sudo ./install.sh
```

Re-running `install.sh` at any time lets you update the client config or reschedule the cron job (it will ask before overwriting an existing `clients.conf`, and backs it up first).

## FortiGate API access

Create a dedicated API admin on the FortiGate, restricted to the probe's IP, with the minimum profile that actually works for config backup:

1. **System → Administrators → Create New → REST API Admin**
2. Assign an admin profile with:
   - **System** set to **Custom**, with only the **Administrator Users** sub-permission set to **Read/Write**. The other System sub-permissions — **Configuration**, **FortiGuard Updates**, **Maintenance** — can stay at **Read**. (A blanket `Read` on the whole System category gets a `403` on the backup endpoint even though "backup" is conceptually a read-only action — this is documented Fortinet behavior, not a bug in these scripts. Setting the whole category to `Read/Write` also works but is broader than necessary.)
   - Every other category (Firewall, Network, VPN, Log & Report, Security Fabric, User & Device, WiFi & Switch, FortiView, etc.) can stay at **Read**.
   - There's no need to use the built-in `super_admin` profile — the above is the least-privilege profile confirmed to work.
3. **Trusted Hosts**: set this to the probe's IP, e.g. `10.0.123.174/32`. **Do not leave this empty** — unlike a regular GUI admin account, a REST API admin with no Trusted Host configured gets every request rejected with `403`, regardless of a valid token.
4. Save — the API token is shown **once**. Copy it immediately.
5. Make sure HTTPS admin access is enabled on the interface the probe reaches.

Paste the raw token when `install.sh` asks for it (don't check "base64 encoded" unless you deliberately encoded it yourself).

> **Firmware note:** on FortiOS 7.4.x/7.6.x, the config backup endpoint requires `POST` with a JSON body (`{"destination":"file","file_format":"fos","scope":"global"}`), not the `GET` with query-string params used by older API docs/examples. `FortinetConfigBackupv1.sh` already does this. If you hit `HTTP 405` on a different firmware version, capture the real request FortiOS' own GUI sends (browser dev tools → Network tab, trigger a manual **System → Configuration → Backup**) and compare.

> **Troubleshooting 403:** in order of likelihood — (1) Trusted Hosts not set on the API admin, (2) System → Administrator Users not set to `Read/Write`, (3) some other category missing `Read`. The response body from a manual `curl` test (see below) sometimes gives a bit more detail than the plain HTTP status.
>
> ```bash
> curl -k -X POST -H "Authorization: Bearer <token>" -H "Content-Type: application/json" \
>   -d '{"destination":"file","file_format":"fos","scope":"global"}' \
>   "https://<firewall-host>:8443/api/v2/monitor/system/config/backup" \
>   -o /tmp/test.conf -w "\nHTTP:%{http_code}\n"
> cat /tmp/test.conf
> ```

## clients.conf format

One line per client, comma-separated, no spaces around commas. Lines starting with `#` and blank lines are ignored.

```
CLIENT_NAME,FIREWALL_HOST,API_TOKEN,BASE64,ITGLUE_API_KEY,ITGLUE_DOCUMENT_ID,OUTPUT_DIR
```

| Field | Description |
|---|---|
| `CLIENT_NAME` | Free-text name, used for logging only |
| `FIREWALL_HOST` | FortiGate API base URL, e.g. `https://10.0.103.254:8443` |
| `API_TOKEN` | FortiGate API token |
| `BASE64` | `yes` / `no` — is `API_TOKEN` base64-encoded? |
| `ITGLUE_API_KEY` | IT Glue API key, or `-` to skip upload for this client |
| `ITGLUE_DOCUMENT_ID` | IT Glue document ID, or `-` to skip upload for this client |
| `OUTPUT_DIR` | Local folder where backups for this client are stored |

See [`clients.conf.example`](clients.conf.example) for sample lines. The file is created with `chmod 600` (contains secrets in plain text) — keep it that way.

Enabling IT Glue upload later for a client that started with `-,-` just means filling in those two fields (manually or by re-running `install.sh`) — no script changes needed.

## Running manually

```bash
sudo /opt/fortibackup/run_all_clients.sh -c /opt/fortibackup/clients.conf
```

## Scheduling

The installer sets up `/etc/cron.d/fortibackup` for a daily run, logging to `/var/log/fortibackup/run.log` (rotated weekly, 8 copies kept via `/etc/logrotate.d/fortibackup`). Re-run `install.sh` to change the schedule.

## Known limitations

- `API_TOKEN` and `ITGLUE_API_KEY` are passed as CLI arguments to the underlying scripts, which makes them briefly visible to other local users via `ps`. Acceptable for now on single-purpose probes; worth hardening (env vars or a secrets file) before wider rollout.
- IT Glue upload payloads are capped at 10 MB (IT Glue's API limit) — the upload script checks this before sending and fails cleanly if exceeded.

## Roadmap

- [ ] Re-enable IT Glue upload per client once ready.
- [ ] Consider a non-interactive/batch mode for `install.sh` for scaling deployment across many probes.
