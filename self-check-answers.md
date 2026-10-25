# Self-check answers

Answers to the seven questions in the guide. Same numbering.

1. **Pitfall #1.** A floating tag such as `postgres:16-alpine` is resolved when each host pulls it. The lab copy pulled it on the day it was created, staging months earlier: same file, different images. Compare `docker inspect <container> --format '{{.Image}}'` on both hosts. Pin `name:tag@sha256:<digest>` with the digest in service, and give the copy the exact images (`docker save` / `docker load`).

2. **Pitfall #5.** It is an update nobody reviewed or tested, applied by a timer. The job should only report: read the registry digest of the tag with `docker buildx imagetools inspect` (no download), compare it with the pinned digest, log and send a message if they differ, check the service answers — and install nothing. The update itself follows the written policy: analysis, lab copy, approval, old digest noted.

3. **Pitfall #4.** No: nothing on the host recorded which digest the floating tag had at build time. Read the PHP, Alpine and Composer versions inside the running container and pin the tags of those same versions. An official tag may have been rebuilt since, so the proof is the next build in the lab, followed by the test suite.

4. **Pitfall #7.** It also clears the application cache — here Redis — and with it state in progress, such as payment confirmations of sessions not yet finished. Clear only `config`, `route` and `view`, one command each.

5. **Pitfall #8.** `horizon:terminate` stops Horizon and counts on a supervisor to start it again. The container has `restart: "no"`, so nothing does: Horizon stays stopped and jobs pile up. Use `docker compose restart app horizon`.

6. **Pitfall #14.** Without `.env.testing`, and with the SQLite lines of `phpunit.xml` commented out, the suite uses the real `.env`: `RefreshDatabase` rebuilds the staging database and `Cache::flush()` empties the real Redis. The tests run on a lab copy, never on a server that holds real data.

7. **Pitfall #16.** `docker exec <app> sh -c 'env | grep ^APP_'` shows what the container's environment imposes — a value set under `environment:` in `docker-compose.yml`, which wins over `.env`; `php artisan about --only=environment` shows what Laravel actually uses. After removing the variable from the compose file, `restart` keeps the old container and its old environment: recreate it with `docker compose up -d --no-deps --no-build app`.
