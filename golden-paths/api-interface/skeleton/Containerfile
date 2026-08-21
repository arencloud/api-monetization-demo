FROM registry.access.redhat.com/ubi9/go-toolset:1.26.5 AS builder
WORKDIR /opt/app-root/src
COPY go.mod ./
COPY main.go ./
COPY internal/ internal/
COPY openapi/ openapi/
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /tmp/api .

FROM registry.access.redhat.com/ubi9-micro:9.7
WORKDIR /opt/app-root/src
COPY --from=builder /tmp/api /usr/local/bin/api
USER 1001
EXPOSE 8080 8082
ENTRYPOINT ["/usr/local/bin/api"]
