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
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# copy & mark your pluginserver
COPY --from=builder /plugin/firebase-app-check /usr/local/bin/firebase-app-check
RUN chmod +x /usr/local/bin/firebase-app-check \
 && mkdir -p /usr/local/kong \
 && chown -R kong: /usr/local/kong

# ─── Tell Kong exactly how to load your Go plugin ────────────────
# (1) where to find your binary
ENV KONG_GO_PLUGINS_DIR=/usr/local/bin

# (2) enable both the built-ins and your new plugin
ENV KONG_PLUGINS=bundled,firebase-app-check

# (3) register an external pluginserver named exactly "firebase-app-check"
ENV KONG_PLUGINSERVER_NAMES=firebase-app-check

# (4) how Kong "starts" that server (it will call this with no args,
#     and the Go PDK's StartServer must block and listen)
ENV KONG_PLUGINSERVER_FIREBASE_APP_CHECK_START_CMD=/usr/local/bin/firebase-app-check

# (5) how Kong "queries" that server for its schema (it must print JSON and exit 0)
ENV KONG_PLUGINSERVER_FIREBASE_APP_CHECK_QUERY_CMD=/usr/local/bin/firebase-app-check\ -dump

# switch back to the unprivileged user
USER kong

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["kong", "docker-start"]

EXPOSE 8000 8443 8001 8444
HEALTHCHECK --interval=10s --timeout=10s --retries=5 CMD kong health
STOPSIGNAL SIGQUIT