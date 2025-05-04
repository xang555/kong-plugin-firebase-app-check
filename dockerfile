# Stage 1: Build the Go plugin as a .so
FROM golang:1.21-alpine AS builder

ENV CGO_ENABLED=1

WORKDIR /plugin

# Copy module definition and download deps
COPY go.mod go.sum ./

RUN go mod download

# Copy source code
COPY . .

# Build the plugin
RUN go build -buildmode=plugin -o firebase_app_check.so .

# Stage 2: Create the Kong image with plugin
FROM kong/kong-gateway:3.4.3.18

# Copy the compiled plugin into Kong's plugin folder
USER root
RUN mkdir -p /usr/local/lib/lua/5.1/kong/plugins/app-check
COPY --from=builder /plugin/firebase_app_check.so \
     /usr/local/lib/lua/5.1/kong/plugins/app-check/handler.so

# Enable the plugin in Kong
ENV KONG_PLUGINS=bundled,app-check

# reset back the defaults
USER kong
ENTRYPOINT ["/docker-entrypoint.sh"]
EXPOSE 8000 8443 8001 8444
STOPSIGNAL SIGQUIT
HEALTHCHECK --interval=10s --timeout=10s --retries=10 CMD kong health
CMD ["kong", "docker-start"]