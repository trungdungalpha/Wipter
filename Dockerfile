# Stage 1: Build the wipter package downloader
FROM --platform=$BUILDPLATFORM docker.io/ubuntu:latest AS wipter-desktop-package-builder

# Install tools to download and handle the wipter package
RUN apt-get -y update && apt-get -y --no-install-recommends --no-install-suggests install \
    binutils wget ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Download the wipter package based on target architecture
ARG TARGETARCH
RUN case "${TARGETARCH}" in \
      amd64) wget -q -O /tmp/wipter-app.tar.gz https://s3.us-west-2.amazonaws.com/provider-assets.wipter.com/latest/linux/x64/wipter-app-x64.tar.gz ;; \
      arm64) wget -q -O /tmp/wipter-app.tar.gz https://s3.us-west-2.amazonaws.com/provider-assets.wipter.com/latest/linux/arm64/wipter-app-arm64.tar.gz ;; \
      *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac

# Stage 2: Final image
FROM docker.io/ubuntu:latest

# Install essential packages, including full D-Bus, X11, and keytar dependencies
RUN apt-get -y update && apt-get -y --no-install-recommends --no-install-suggests install \
    wget tini xdotool gpg openbox ca-certificates \
    python3-pip python3-venv \
    git \
    # D-Bus, GNOME Keyring, and keytar dependencies
    dbus dbus-x11 gnome-keyring libsecret-1-0 libsecret-1-dev \
    # Node.js and build tools for keytar
    nodejs npm build-essential && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Create /tmp/.X11-unix and /run/dbus directories
RUN mkdir -p /tmp/.X11-unix /run/dbus && \
    chmod 1777 /tmp/.X11-unix && \
    chmod 755 /run/dbus

# Create directories for keyring and cache
RUN mkdir -p /root/.local/share/keyrings /root/.cache

# Create a virtual environment and install Python dependencies
RUN python3 -m venv /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir websockify keyring

# Update CA certificates
RUN update-ca-certificates

# Copy noVNC files
RUN git clone https://github.com/novnc/noVNC.git /noVNC

# Expose the necessary ports
EXPOSE 5900 6080

# Install TurboVNC
RUN wget -q -O- https://packagecloud.io/dcommander/turbovnc/gpgkey | gpg --dearmor > /etc/apt/trusted.gpg.d/TurboVNC.gpg && \
    wget -q -O /etc/apt/sources.list.d/turbovnc.list https://raw.githubusercontent.com/TurboVNC/repo/main/TurboVNC.list && \
    apt-get -y update && apt-get -y install turbovnc libwebkit2gtk-4.1-0 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Copy and extract the wipter tarball
COPY --from=wipter-desktop-package-builder /tmp/wipter-app.tar.gz /tmp/wipter-app.tar.gz
RUN mkdir -p /root/wipter && \
    tar -xzf /tmp/wipter-app.tar.gz -C /root/wipter --strip-components=1 && \
    rm /tmp/wipter-app.tar.gz

# Install system dependencies for wipter and wipter.deb
RUN apt-get -y update && \
    apt-get -y install curl iputils-ping net-tools apt-transport-https libnspr4 libnss3 libxss1 libssl-dev && \
    apt-get -y --fix-broken --no-install-recommends --no-install-suggests install && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Copy the start script
COPY start.sh /root/

# Make start.sh executable
RUN chmod +x /root/start.sh

# Use tini as the entrypoint to manage processes
ENTRYPOINT ["tini", "-s", "/root/start.sh"]
