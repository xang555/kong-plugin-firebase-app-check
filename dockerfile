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
RUN go build -o firebase-app-check .



# ─── Stage 2: Runtime on Kong (Debian) ────────────────────────────
FROM kong:3.4.2

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates procps strace vim \
 && rm -rf /var/lib/apt/lists/*

# copy & mark your pluginserver
COPY --from=builder /plugin/firebase-app-check /usr/local/bin/firebase-app-check
RUN chmod +x /usr/local/bin/firebase-app-check \
    && mkdir -p /tmp/kong-plugin-sockets

# Add a detailed wrapper script with debug logging
RUN echo '#!/bin/bash\n\
set -x\n\
\n\
# Remove stale socket\n\
rm -f /tmp/kong-plugin-sockets/firebase-app-check.socket\n\
\n\
# Enable core dumps\n\
ulimit -c unlimited\n\
\n\
# Log the environment\n\
env > /tmp/plugin-env.log\n\
\n\
# Show current working directory and permissions\n\
pwd > /tmp/plugin-cwd.log\n\
ls -la /tmp/kong-plugin-sockets >> /tmp/plugin-cwd.log\n\
\n\
# Try to run the binary with arguments, logging everything\n\
echo "Running: /usr/local/bin/firebase-app-check $*" > /tmp/plugin-run.log\n\
/usr/local/bin/firebase-app-check "$@" >> /tmp/plugin-run.log 2>&1\n\
exit_code=$?\n\
\n\
# Log the exit code\n\
echo "Exit code: $exit_code" >> /tmp/plugin-run.log\n\
\n\
# Return the original exit code\n\
exit $exit_code\n\
' > /usr/local/bin/firebase-app-check-debug \
 && chmod +x /usr/local/bin/firebase-app-check-debug

# Create a test script to verify plugin functionality
RUN echo '#!/bin/bash\n\
set -x\n\
\n\
# Test if plugin can be executed\n\
echo "Testing plugin executable..." > /tmp/plugin-test.log\n\
/usr/local/bin/firebase-app-check -dump >> /tmp/plugin-test.log 2>&1\n\
echo "Exit code: $?" >> /tmp/plugin-test.log\n\
\n\
# Try to get help output\n\
echo "\nTrying help flag..." >> /tmp/plugin-test.log\n\
/usr/local/bin/firebase-app-check -h >> /tmp/plugin-test.log 2>&1\n\
echo "Exit code: $?" >> /tmp/plugin-test.log\n\
\n\
# Try without arguments\n\
echo "\nTrying without arguments..." >> /tmp/plugin-test.log\n\
/usr/local/bin/firebase-app-check >> /tmp/plugin-test.log 2>&1\n\
echo "Exit code: $?" >> /tmp/plugin-test.log\n\
\n\
# Try with socket explicitly specified\n\
echo "\nTrying with socket path..." >> /tmp/plugin-test.log\n\
/usr/local/bin/firebase-app-check --socket-path=/tmp/kong-plugin-sockets/firebase-app-check.socket >> /tmp/plugin-test.log 2>&1\n\
echo "Exit code: $?" >> /tmp/plugin-test.log\n\
' > /usr/local/bin/test-plugin \
 && chmod +x /usr/local/bin/test-plugin

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
ENV KONG_PLUGINSERVER_FIREBASE_APP_CHECK_START_CMD=/usr/local/bin/firebase-app-check-debug
ENV KONG_PLUGINSERVER_FIREBASE_APP_CHECK_SOCKET=/tmp/kong-plugin-sockets/firebase-app-check.socket

# (5) how Kong "queries" that server for its schema (it must print JSON and exit 0)
ENV KONG_PLUGINSERVER_FIREBASE_APP_CHECK_QUERY_CMD=/usr/local/bin/firebase-app-check-debug\ -dump

# Create custom entrypoint wrapper
RUN echo '#!/bin/bash\n\
set -x\n\
\n\
# Run the plugin test first\n\
/usr/local/bin/test-plugin\n\
\n\
# Create the socket directory with wide permissions\n\
mkdir -p /tmp/kong-plugin-sockets\n\
chmod 777 /tmp/kong-plugin-sockets\n\
\n\
# Start Kong\n\
exec /docker-entrypoint.sh "$@"\n\
' > /usr/local/bin/entrypoint-wrapper.sh \
 && chmod +x /usr/local/bin/entrypoint-wrapper.sh

# switch back to the unprivileged user
USER kong

ENTRYPOINT ["/usr/local/bin/entrypoint-wrapper.sh"]
CMD ["kong", "docker-start"]

EXPOSE 8000 8443 8001 8444
HEALTHCHECK --interval=10s --timeout=10s --retries=5 CMD kong health
STOPSIGNAL SIGQUIT