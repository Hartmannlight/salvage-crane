FROM alpine@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b
COPY binary.sh /bin/binary.sh

RUN mkdir -p /salvage/meta /salvage/volume

RUN apk add --no-cache bash \
	borgbackup \
	openssh \
	&& mkdir -m 700 /root/.ssh

ENTRYPOINT ["/bin/bash"]
CMD ["/bin/binary.sh"]
