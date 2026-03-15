FROM ghcr.io/openclaw/openclaw:latest
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends sudo \
    && rm -rf /var/lib/apt/lists/* \
    && echo 'node ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
USER node
