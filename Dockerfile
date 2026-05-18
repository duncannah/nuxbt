# syntax=docker/dockerfile:1

ARG ALPINE_VERSION=3.22
ARG IMAGE_PLATFORM=linux/amd64

FROM --platform=${IMAGE_PLATFORM} node:24-alpine AS frontend

WORKDIR /src/nuxbt/web/client
COPY nuxbt/web/client/package*.json ./
RUN npm ci

COPY nuxbt/web/client ./
RUN npm run build

FROM --platform=${IMAGE_PLATFORM} alpine:${ALPINE_VERSION} AS wheel

RUN apk add --no-cache python3 py3-pip

WORKDIR /src
COPY pyproject.toml README.md LICENSE MANIFEST.in ./
COPY nuxbt ./nuxbt
COPY --from=frontend /src/nuxbt/web/templates ./nuxbt/web/templates
COPY --from=frontend /src/nuxbt/web/static/dist ./nuxbt/web/static/dist

RUN python3 -m venv /tmp/build-venv \
    && /tmp/build-venv/bin/pip install --no-cache-dir --upgrade pip build \
    && /tmp/build-venv/bin/python -m build --wheel --outdir /dist

FROM --platform=${IMAGE_PLATFORM} alpine:${ALPINE_VERSION}

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH=/opt/venv/bin:$PATH

# BlueZ is required at runtime. bluez-deprecated provides sdptool,
# hcitool, and hciconfig, which NUXBT still calls for SDP and adapter setup.
RUN apk add --no-cache \
        python3 \
        py3-pip \
        bluez \
        bluez-deprecated \
        dbus \
        libcap \
        sudo \
        py3-cairo \
        py3-cryptography \
        py3-dbus \
        py3-evdev \
        py3-gobject3 \
        py3-psutil \
    && mkdir -p /usr/local/sbin \
    && ln -sf /usr/lib/bluetooth/bluetoothd /usr/local/sbin/bluetoothd \
    && python3 -m venv --system-site-packages /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --upgrade pip

RUN mkdir -p /usr/local/lib/systemd/system /run/systemd/system/bluetooth.service.d \
    && printf '%s\n' \
        '[Service]' \
        'ExecStart=/usr/lib/bluetooth/bluetoothd' \
        > /usr/local/lib/systemd/system/bluetooth.service \
    && printf '%s\n' \
        '[Service]' \
        'ExecStart=' \
        'ExecStart=/usr/lib/bluetooth/bluetoothd --compat --noplugin=*' \
        > /run/systemd/system/bluetooth.service.d/nuxbt.conf \
    && cat > /usr/local/sbin/setcap <<'SH' \
    && chmod +x /usr/local/sbin/setcap \
    && ln -sf /usr/local/sbin/setcap /usr/local/bin/setcap \
    && cat > /usr/local/bin/systemctl <<'SH' \
    && chmod +x /usr/local/bin/systemctl \
    && cat > /usr/local/bin/nuxbt-container-shell <<'SH' \
    && chmod +x /usr/local/bin/nuxbt-container-shell
#!/bin/sh
# In containers, raw Bluetooth permissions come from Docker capabilities
# such as NET_ADMIN/NET_RAW or --privileged. Mutating the Python binary's file
# capabilities is unnecessary and can make it unexecutable in some runtimes.
exit 0
SH
#!/bin/sh
set -eu

service_name="${3:-${2:-}}"

start_dbus() {
    mkdir -p /run/dbus
    dbus-uuidgen --ensure=/etc/machine-id
    if [ ! -S /run/dbus/system_bus_socket ]; then
        rm -f /run/dbus/pid
        dbus-daemon --system --fork
    fi
}

start_bluetooth() {
    start_dbus
    if [ -f /run/bluetoothd.pid ] && kill -0 "$(cat /run/bluetoothd.pid)" 2>/dev/null; then
        return 0
    fi

    mkdir -p /var/run
    /usr/lib/bluetooth/bluetoothd --compat --noplugin='*' -n >/var/log/bluetoothd.log 2>&1 &
    echo "$!" > /run/bluetoothd.pid
}

