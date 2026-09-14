FROM alpine:3.23@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40

# renovate: datasource=github-releases depName=restic/restic
ARG RESTIC_VERSION=0.19.1
ARG TARGETARCH

RUN apk upgrade --no-cache && apk add --no-cache \
      bash \
      jq \
      ca-certificates \
      curl \
      openssh-client \
      bzip2 \
  && update-ca-certificates \
  && ARCH="${TARGETARCH:-amd64}" \
  && case "$ARCH" in \
      amd64|arm64) : ;; \
      *) echo "Unsupported TARGETARCH: $ARCH" >&2; exit 1 ;; \
     esac \
  && curl -fsSL -o /tmp/restic.bz2 "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_${ARCH}.bz2" \
  && bunzip2 /tmp/restic.bz2 \
  && chmod +x /tmp/restic \
  && mv /tmp/restic /usr/local/bin/restic \
  && mkdir -p /salvage/meta /salvage/volume

COPY binary.sh /bin/binary.sh
RUN chmod +x /bin/binary.sh

ENTRYPOINT ["/bin/binary.sh"]
