# Kamal Deployment

Documentation for deploying this project with **Kamal v2.12.0**.

This project deploys Vaultwarden (a Rust web app) as a single container to one
EC2 server using [Kamal](https://kamal-deploy.org/), 37signals' Docker-based
deploy tool.

---

## 1. Overview

Kamal's job, on every deploy:

1. **Build** the image from the repo's `Dockerfile` (a symlink to
   `docker/Dockerfile.debian`) using Docker Buildx.
2. **Push** the image to Docker Hub (`aaaleid/vaultwarden`).
3. **SSH** into the server and **pull** the image.
4. **Run** a new container behind **kamal-proxy**, which provides zero-downtime
   (gapless) deployments and automatic Let's Encrypt HTTPS on ports 80/443.
5. **Verify** the app is healthy, then **prune** old containers/images.

---

## 2. Architecture

```
GitHub Actions runner ──build/push──▶ Docker Hub (aaaleid/vaultwarden)
        │
        │ kamal (SSH)
        ▼
EC2 server: kamal-proxy (ports 80/443, Let's Encrypt) ──▶ vaultwarden container (port 80)
        │
        └──▶ volume /vw-data:/data
```

- **Build/control side:** the GitHub Actions runner (or your laptop locally).
- **Runtime side:** a single EC2 instance, SSH user `ec2-user`.
- **Proxy:** `kamal-proxy` handles TLS (Let's Encrypt), host routing, and
  health-checked routing to the app container on port 80.
- **Data:** persists in the host volume `/vw-data` mounted at `/data`
  (SQLite DB, attachments, config).
- **Health:** the app and proxy both use `GET /alive`
  (see `docker/healthcheck.sh`).

---

## 3. Configuration — `config/deploy.yml`

Reference: <https://kamal-deploy.org/docs/configuration/>

| Key | Value | Notes |
|---|---|---|
| `service` | `vaultwarden` | Container name prefix |
| `image` | `aaaleid/vaultwarden` | Docker Hub image (build + push target) |
| `minimum_version` | `2.12.0` | Deploys fail on older Kamal |
| `servers.web.hosts` | `ENV["SERVER_IP"]` | Single EC2 IP, from GitHub Actions `vars.SERVER_IP` |
| `servers.web.options.restart` | `unless-stopped` | Container survives daemon restarts/reboots |
| `registry.username` / `.password` | `aaaleid` / `DOCKER_PA_TOKEN` | Docker Hub Personal Access Token (secret) |
| `proxy.ssl` | `true` | Automatic Let's Encrypt certs |
| `proxy.host` | `ENV["DOMAIN_NAME"]` | From GitHub Actions `vars.DOMAIN_NAME` |
| `proxy.app_port` | `80` | App container listens on 80 |
| `proxy.healthcheck` | `path: /alive`, `interval: 5`, `timeout: 5` | Deploy-time readiness check (seconds) |
| `deploy_timeout` | `60` | Max seconds to wait for the app to become healthy during deploy |
| `ssh.user` | `ec2-user` | SSH login user |
| `volumes` | `/vw-data:/data` | Persistent data |
| `logging.options` | `max-size: 10m`, `max-file: 3` | Docker log rotation |
| `env.clear` | `DOMAIN`, `SIGNUPS_ALLOWED=false`, `ROCKET_PORT=80`, `INVITATIONS_ALLOWED=false`, `SHOW_PASSWORD_HINT=false` | Runtime env for the app |
| `env.secret` | `ADMIN_TOKEN` | Admin token injected at runtime from `.kamal/secrets` |
| `builder.arch` | `amd64` | Server architecture |
| `builder.args.DB` | `sqlite,mysql,postgresql` | Docker build arg (DB features) |
| `builder.cache.type` | `gha` | GitHub Actions build cache |

### Kamal 2.x notes (things that existed in 1.x)

- **No `rolling` config.** `kamal-proxy` handles gapless deployments natively.
  Host boot batching is done via `boot: { limit: <n or %>, wait: <sec> }`
  (irrelevant for a single server).
- **No `lock_timeout` config.** Locking is CLI-based:
  `kamal deploy --lock-wait [--lock-wait-timeout SECS]`.
- **Docker options** (`restart`, etc.) live under `servers.<role>.options` —
  the host list must be wrapped in `hosts:` when options are present.

---

## 4. Secrets — `.kamal/secrets`

`.kamal/secrets` is a dotenv file that maps **env var names** to Kamal secret
names. It contains **no real values** and is safe for git.

| Secret | Referenced by | Source |
|---|---|---|
| `DOCKER_PA_TOKEN=$DOCKER_PA_TOKEN` | `registry.password` | GitHub Actions secret `DOCKER_PA_TOKEN` |
| `ADMIN_TOKEN=$ADMIN_TOKEN` | `env.secret` | GitHub Actions secret `ADMIN_TOKEN` |

Flow: **GitHub Actions secret → step env → `.kamal/secrets` → Kamal**.

For local deploys, export the same variables in your shell:

```bash
export SERVER_IP="1.2.3.4"
export DOMAIN_NAME="vault.example.com"
export ADMIN_TOKEN="..."
export DOCKER_PA_TOKEN="..."
```

---

## 5. Hooks — `.kamal/hooks/`

Hooks are executable scripts Kamal runs locally (on the control machine) around
deploy phases. They are optional; a non-zero exit aborts the deployment.

| Hook | Runs | Purpose |
|---|---|---|
| `pre-build` | before building the image | Aborts if the git checkout is dirty. In CI (detects `GITHUB_ACTIONS`) skips branch/remote checks (detached HEAD). Locally, also verifies the branch is pushed and `KAMAL_VERSION` matches remote HEAD |
| `post-deploy` | after a successful deploy/rollback | Polls `https://${DOMAIN_NAME}/alive` (30 × 10s) and logs a summary (`performer`, `version`, `runtime`). Skips if `DOMAIN_NAME` is unset |

Environment available to hooks: `KAMAL_RECORDED_AT`, `KAMAL_PERFORMER`,
`KAMAL_VERSION`, `KAMAL_HOSTS`, `KAMAL_ROLES`, `KAMAL_DESTINATION`, and
`KAMAL_RUNTIME` (post-deploy). Disable hooks with `--skip-hooks`.

---

## 6. CI/CD Workflows

### `deploy.yml` — automatic + manual deploy

Triggered by:

- **Push to `main`** — deploys after waiting for CI checks to pass
  (Check-Runs API, 30-min timeout, fails fast on any failed/cancelled check;
  skips if no checks exist for the commit, e.g. docs-only pushes).
- **Manual `workflow_dispatch`** — optional `tag_override` input deploys an
  arbitrary branch/tag/SHA instead of the current `main` HEAD; **skips the CI
  wait**.

Pipeline: checkout → Buildx + GHA cache → Ruby + `gem install kamal -v 2.12.0`
→ SSH agent + `ssh-keyscan` known hosts → CI gate (push only) → create GitHub
deployment record (`production`) → `kamal deploy --lock-wait` → verify
`/alive` (30 × 10s) → mark deployment success/failure.

Safeguards:

- `concurrency: group=deploy-production` — only one deploy/rollback at a time.
- `--lock-wait` — waits (default 900s) for a lock held by an out-of-band
  (e.g. local) deploy instead of failing.
- Permissions: `contents: read`, `deployments: write`, `checks: read`.
- Job `timeout-minutes: 120`.

### `rollback.yml` — manual rollback

Triggered by **manual `workflow_dispatch` only**, input `version` (a git SHA
that was previously deployed).

Pipeline: checkout (current config) → Ruby + Kamal → SSH → create deployment
record → `kamal rollback <VERSION>` → verify `/alive` → mark success/failure.

Notes:

- `kamal rollback` takes a **positional version** — there is no `--steps`.
- The version must still exist as a container on the server
  (list with `kamal app containers`); if not, Kamal prints
  *"not available as a container"* and the workflow fails.
- Both workflows share the `deploy-production` concurrency group, so a deploy
  and a rollback can never run at the same time.

---

## 7. Local Deploy Commands

Run from the repo root with the env vars from section 4 exported.

| Command | Purpose |
|---|---|
| `kamal setup` | First-time provisioning: install Docker on the server, boot proxy, deploy |
| `kamal deploy` | Build, push, deploy (zero-downtime) |
| `kamal deploy --lock-wait` | Same, but waits if another deploy holds the lock |
| `kamal rollback <sha>` | Revert to a previously deployed version |
| `kamal app containers` | List available versions on the server (for rollback) |
| `kamal app version` | Show the currently running version |
| `kamal app logs` | Stream app logs |
| `kamal app details` | Container status per host |
| `kamal app exec bin/sh` | Open a shell inside the container |
| `kamal proxy logs` | kamal-proxy logs (TLS/routing issues) |
| `kamal lock status` | Check the deploy lock |
| `kamal prune` | Manually clean up old containers/images |
| `kamal env` / `kamal env push` | Inspect / push the runtime env file to the server |
| `kamal details` | Overview: proxy + app status on all hosts |

Useful flags: `-v` verbose, `-q` quiet, `-H` skip hooks, `-d <dest>` for a
destination (staging) config (`config/deploy.<dest>.yml` — none configured).

---

## 8. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Deploy aborts with a `pre-build`/`post-deploy` hook error | Hook exited non-zero; check output. `--skip-hooks` bypasses (not recommended) |
| `Locked by ...` during deploy | Another deploy holds the lock; use `--lock-wait` or `kamal lock status` / release manually on the server |
| Rollback says version is *not available as a container* | That version was pruned or never deployed; list versions with `kamal app containers` |
| Deploy waits then fails on the CI gate | A CI check failed or took > 30 min; check the commit's checks page. Re-run via `workflow_dispatch` to bypass |
| App unhealthy after deploy | Check `kamal app logs`, `kamal proxy logs`, and DNS for `DOMAIN_NAME`; verify ports 80/443 are open for Let's Encrypt |
| SSL certificate issues | kamal-proxy needs port 443 open and `proxy.host` pointing at the server |
| Image push fails | Registry token expired; refresh `DOCKER_PA_TOKEN` in GitHub Actions secrets |

---

*Config reference: <https://kamal-deploy.org/docs/configuration/> ·
Source: <https://github.com/basecamp/kamal>*
