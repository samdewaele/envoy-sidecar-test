FROM golang:1.22-alpine AS builder
WORKDIR /src
COPY main.go .
RUN go mod init testapp && \
    CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o testapp .

FROM alpine:3.19
RUN apk add --no-cache ca-certificates curl
WORKDIR /app
COPY --from=builder /src/testapp .
USER 65534
ENTRYPOINT ["/app/testapp"]
