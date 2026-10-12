#!/bin/bash
set -e

ROLE="${1:-$ROLE}"
NODE_VERSION="26"
BRANCH_NAME="main"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIG_DIR="$(cd "$(dirname "$0")/../configs" && pwd)"

case "$ROLE" in
    frontend|backend)
        TARGET="$ROLE"
        ;;
    *)
        echo "[ERROR] Missing or invalid target role."
        echo "Usage: $0 {frontend|backend}"
        exit 1
        ;;
esac

install_shared_tools() {
    echo "[SETUP] Refreshing system repositories and installing base utilities..."
    sudo apt update && sudo apt upgrade -y
    sudo apt install -y sudo git curl build-essential ufw openssh-server

	echo "[SETUP] Enabling and starting OpenSSH service..."
    sudo systemctl enable --now ssh

    echo "[SETUP] Configuring firewall baseline (SSH)..."
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw allow 22/tcp
    sudo ufw --force enable
}

sync_repo() {
    echo "[GIT] Pulling latest updates from $BRANCH_NAME..."
    cd "$REPO_ROOT"
    sudo git config --system --add safe.directory "$REPO_ROOT"
    git fetch origin "$BRANCH_NAME"
    git reset --hard "origin/$BRANCH_NAME"
}

setup_frontend() {
    echo "[SETUP] Configuring firewall for Frontend (HTTP/HTTPS)..."
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp

    echo "[USERS] Creating service user nuxtapp with home directory..."
    if ! getent passwd nuxtapp >/dev/null 2>&1; then
        sudo useradd -m -s /usr/sbin/nologin nuxtapp
    fi

    echo "[SETUP] Installing Frontend dependencies (Caddy, Node.js ${NODE_VERSION}, pnpm)..."
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
    sudo apt update
    sudo apt-get install -y caddy

    curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | sudo -E bash -
    sudo apt-get install -y nodejs
    sudo npm install -g pnpm --allow-scripts=pnpm

    echo "[DEPLOY] Building Nuxt frontend in repository..."
    cd "$REPO_ROOT/frontend"
    export CI=true
    export NUXT_TELEMETRY_DISABLED=1
    pnpm install --frozen-lockfile </dev/null
    pnpm run build </dev/null

    echo "[DEPLOY] Copying build artifacts to /home/nuxtapp/app..."
    sudo rm -rf /home/nuxtapp/app
    sudo mkdir -p /home/nuxtapp/app
	# Nuxt needs only ".output" folder
    sudo cp -r "$REPO_ROOT/frontend/.output" /home/nuxtapp/app/
    sudo chown -R nuxtapp:nuxtapp /home/nuxtapp/app
    sudo chmod -R 750 /home/nuxtapp/app

    echo "[SETUP] Installing configs and service..."
    sudo mkdir -p /var/log/caddy /etc/caddy
    sudo cp "$CONFIG_DIR/Caddyfile" /etc/caddy/Caddyfile
    sudo cp "$CONFIG_DIR/frontend.service" /etc/systemd/system/frontend.service

    sudo systemctl daemon-reload
    sudo systemctl enable frontend.service

    echo "[DEPLOY] Restarting frontend.service..."
    sudo systemctl restart frontend.service
    sudo systemctl status frontend.service --no-pager
}

setup_backend() {
    echo "[SETUP] Configuring firewall for Backend (8080)..."
    sudo ufw allow 8080/tcp

    echo "[USERS] Creating service user gamebackend with home directory..."
    if ! getent passwd gamebackend >/dev/null 2>&1; then
        sudo useradd -m -s /usr/sbin/nologin gamebackend
    fi

    echo "[SETUP] Installing Backend dependencies (OpenJDK 25, PostgreSQL)..."
    sudo apt-get install -y openjdk-25-jdk postgresql postgresql-contrib

    echo "[DEPLOY] Compiling Kotlin backend via Gradle wrapper..."
    cd "$REPO_ROOT/backend"
    chmod +x gradlew
    ./gradlew bootJar --no-daemon

    echo "[DEPLOY] Copying JAR artifact to /home/gamebackend/app..."
    sudo rm -rf /home/gamebackend/app
    sudo mkdir -p /home/gamebackend/app
    sudo cp "$REPO_ROOT/backend/build/libs/"*.jar /home/gamebackend/app/app.jar
    sudo chown -R gamebackend:gamebackend /home/gamebackend/app
    sudo chmod -R 750 /home/gamebackend/app

    echo "[SETUP] Installing service..."
    sudo cp "$CONFIG_DIR/backend.service" /etc/systemd/system/backend.service

    sudo systemctl daemon-reload
    sudo systemctl enable backend.service

    echo "[DEPLOY] Restarting backend.service..."
    sudo systemctl restart backend.service
    sudo systemctl status backend.service --no-pager
}

# --- Execution Flow ---
echo "[START] Starting machine provisioning for role: $TARGET"
install_shared_tools
sync_repo

if [ "$TARGET" = "frontend" ]; then
    setup_frontend
elif [ "$TARGET" = "backend" ]; then
    setup_backend
fi

echo "[SUCCESS] Machine provisioning completed for $TARGET."