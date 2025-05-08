# ─── Stage 1: Build the Go Plugin ─────────────────────────────────────
FROM golang:1.21-alpine AS builder

# Install build tools
RUN apk add --no-cache build-base git

# Set environment variables for CGO
ENV CGO_ENABLED=1 \
    GOOS=linux \
    GOARCH=amd64

WORKDIR /plugin

# Copy go.mod and go.sum files
COPY go.mod go.sum ./
RUN go mod download

# Copy the rest of the plugin source code
COPY . .

# Build the plugin as a shared object (.so) file
RUN go build -buildmode=plugin -o firebase_app_check.so main.go

# ─── Stage 2: Prepare the Kong Image ──────────────────────────────────
FROM kong:3.4.2

USER root

# Create directory for Go plugins
RUN mkdir -p /usr/local/kong/go-plugins

# Copy the compiled plugin into the Kong image
COPY --from=builder /plugin/firebase_app_check.so /usr/local/kong/go-plugins/

# Set environment variables to configure Kong
ENV KONG_GO_PLUGINS_DIR=/usr/local/kong/go-plugins
ENV KONG_PLUGINS=bundled,firebase_app_check

# Switch back to the non-root user
USER kong

# Expose necessary ports
EXPOSE 8000 8443 8001 8444

# Healthcheck and default command
HEALTHCHECK --interval=10s --timeout=10s --retries=5 CMD kong health
CMD ["kong", "docker-start"]