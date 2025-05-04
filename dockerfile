# Stage 1: Compile the Go plugin
FROM golang:1.21-alpine AS builder
ENV CGO_ENABLED=1
WORKDIR /plugin

COPY go.mod go.sum ./
RUN go mod download
RUN apk add --no-cache build-base

COPY . .
RUN go build -buildmode=plugin -o firebase_app_check.so .

# Stage 2: Build final Kong image with plugin
FROM kong/kong-gateway:3.4.3.18

USER root

# Create plugin directory and copy compiled .so
RUN mkdir -p /usr/local/lib/lua/5.1/kong/plugins/app-check
COPY --from=builder /plugin/firebase_app_check.so \
     /usr/local/lib/lua/5.1/kong/plugins/app-check/handler.so

# Restore Kong's entrypoint script from the base image
COPY --from=kong/kong-gateway:3.4.3.18 /docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# Enable your plugin alongside Kong’s bundled plugins
ENV KONG_PLUGINS=bundled,app-check

# Switch back to the non-root user and let the base image launch logic run
USER kong

# (No need to re-specify ENTRYPOINT or CMD; they’re inherited from the base image)