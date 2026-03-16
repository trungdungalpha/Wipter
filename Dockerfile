FROM docker.io/ubuntu:latest

# Install essential packages - bỏ TurboVNC/noVNC/nodejs/gnome-keyring, thêm xvfb
RUN apt-get -y update && apt-get -y --no-install-recommends --no-install-suggests install \
    wget tini xdotool gpg openssl ca-certificates \
    # Xvfb thay TurboVNC (nhẹ hơn ~60MB RAM/container)
    xvfb \
    # openbox vẫn cần cho wipter window manager
    openbox \
    # dos2unix for line ending conversion
    dos2unix \
    # Tools for wipter package download
    binutils \
    # curl và net-tools
    curl iputils-ping net-tools apt-transport-https libnspr4 libnss3 libxss1 libssl-dev && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Create /tmp/.X11-unix directory
RUN mkdir -p /tmp/.X11-unix && \
    chmod 1777 /tmp/.X11-unix

# Download the wipter package based on architecture
ARG TARGETARCH
RUN case "${TARGETARCH}" in \
      amd64) wget -q -O /tmp/wipter-app.tar.gz https://provider-assets.wipter.com/latest/linux/x64/wipter-app-x64.tar.gz ;; \
      arm64) wget -q -O /tmp/wipter-app.tar.gz https://provider-assets.wipter.com/latest/linux/arm64/wipter-app-arm64.tar.gz ;; \
      *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    mkdir -p /root/wipter && \
    tar -xzf /tmp/wipter-app.tar.gz -C /root/wipter --strip-components=1 && \
    rm /tmp/wipter-app.tar.gz

# Install wipter runtime dependencies
RUN apt-get -y update && \
    apt-get -y --fix-broken --no-install-recommends --no-install-suggests install && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Update CA certificates
RUN update-ca-certificates

# Copy the start script
COPY start.sh /root/

# Convert start.sh to Unix line endings and make it executable
RUN dos2unix /root/start.sh && \
    chmod +x /root/start.sh

# Use tini as the entrypoint to manage processes
ENTRYPOINT ["tini", "-s", "/root/start.sh"]
