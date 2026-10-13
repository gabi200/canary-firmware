# Canary three-Pi hub: PostgreSQL 16 run by Patroni, one per Pi (RUNME.md section 3).
# Built by docker compose (service "postgres", profile "cluster"). The base image already carries
# the PGDG apt repository, which ships Patroni; python3-etcd is what Patroni's etcd3 support
# imports. Multi-arch, so it builds natively on a Pi (arm64).
FROM postgres:16.15-bookworm

# patroni 4.1.x: patch releases only, a new minor or major is a deliberate upgrade.
RUN apt-get update \
    && apt-get install -y --no-install-recommends "patroni=4.1.*" python3-etcd \
    && rm -rf /var/lib/apt/lists/* \
    && patroni --version \
    && python3 -c "import patroni.dcs.etcd3"

COPY patroni.yml /etc/patroni/patroni.yml
COPY entrypoint.sh /usr/local/bin/canary-patroni
COPY post_bootstrap.sh /usr/local/bin/canary-post-bootstrap

# PGDATA is a subdirectory of the image's volume, so initdb can create it with mode 0700.
# PATRONICTL_CONFIG_FILE: `docker compose exec postgres patronictl list` needs no -c.
ENV PGDATA=/var/lib/postgresql/data/pgdata \
    PATRONICTL_CONFIG_FILE=/etc/patroni/patroni.yml

USER postgres
# Patroni (PID 1) shuts PostgreSQL down cleanly and hands the leader role over on SIGTERM.
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/canary-patroni"]
