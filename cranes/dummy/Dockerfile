FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b
RUN apk upgrade --no-cache
COPY binary.sh /bin/binary.sh

RUN mkdir -p /salvage/meta /salvage/volume

CMD ["/bin/binary.sh"]
