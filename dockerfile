# ─── Stage 1: Build a fully static Go plugin ───────────────────────
FROM golang:1.21-alpine AS builder

# produce a self-contained, static binary
ENV CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=amd64

WORKDIR /plugin
COPY go.mod go.sum ./
RUN apk add --no-cache git \
 && go mod download

COPY . .
# Build with debug flags
RUN go build -o firebase-app-check .



# ─── Stage 2: Runtime on Kong (Debian) ────────────────────────────
FROM kong:3.4.2

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates procps strace \
 && rm -rf /var/lib/apt/lists/*

# copy & mark your pluginserver
COPY --from=builder /plugin/firebase-app-check /usr/local/bin/firebase-app-check
RUN chmod +x /usr/local/bin/firebase-app-check \
 && mkdir -p /usr/local/kong \
 && chmod 777 /usr/local/kong \
 && chown -R kong:kong /usr/local/kong

# Add a debugging wrapper script
RUN echo '#!/bin/bash\n\
set -e\n\
\n\
# Remove any stale socket\n\
rm -f /usr/local/kong/firebase-app-check.socket\n\
\n\
# Log environment variables for debugging\n\
echo "Starting plugin server with environment:"\n\
env | grep -E "KONG|PLUGIN" > /tmp/plugin-env.log\n\
\n\
# Run the plugin with debug output to a log file\n\
/usr/local/bin/firebase-app-check "$@" 2>&1 | tee /tmp/plugin-output.log\n\
' > /usr/local/bin/firebase-app-check-wrapper \
 && chmod +x /usr/local/bin/firebase-app-check-wrapper

# ─── Tell Kong exactly how to load your Go plugin ────────────────
# (1) where to find your binary
ENV KONG_GO_PLUGINS_DIR=/usr/local/bin
ENV KONG_LOG_LEVEL=debug

# (2) enable both the built-ins and your new plugin
ENV KONG_PLUGINS=bundled,firebase-app-check

# (3) register an external pluginserver named exactly "firebase-app-check"
ENV KONG_PLUGINSERVER_NAMES=firebase-app-check

# (4) how Kong "starts" that server (it will call this with no args,
#     and the Go PDK's StartServer must block and listen)
ENV KONG_PLUGINSERVER_FIREBASE_APP_CHECK_START_CMD=/usr/local/bin/firebase-app-check-wrapper
ENV KONG_PLUGINSERVER_FIREBASE_APP_CHECK_SOCKET=/usr/local/kong/firebase-app-check.socket

# (5) how Kong "queries" that server for its schema (it must print JSON and exit 0)
ENV KONG_PLUGINSERVER_FIREBASE_APP_CHECK_QUERY_CMD=/usr/local/bin/firebase-app-check\ -dump

# Add timeout and retry settings for plugin server
ENV KONG_PLUGINSERVER_CONNECT_TIMEOUT=60000
ENV KONG_PLUGINSERVER_SOCKET_TIMEOUT=60000

# Create custom entrypoint wrapper
RUN echo '#!/bin/bash\n\
set -e\n\
\n\
# Make sure directory exists and has correct permissions\n\
mkdir -p /usr/local/kong\n\
chmod 777 /usr/local/kong\n\
chown -R kong:kong /usr/local/kong\n\
\n\
# Test the plugin independently\n\
echo "Testing plugin in standalone mode..."\n\
/usr/local/bin/firebase-app-check -dump > /tmp/plugin-schema.json 2>&1 || echo "Schema dump failed: $?"\n\
cat /tmp/plugin-schema.json\n\
\n\
# Add a pre-start hook to create and check the socket\n\
(sleep 5 && echo "Checking for socket file..." && ls -la /usr/local/kong/ > /tmp/socket-check.log 2>&1) &\n\
\n\
# Start Kong\n\
exec /docker-entrypoint.sh "$@"\n\
' > /usr/local/bin/entrypoint-wrapper.sh \
 && chmod +x /usr/local/bin/entrypoint-wrapper.sh

# switch back to the unprivileged user
USER kong

# Add volume for persistent logs
VOLUME /tmp

ENTRYPOINT ["/usr/local/bin/entrypoint-wrapper.sh"]
CMD ["kong", "docker-start"]

EXPOSE 8000 8443 8001 8444
HEALTHCHECK --interval=10s --timeout=10s --retries=5 CMD kong health
STOPSIGNAL SIGQUIT