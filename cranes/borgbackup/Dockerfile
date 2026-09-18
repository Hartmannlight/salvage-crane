FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
RUN apk upgrade --no-cache
COPY binary.sh /bin/binary.sh

RUN mkdir -p /salvage/meta /salvage/volume

RUN apk add --no-cache bash \
	borgbackup \
	openssh \
	&& mkdir -m 700 /root/.ssh

ENTRYPOINT ["/bin/bash"]
CMD ["/bin/binary.sh"]