stop_bluetooth() {
    if [ -f /run/bluetoothd.pid ]; then
        kill "$(cat /run/bluetoothd.pid)" 2>/dev/null || true
        rm -f /run/bluetoothd.pid
    fi
    pkill bluetoothd 2>/dev/null || true
}

case "${1:-}" in
    show)
        if [ "${2:-}" = "-p" ] && [ "${3:-}" = "FragmentPath" ] && [ "${4:-}" = "bluetooth.service" ]; then
            echo "FragmentPath=/usr/local/lib/systemd/system/bluetooth.service"
            exit 0
        fi
        ;;
    daemon-reload)
        exit 0
        ;;
    start|restart)
        if [ "$service_name" = "bluetooth" ] || [ "$service_name" = "bluetooth.service" ]; then
            stop_bluetooth
            start_bluetooth
            exit 0
        fi
        ;;
    stop)
        if [ "$service_name" = "bluetooth" ] || [ "$service_name" = "bluetooth.service" ]; then
            stop_bluetooth
            exit 0
        fi
        ;;
esac

echo "systemctl compatibility shim only supports bluetooth.service in this container" >&2
exit 1
SH
#!/bin/sh
set -eu

mkdir -p /run/systemd/system/bluetooth.service.d
if [ ! -f /run/systemd/system/bluetooth.service.d/nuxbt.conf ]; then
    printf '%s\n' \
        '[Service]' \
        'ExecStart=' \
        'ExecStart=/usr/lib/bluetooth/bluetoothd --compat --noplugin=*' \
        > /run/systemd/system/bluetooth.service.d/nuxbt.conf
fi

systemctl restart bluetooth.service

if [ "$#" -eq 0 ]; then
    exec /bin/ash
fi

exec "$@"
SH

COPY --from=wheel /dist/*.whl /tmp/
COPY pyproject.toml /tmp/pyproject.toml

# Intentionally omit PyQt6 to keep this image headless and small. The CLI,
# webapp, TUI, macro runner, and Bluetooth controller paths are included.
RUN python - <<'PY' > /tmp/requirements.txt \
    && pip install --no-cache-dir -r /tmp/requirements.txt \
    && pip install --no-cache-dir --no-deps /tmp/*.whl \
    && ln -sf /opt/venv/bin/nuxbt /usr/local/bin/nuxbt \
    && rm -f /tmp/*.whl /tmp/pyproject.toml /tmp/requirements.txt
import tomllib

skip = {
    "cryptography",  # provided by apk
    "dbus-python",  # provided by apk
    "psutil",       # provided by apk
    "pygobject",    # provided by apk
    "pyqt6",        # omitted to keep this image headless and small
    "python",
}


def caret_to_range(version):
    parts = [int(part) for part in version.split(".")]
    while len(parts) < 3:
        parts.append(0)

    major, minor, patch = parts[:3]
    if major > 0:
        upper = f"{major + 1}.0.0"
    elif minor > 0:
        upper = f"0.{minor + 1}.0"
    else:
        upper = f"0.0.{patch + 1}"

    return f">={version},<{upper}"


def pep508_requirement(name, spec):
    if isinstance(spec, dict):
        spec = spec.get("version", "")

    if not spec or spec == "*":
        return name
    if spec.startswith("^"):
        return f"{name}{caret_to_range(spec[1:])}"
    if spec.startswith((">", "<", "=", "!", "~")):
        return f"{name}{spec}"

    return f"{name}=={spec}"


with open("/tmp/pyproject.toml", "rb") as file:
    dependencies = tomllib.load(file)["tool"]["poetry"]["dependencies"]

for name, spec in dependencies.items():
    if name.lower().replace("_", "-") not in skip:
        print(pep508_requirement(name, spec))
PY

# Bluetooth access is managed inside the container. Run on Linux with enough
# privileges for the container's bluetoothd to control the adapter. If the
# host is also running bluetoothd for the same adapter, stop it first.
EXPOSE 8000

CMD ["/usr/local/bin/nuxbt-container-shell"]
