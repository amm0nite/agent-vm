# Runs the disposable Arch agent VM as a long-lived container.
# The VM image is built on first start into /data, not into this image.
# Unpinned on purpose: each CI build picks up current Debian and QEMU fixes.
FROM debian:trixie-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        cloud-image-utils \
        curl \
        ipxe-qemu \
        jq \
        openssh-client \
        qemu-system-x86 \
        qemu-utils \
        socat \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --uid 1000 vm \
    && install -d -o vm -g vm /data

COPY build-image.sh wipe-workspace.sh /opt/agent-vm/
COPY lib /opt/agent-vm/lib
COPY cloud-init /opt/agent-vm/cloud-init
COPY config /opt/agent-vm/config
COPY guest /opt/agent-vm/guest
COPY docker/entrypoint.sh /opt/agent-vm/docker/
COPY docker/healthcheck.sh /usr/local/bin/agent-vm-healthcheck

ENV ARCH_AGENT_IMAGE_DIR=/data/images \
    ARCH_AGENT_LOG_DIR=/data/logs

USER vm
VOLUME /data
EXPOSE 2222

# The first start builds the VM image, which takes several minutes.
HEALTHCHECK --interval=30s --timeout=15s --start-period=30m --start-interval=10s --retries=3 \
    CMD ["agent-vm-healthcheck"]

ENTRYPOINT ["/opt/agent-vm/docker/entrypoint.sh"]
CMD ["run"]
