FROM golang:1.27.4-alpine AS build

# SQLite 编译进二进制，运行镜像不需要 Go 工具链或 C 编译器。
RUN apk add --no-cache build-base
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=1 go build -trimpath -tags sqlite_omit_load_extension \
    -ldflags '-s -w -linkmode external -extldflags "-static"' -o /out/ipad-dashboard .

FROM alpine:3.23
RUN apk add --no-cache ca-certificates \
    && addgroup -g 10001 dashboard \
    && adduser -D -H -u 10001 -G dashboard dashboard \
    && mkdir -p /dashboard /relay-data \
    && chown dashboard:dashboard /relay-data

ENV DISPLAY_MODE=pairing \
    DISPLAY_BIND=0.0.0.0 \
    RELAY_DATA_DIR=/relay-data

WORKDIR /dashboard
COPY --from=build /out/ipad-dashboard ./ipad-dashboard
COPY web ./web
COPY LICENSE THIRD_PARTY_NOTICES.md ./
COPY licenses/go-sqlite3.txt ./licenses/go-sqlite3.txt
COPY licenses/Go-LICENSE.txt ./licenses/Go-LICENSE.txt
USER 10001:10001
VOLUME ["/relay-data"]
EXPOSE 18086
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["/dashboard/ipad-dashboard", "--healthcheck"]
CMD ["/dashboard/ipad-dashboard"]
