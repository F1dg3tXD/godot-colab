# syntax=docker/dockerfile:1
#
# Godot Collab relay server image.
#
# Build from the repository root:
#   docker build -f tools/relay_server/Dockerfile -t godot-collab-relay:4.7.2 .
#
# Run (UDP 45900 published):
#   docker run --rm -p 45900:45900/udp godot-collab-relay:4.7.2 --port 45900
#
# The image is self-contained: it installs a pinned, checksum-verified Godot
# 4.7.2 headless binary, copies the add-on, and generates the GDScript global
# class cache during the build so the relay can start with no editor present.

FROM debian:bookworm-slim

ARG GODOT_VERSION=4.7.2
ARG GODOT_SHA512=9aa00f7a605200940bce3027a567b782f49bd8e940dd06ae9e987bd65aee1b1467edd56ed84fcdcbdd44354bf613bdbb4e5d2913e925850368e150c59ed54c65

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl unzip libfontconfig1 \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    url="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip"; \
    curl -fsSL "$url" -o /tmp/godot.zip; \
    echo "${GODOT_SHA512}  /tmp/godot.zip" | sha512sum -c -; \
    unzip -q /tmp/godot.zip -d /opt/godot; \
    mv "/opt/godot/Godot_v${GODOT_VERSION}-stable_linux.x86_64" /usr/local/bin/godot; \
    chmod +x /usr/local/bin/godot; \
    rm -rf /tmp/godot.zip

WORKDIR /relay
COPY project.godot icon.png icon.png.import ./
COPY addons ./addons
COPY tools/relay_server ./tools/relay_server

# `class_name` types (CollabRelayServer, CollabLog, ...) are resolved from
# .godot/global_script_class_cache.cfg, which a fresh checkout does not contain.
# Generate it here so the container never needs an editor.
RUN godot --headless --import || true

ENV GODOT_SILENCE_ROOT_WARNING=1
EXPOSE 45900/udp

ENTRYPOINT ["godot", "--headless", "--script", "tools/relay_server/relay_server.gd", "--"]
CMD ["--port", "45900"]
