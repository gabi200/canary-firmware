# Hub announcer (announcer.py): publishes canary-hub.local and _canary-hub._tcp through the host's
# avahi-daemon (D-Bus socket mounted by docker-compose.yml).
FROM alpine:3.24.2
RUN apk add --no-cache python3 avahi-tools iproute2
COPY announcer.py /announcer.py
CMD ["python3", "-u", "/announcer.py"]
