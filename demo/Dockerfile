# syntax=docker/dockerfile:1

FROM golang:1.27.1-bookworm AS builder

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY cmd ./cmd
COPY internal ./internal

RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /demo-service ./cmd/server

FROM gcr.io/distroless/static-debian13:nonroot

COPY --from=builder /demo-service /demo-service

# Numeric UID of the distroless "nonroot" user: kubelet can verify runAsNonRoot
# only against a numeric user.
USER 65532:65532
EXPOSE 8080

ENTRYPOINT ["/demo-service"]
