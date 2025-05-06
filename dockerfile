# ─── Stage 1: Build a pure-Go, static pluginserver ───────────────────
FROM golang:1.21 AS builder

ENV CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=amd64

WORKDIR /plugin

# grab dependencies
COPY go.mod go.sum ./
RUN apt-get update \
 && apt-get install -y --no-install-recommends git \
 && go mod download

COPY . .
RUN go build -o firebase-app-check .



# ─── Stage 2: Kong runtime (Alpine variant) ─────────────────────────
FROM kong:3.9.0

USER root

# copy & mark your binary
COPY --from=builder /plugin/firebase-app-check /usr/local/bin/firebase-app-check
RUN chmod +x /usr/local/bin/firebase-app-check

# make sure Kong’s prefix & socket dir exist and are owned by `kong`
RUN mkdir -p /usr/local/kong \
 && chown -R kong: /usr/local/kong

# explicitly tell Kong what its prefix is (where to write nginx.conf, .socket, etc.)
ENV KONG_PREFIX=/usr/local/kong

# 1) where to find Go plugin binaries
ENV KONG_GO_PLUGINS_DIR=/usr/local/bin

# 2) enable built-ins + yours
ENV KONG_PLUGINS=bundled,firebase-app-check

# 3) register an external server named exactly "firebase-app-check"
ENV KONG_PLUGINSERVER_NAMES=firebase-app-check

# 4) how Kong “starts” that server (no args—it must block and listen)
ENV KONG_PLUGINSERVER_FIREBASE_APP_CHECK_START_CMD=/usr/local/bin/firebase-app-check

# 5) how Kong “queries” that server for schema (must match your dump test)
ENV KONG_PLUGINSERVER_FIREBASE_APP_CHECK_QUERY_CMD=/usr/local/bin/firebase-app-check\ -dump

# back to unprivileged user
USER kong

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["kong", "docker-start"]

EXPOSE 8000 8443 8001 8444
HEALTHCHECK --interval=10s --timeout=10s --retries=5 CMD kong health
STOPSIGNAL SIGQUIT