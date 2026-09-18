FROM golang:1.26-alpine@sha256:ce864e7223ac17b1775e6fd0b4c0db580c2eb50e7953a427916379e4b92a1628 AS builder
# renovate: datasource=github-releases depName=restic/restic
ARG RESTIC_VERSION=0.19.1
WORKDIR /build
RUN wget -qO /tmp/source.tar.gz "https://codeload.github.com/restic/restic/tar.gz/refs/tags/v${RESTIC_VERSION}" \
    && tar -xzf /tmp/source.tar.gz --strip-components=1
COPY build-deps/go.mod build-deps/go.sum ./
RUN go mod download
RUN CGO_ENABLED=0 go build -mod=readonly -trimpath -ldflags="-s -w -X main.version=${RESTIC_VERSION}" -o /restic ./cmd/restic

FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
RUN apk upgrade --no-cache && apk add --no-cache bash jq ca-certificates curl openssh-client \
    && update-ca-certificates && mkdir -p /salvage/meta /salvage/volume
COPY --from=builder /restic /usr/local/bin/restic
COPY binary.sh /bin/binary.sh
RUN chmod +x /bin/binary.sh
ENTRYPOINT ["/bin/binary.sh"]
