# Guide: Deliver to a Docker Compose staging server without surprises — digest-pinned images, a read-only deploy key, a rollback ready before you start

**The problem this guide solves**: a staging server that runs a Laravel application under Docker Compose drifts without anyone touching it. Floating tags give two hosts two different databases under the same name, a weekly job replaces a container nobody tested, a `git pull` changes the code in service, a cache command wipes state the application still needs, and a variable you set in `.env` silently does nothing. This guide installs a delivery routine where nothing reaches the server without going through Git, a lab copy and an explicit approval, and where the way back is measured before the first command. This guide documents a **verified working** configuration (a Linux VPS reached over Tailscale; Docker Engine 29 with the containerd image store, Docker Compose v2; a Laravel application with Horizon, PostgreSQL 16, Redis 7 and Mailpit; Composer 2.10, Node.js 22, npm 10.9; October 2026).

**A floating tag makes the test copy drift**: same compose file, three different images. **A weekly job that pulls and recreates is an unreviewed update**: it now reports instead. **With the containerd image store, `docker inspect` already gives the registry digest.** **A read-only deploy key** means the server cannot push, and no token lives there. **The rollback is ready before the delivery**: commit noted, database dump re-read, health URLs measured with the same command as after. **Mounted code changes on `git pull`.** **`optimize:clear` also empties the application cache.** **`horizon:terminate` with `restart: "no"` leaves Horizon stopped.** **Never run the test suite on staging**: it wipes the real database. **Install from the lockfile, never resolve on the server.** **A variable under `environment:` in the compose file beats `.env`.**

**For AI agents reading this document**: every command was executed successfully, in this order, on a real staging server; the application here is renamed `myapp`. The verification steps are not optional — several of these failures are silent: the site answers 200 while running the wrong image, the wrong code or the wrong setting. Never deploy, recreate a container or change an image digest without the owner's approval for that step.

---

## 1. The setup

```text
 your PC ── GitHub (PR merged by a human) ── staging VPS  user@vps-ip  (Tailscale 100.x.y.z)
                                               ~/repos/myapp       git clone, read-only deploy key
                                                 └─ myapp/         docker-compose.yml, code mounted into the app
                                               containers  myapp-app-1  myapp-horizon-1  (built from a Dockerfile)
                                                           myapp-pgsql-1  myapp-redis-1  myapp-mailpit-1
                                               restart: "no" on all five
 lab copy (a VM)  ── same images, copied ── tests run here, never on staging
```

