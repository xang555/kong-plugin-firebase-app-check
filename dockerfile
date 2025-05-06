# ─── Stage 1: Build a fully static Go plugin ───────────────────────
FROM golang:1.21 AS builder

# disable cgo so we get a pure-Go, statically linked binary
ENV CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=amd64

WORKDIR /plugin

# grab dependencies
COPY go.mod go.sum ./
RUN apt-get update \
 && apt-get install -y --no-install-recommends git \
 && go mod download

# compile your plugin; name output exactly to your slug
COPY . .
RUN go build -o firebase-app-check .



# ─── Stage 2: Runtime on Kong:Alpine ───────────────────────────────
FROM kong:3.9.0

USER root

# install root CAs in case your plugin does any HTTPS
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# copy in your static binary
COPY --from=builder /plugin/firebase-app-check /usr/local/bin/firebase-app-check
RUN chmod +x /usr/local/bin/firebase-app-check

# make the socket dir writable by kong
RUN mkdir -p /usr/local/kong \
 && chown kong: /usr/local/kong

# Correct the query command to use -dump without additional quotes
ENV KONG_GO_PLUGINS_DIR=/usr/local/bin \
    KONG_PLUGINS=bundled,firebase-app-check \
    KONG_PLUGINSERVER_NAMES=firebase-app-check \
    KONG_PLUGINSERVER_FIREBASE_APP_CHECK_START_CMD=/usr/local/bin/firebase-app-check \
    KONG_PLUGINSERVER_FIREBASE_APP_CHECK_QUERY_CMD="/usr/local/bin/firebase-app-check -dump"

# drop back to the kong user
USER kong

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["kong", "docker-start"]

EXPOSE 8000 8443 8001 8444
STOPSIGNAL SIGQUIT
HEALTHCHECK --interval=10s --timeout=10s --retries=10 CMD kong health