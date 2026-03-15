FROM ghcr.io/openclaw/openclaw:latest
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends sudo ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL https://go.dev/dl/go1.24.1.linux-amd64.tar.gz | tar -C /usr/local -xz \
    && echo 'node ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
ENV PATH="/usr/local/go/bin:/home/node/go/bin:${PATH}"
USER node