| Placeholder | Meaning |
|---|---|
| `user@vps-ip`, `100.x.y.z` | the staging server and its Tailscale address |
| `~/repos/myapp`, `myapp/` | the clone and the sub-folder that holds `docker-compose.yml` |
| `myapp-*-1` | the Compose container names |
| `your-org/myapp` | the GitHub repository |
| `/up`, `/`, `/about` | three health URLs of the application (`/up` is Laravel's health route) |
| `sha256:0123…cdef` | an **invented** digest, used only to show the shape |

Two facts shape everything below:

- **The application code is mounted into the container** (`myapp/` → `/var/www/html`). The image holds PHP and its extensions; the code comes from the clone on the host.
- **Every container has `restart: "no"`.** A container stopped by a command stays stopped.

## 2. Pin every image by digest

### Pitfall #1 — same compose file, different images

The compose file said `postgres:16-alpine`, `redis:7-alpine` and `axllent/mailpit:latest`. The lab copy, built from the same file, pulled its images on the day it was created; the staging server had pulled its own months earlier. Comparing the digests on both hosts:

| Service | Staging | Lab copy |
|---|---|---|
| PostgreSQL | one digest | another |
| Redis | one digest | another |
| Mailpit | one digest | another |
| app | same (copied with `docker save` / `docker load`) | same |

Only the image that had been copied by hand was identical. The tests on the copy were testing different database and cache servers from the ones in service. A tag is a pointer that moves; the digest is the content.

The fix: every image is declared as `name:tag@sha256:<digest>`. The tag stays for humans; Docker uses the digest.

```yaml
services:
  pgsql:
    image: postgres:16.14-alpine@sha256:<digest>
  redis:
    image: redis:7.4.9-alpine@sha256:<digest>
  mailpit:
    image: axllent/mailpit:v1.30.4@sha256:<digest>
```

The starting point is the digest **already in service**, not a fresh pull: pinning must not change anything.

### Pitfall #2 — with containerd, the image ID *is* the registry digest

With Docker 29 and the containerd image store, the image a container runs is reported directly as the digest of the registry's index — the exact value you can pin:

```bash
docker inspect myapp-pgsql-1 --format '{{.Image}}'
```

The registry's current digest for a tag is read **without downloading anything**:

```bash
docker buildx imagetools inspect postgres:16.14-alpine --format '{{.Manifest.Digest}}'
```

These two commands are the whole of the update check in section 3.

### Pitfall #3 — which version is behind a digest?

A floating tag tells you nothing: `16-alpine` could be any 16.x. Read the version from the image itself — PostgreSQL and Redis images carry it in their environment (`PG_VERSION`, `REDIS_VERSION`), and a binary usually has a version command:

```bash
docker exec myapp-mailpit-1 /mailpit version
```

Then check that the **precise tag** (`16.14-alpine`) points to **the same digest** as the one in service, with `docker buildx imagetools inspect` above. Only then write `postgres:16.14-alpine@sha256:<digest>`.

### Pitfall #4 — the base images of a built image cannot be recovered

`myapp-app` and `myapp-horizon` are built from a `Dockerfile` whose `FROM` lines used floating tags (`php:8.3-fpm-alpine`, `composer:2`). The digest those tags had when the image was built months ago is gone: nothing on the host records it.

What you can do: read the versions in the running container (PHP, Alpine, Composer) and pin the tags of **those same versions** in the `Dockerfile` (`php:8.3.<patch>-fpm-alpine3.<minor>`, `composer:2.<minor>.<patch>`). An official tag can have been rebuilt since, with the same version and a different content — so this pin is a best effort. The real proof is the **next build, in the lab**, followed by the test suite.

## 3. Nothing updates itself

### Pitfall #5 — a weekly job that pulls and recreates is an untested update

A systemd timer ran a weekly maintenance script every Sunday. For the monitoring container, it pulled the floating tag and, if the image had changed, recreated the container — without a test, without anyone knowing until something broke.

It was replaced by [`files/weekly-maintenance.sh`](files/weekly-maintenance.sh), which **reports and installs nothing**. For each image it:

1. reads the registry digest of the tracked tag (`imagetools inspect`, no download);
2. compares it with the pinned digest; if they differ, writes a log line and sends a Telegram message (container, tag, two short digests);
3. warns if the running container is not on the pinned digest;
4. checks that the service answers (HTTP 2xx or 3xx, six tries, ten seconds apart).

The Telegram bot token is read from a root-only file and passed to `curl` on standard input, so it never appears in the process list. The script was verified with one entry (a monitoring container); each entry needs an HTTP health URL. The digest in the file is invented: put yours.

### The written update policy

A pin with no update rule turns into an image nobody updates. The policy, written down before the first pin:

- **Rhythm**: monthly — and **immediately** if your vulnerability watch flags the image.
- **Steps**:
  1. the new registry digest (`imagetools inspect`);
  2. analysis: an SBOM of the new image and a lookup in a vulnerability database;
  3. the new image in the lab copy, test suite green;
  4. the digest changed in the compose file, **with the owner's approval**;
  5. the **old digest noted** for the rollback.
- Base images of a `Dockerfile` and images of a project's compose file change in a branch of the project, like any other code change.
- Unused images are deleted with the owner's approval (they can be pulled again).

## 4. A read-only deploy key

The server clones over SSH with a **GitHub deploy key, read-only, for this one repository**. An alias in `~/.ssh/config` of the deploying user selects the key:

```text
Host github-myapp
  HostName github.com
  User git
  IdentityFile ~/.ssh/myapp_deploy
```

and the clone's remote is `github-myapp:your-org/myapp.git`.

Two checks, done once:

- **The key cannot write**: a test `git push` from the server must be refused with a message saying the key is **marked as read only**. That refusal is the proof; a key that pushes is a write key.
- **The GitHub host key is the real one**: before it enters `known_hosts`, compare its fingerprint with the SSH fingerprints GitHub publishes at `https://api.github.com/meta`.

**No token on the server**, for any purpose. A change to the repository is made elsewhere and arrives as a merged pull request.

## 5. Before the delivery: the way back, measured

The pull request is merged on GitHub by a human. On the server, look at what is coming before taking anything:

```bash
cd ~/repos/myapp
git fetch origin
git log --oneline HEAD..origin/main
git diff --stat HEAD origin/main
git merge-base --is-ancestor HEAD origin/main && echo fast-forward
```

If `composer.lock` or `package-lock.json` change, read section 7 first.

Then prepare the rollback **before** the first change:

1. **Note `HEAD`** (`git rev-parse HEAD`).
2. **Dump the database, hash it, re-read it**:

   ```bash
   mkdir -p ~/backups-delivery
   docker exec myapp-pgsql-1 pg_dump -U myuser -Fc mydb > ~/backups-delivery/myapp-before-<commit>.dump
   sha256sum ~/backups-delivery/myapp-before-<commit>.dump | tee ~/backups-delivery/myapp-before-<commit>.dump.sha256
   docker exec -i myapp-pgsql-1 pg_restore --list < ~/backups-delivery/myapp-before-<commit>.dump | grep -c "TABLE DATA"
   ```

   The last line proves the archive can be read, and the count must match the number of tables you expect. A dump file that exists is not a backup until something has read it.
3. **Measure the health URLs before**, with the exact command you will use after:

   ```bash
   for p in /up / /about; do echo "$p $(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://100.x.y.z:8080$p")"; done
   ```

   A 500 after the delivery means nothing if you do not know the page already answered 500 before.

## 6. The delivery

With the owner's approval:

```bash
git -C ~/repos/myapp pull --ff-only origin main
docker exec myapp-app-1 php artisan config:clear
docker exec myapp-app-1 php artisan route:clear
docker exec myapp-app-1 php artisan view:clear
cd ~/repos/myapp/myapp && docker compose restart app horizon
```

### Pitfall #6 — mounted code changes on `git pull`

Because the code is mounted, `git pull` **is** the deployment: the moment it finishes, PHP serves the new files. There is no build to wait for and no image to roll back. The backup, the noted `HEAD` and the before-measurements of section 5 have to exist before this line, not after.

### Pitfall #7 — `optimize:clear` also empties the application cache

`php artisan optimize:clear` looks like the tidy way to reset caches after a deployment. It also clears the **application cache** — here Redis — which holds state in progress: a payment confirmation waiting to be picked up by the user's next request, for instance. On a staging server without customers it costs nothing; on a production server it loses transactions. Clear only what a deployment needs: `config:clear`, `route:clear`, `view:clear`, one by one.

### Pitfall #8 — `horizon:terminate` with `restart: "no"`

`php artisan horizon:terminate` is the documented way to make Horizon pick up new code: it stops, and the process supervisor starts it again. Here there is no supervisor: the container has `restart: "no"`, so Horizon would stay stopped and queued jobs would pile up. Use `docker compose restart app horizon`.

### Pitfall #9 — a compose file modified on the server makes `git pull --ff-only` refuse

The server's copy of `docker-compose.yml` carried a local change (a healthcheck added on the server). When a merged branch also touched that file, `git pull --ff-only` refused to overwrite the local change. Do not force it, and do not discard the change without reading it:

```bash
git -C ~/repos/myapp diff myapp/docker-compose.yml
git -C ~/repos/myapp stash
git -C ~/repos/myapp pull --ff-only origin main
git -C ~/repos/myapp stash pop
git -C ~/repos/myapp diff myapp/docker-compose.yml
```

Read the result of `stash pop` before going further. Keep a copy of the file (`cp docker-compose.yml docker-compose.yml.bak-<date>`) before the first step.

### Pitfall #10 — what `docker compose up -d` would do, and `down -v`

Changing the `image:` lines to pinned digests does not change any running container by itself — but the next `docker compose up -d` would act on it. Ask first:

```bash
cd ~/repos/myapp/myapp && docker compose up -d --dry-run
```

It announced that `pgsql`, `redis` and `mailpit` would be **recreated** — their declaration changed, although the images were the same: a short outage, not a no-op. It also warned that the database and Redis volumes **were not created by Compose** (they came from an earlier setup). Compose reuses them; the warning is harmless. But it is a reminder: **never `docker compose down -v`** on this server. `-v` deletes named volumes, and these hold the only copy of the data besides your backups.

When a delivery only changes the compose declaration and the images are identical, there is no need to recreate anything that day.

## 7. Dependencies: install the lockfile, never resolve it on the server

Versions are decided **in a branch**, on the lab copy, with green tests and approval. The server only installs what `composer.lock` and `package-lock.json` say.

| What | On the staging server | Never on the server |
|---|---|---|
| PHP | `docker exec myapp-app-1 composer install --no-interaction` | `composer update`, `composer require` |
| JS | on the host, in `myapp/`: `npm ci && npm run build` (the app container has no Node) | `npm install`, `npm update`, `npm audit fix` |

### Pitfall #11 — run Composer in the application container, not in `composer:2`

The official `composer:2` image looks like the natural tool. It lacks the PHP extensions the application requires (`intl`, `pcntl`), so Composer refuses the platform. The application container has them: run `composer install` there.

### Pitfall #12 — `npm ci` fails on purpose

`npm ci` starts from scratch (deletes `node_modules`) and **fails** if the lockfile does not match `package.json`. That failure is the point: `npm install` would rewrite the lockfile silently and install versions nobody tested. A dry run checks the match without touching anything:

```bash
npm ci --dry-run --ignore-scripts
```

After an install, the lockfiles must be unchanged:

```bash
git -C ~/repos/myapp status --porcelain
```

No `composer.lock` and no `package-lock.json` in that output. Your known local changes (section 6, pitfall #9) may be there; note what the expected state is, so that anything else stands out.

### Pitfall #13 — `"*"` constraints in `composer.json`

Four dependencies were declared as `"*"`. The lockfile protects you only as long as you run `install`; the first `composer update` would jump to a new major version without warning. Each one was bounded to its current major version, with the minor as a floor (`^5.46` for a package at 5.46.x). The check that goes from red to green:

```bash
composer validate --strict
```

Red before (one "unbound version constraint" per `"*"`), green after, and red again if a `"*"` comes back. The installed packages were identical before and after (only the lockfile's `content-hash` changed), and the test suite on the lab copy was green before and after.

## 8. Never run the test suite on staging

### Pitfall #14 — `php artisan test` on staging wipes the real database

It is tempting to "just run the tests" on the server after a delivery. On this server there was **no `.env.testing`**, the SQLite lines of `phpunit.xml` were commented out, and `.env` pointed at the real database. The suite would have run `RefreshDatabase` against the **staging data** and `Cache::flush()` against the **real Redis**. Tests run on the lab copy, never on a server that holds real data. If a repository's agent instructions say otherwise, fix the instructions.

### Pitfall #15 — a lab copy without a locally built image

The lab copy was rebuilt on the exact staging images, transferred with `docker save` on the server and `docker load` in the lab. One built image (`myapp-horizon`) was not transferred, and `docker compose up -d --no-build` stopped on the missing service. Name the services you want instead:

```bash
docker compose up -d --no-build pgsql redis mailpit
```

## 9. Where a variable's value really comes from

### Pitfall #16 — a variable under `environment:` beats `.env`

The staging server showed Laravel's debug page on every error 500. `.env` said `APP_DEBUG=false`, and changing it did nothing. The cause was in `docker-compose.yml`, under the `app` service:

```yaml
    environment:
      APP_DEBUG: "true"
```

A variable set under `environment:` is in the container's environment, and Laravel does not override an environment variable with the `.env` file. `.env` loses.

To see the values the application actually runs with, and where they come from:

```bash
docker exec myapp-app-1 sh -c 'env | grep ^APP_'
docker exec myapp-app-1 php artisan about --only=environment
```

The first shows what the container's environment imposes; the second shows what Laravel ended up with (`Debug Mode`, `Environment`). The fix was to delete `APP_DEBUG` from the compose file (in a branch, merged like any change), leave `.env` in charge, and **recreate** the container — `docker compose restart` keeps the old environment:

```bash
cd ~/repos/myapp/myapp && docker compose up -d --no-deps --no-build app
```

`--no-deps` leaves the database, Redis and Horizon alone; `--no-build` reuses the pinned image. It was proved on the lab copy with a provoked error 500 (database and Redis stopped): before the fix, `.env` set to `false` still returned the full debug page; after it, `false` gave a short page without a trace and `true` the debug page again.

## 10. End-to-end verification

After every delivery, in this order:

```bash
cd ~/repos/myapp/myapp && docker compose ps
for p in /up / /about; do echo "$p $(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://100.x.y.z:8080$p")"; done
docker exec myapp-app-1 grep -n "<a line of the fix>" /var/www/html/<changed file>
docker logs --since 2m myapp-app-1
docker logs --since 2m myapp-horizon-1
```

| Check | ✅ Expected | ❌ What it means |
|---|---|---|
| `docker compose ps` | every service `healthy` | a container did not start, or Horizon stayed stopped (pitfall #8) |
| health URLs | the same codes as before the delivery (200) | the delivery broke a page — roll back |
| `grep` of the fix **inside the container** | the new line is there | the pull did not reach the mounted folder, or you are looking at the wrong clone |
| `docker logs --since 2m` | no error | an error the pages do not show yet |
| `artisan about --only=environment` (if a setting changed) | the value you set | another source wins (pitfall #16) |
| `git status --porcelain` | only the expected local changes, no lockfile | something resolved dependencies on the server (pitfall #12) |

These checks prove the delivery arrived and nothing visible broke; the functional proof remains the test suite on the lab copy.

**Then, the same day**: re-run your component inventory and vulnerability watch. What the delivery brought in (a new package, a new image) is seen the day it arrives, not at the next weekly run.

### Rollback

```bash
git -C ~/repos/myapp reset --hard <HEAD noted before>
docker exec myapp-app-1 php artisan config:clear
docker exec myapp-app-1 php artisan route:clear
docker exec myapp-app-1 php artisan view:clear
cd ~/repos/myapp/myapp && docker compose restart app horizon
```

The database only if the delivery changed it (`pg_restore --clean` from the dump of section 5). For an image change: put the old digest back in the compose file and recreate that service. If a stash was involved (pitfall #9), `stash pop` again after the reset and re-read the file.

## Symptom / Cause / Fix

| Symptom | Cause | Fix |
|---|---|---|
| Tests pass on the copy, behaviour differs on staging | floating tags pulled at different dates | pin `name:tag@sha256:<digest>`, copy the exact images |
| A container changed on a Sunday, nobody did anything | weekly job pulls and recreates | a script that reports and installs nothing |
| No idea which version `16-alpine` is | floating tag | `PG_VERSION` / version command, then check the precise tag's digest |
| Old base-image digest not found | never recorded | pin the same versions; prove it with the next lab build |
| Code in service changed before the backup | code is mounted | backup and measurements before `git pull` |
| Payment confirmation lost after a deployment | `optimize:clear` empties the app cache | `config:clear`, `route:clear`, `view:clear` |
| Jobs pile up after a deployment | `horizon:terminate` with `restart: "no"` | `docker compose restart app horizon` |
| `git pull --ff-only` refuses | compose file modified on the server | diff, stash, pull, stash pop, re-read |
| `--dry-run` announces recreations, volume warning | declaration changed; volumes predate Compose | expected; never `down -v` |
| Real data gone after "running the tests" | no `.env.testing`, `RefreshDatabase` | tests only on the lab copy |
| `up -d --no-build` stops on a service | image not in the copy | name the services to start |
| `composer install` refuses the platform in `composer:2` | missing `intl`, `pcntl` | run it in the app container |
| `npm ci` fails | lockfile ≠ `package.json` | fix it in a branch, never `npm install` on the server |
| `composer validate --strict` red | `"*"` constraints | bound each to its major version |
| `.env` change has no effect | variable under `environment:` | remove it from the compose file, recreate the container |

## Known limitations

- **The staging server installs Composer's development packages.** A production server would run `composer install --no-dev`; that decision belongs to the day a production server exists.
- **Base images of built images are pinned by version, not by their original digest** (pitfall #4). Until the next lab build passes, the pin is a best effort.
- **The checks after delivery are smoke checks.** They do not replace the test suite on the lab copy.
- **Mounted code has no image to roll back to**: the rollback is Git plus the database dump, nothing more.
- **The weekly script reports one class of change** (a new digest for a tracked tag). It does not scan for vulnerabilities; that is the job of a separate watch.
- **A deploy key is per repository.** A second repository needs its own key and its own alias.
- **The update policy is a human process.** Nothing enforces the approval step except discipline and the absence of write access on the server.

## Self-check

Seven questions. Each one is answered by a pitfall above. Write the answer down before you open [self-check-answers.md](self-check-answers.md).

1. **Pitfall #1.** Your lab copy uses the same `docker-compose.yml` as staging and its tests are green. Why may that prove nothing about the PostgreSQL in service?
2. **Pitfall #5.** A weekly job keeps your monitoring container "up to date" by pulling its tag and recreating it. What is wrong with that, and what should the job do instead?
3. **Pitfall #4.** You want to pin the `FROM php:8.3-fpm-alpine` of an image built four months ago. Can you recover the digest it was built from? What do you pin, and what proves it?
4. **Pitfall #7.** After a deployment you run `php artisan optimize:clear` to be safe. What can that lose on a production server?
5. **Pitfall #8.** Why does `php artisan horizon:terminate` leave this staging server without a running queue?
6. **Pitfall #14.** A colleague proposes running `php artisan test` on staging to check the delivery. What happens to the data, and where should the tests run?
7. **Pitfall #16.** You set `APP_DEBUG=false` in `.env` and restart the container; the debug page still appears. Which two commands tell you where the value comes from, and why is `docker compose restart` not enough after you fix it?

## Credits

Built on [Docker Engine and Docker Compose](https://docs.docker.com/) (Apache 2.0), [Laravel](https://laravel.com/) and [Laravel Horizon](https://laravel.com/docs/horizon) (MIT), [PostgreSQL](https://www.postgresql.org/) (PostgreSQL License), [Redis](https://redis.io/), [Mailpit](https://mailpit.axllent.org/) (MIT), [Composer](https://getcomposer.org/) (MIT), [npm](https://www.npmjs.com/) and [Tailscale](https://tailscale.com/). No text from their documentation is copied here.

---

*Guide written and verified in October 2026 on a Linux VPS staging server and a lab VM. Versions: Docker Engine 29 (containerd image store), Docker Compose v2, PostgreSQL 16.14 (alpine), Redis 7.4.9 (alpine), Mailpit v1.30.4, PHP 8.3 (fpm-alpine), Composer 2.10, Node.js 22.23, npm 10.9.*
