FROM alpine:3.23@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40
RUN apk upgrade --no-cache
COPY binary.sh /bin/binary.sh

RUN mkdir -p /salvage/meta /salvage/volume

CMD ["/bin/binary.sh"]
