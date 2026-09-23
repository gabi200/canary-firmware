# Canary simulators: MQTT only, no hardware needed. Multi-arch base image.
#   hw_sim.py    firmware-accurate ESP32 air + water nodes (default entrypoint)
#   simulate.py  legacy canary.telemetry.v1 sensors (compose service "simulator")
# Broker settings come from MQTT_HOST / MQTT_PORT / MQTT_USERNAME / MQTT_PASSWORD
# (set by docker-compose.yml), so `run --rm hw-sim --scenario co` needs no flags.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /sim
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY hw_sim.py simulate.py ./

USER nobody
ENTRYPOINT ["python", "hw_sim.py"]
CMD ["--scenario", "normal"]
