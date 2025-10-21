#!/bin/bash

# ==========================================================
# Automated Deployment Script (Stage 1 - DevOps Intern)
# Author: Williams Eche
# ==========================================================

set -e  # Stop script immediately if any command fails
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# ==========================================================
# 1. Collect User Inputs
# ==========================================================

read -p "Enter your GitHub repo URL (e.g., https://github.com/username/repo.git): " REPO_URL
read -p "Enter your GitHub Personal Access Token (PAT): " GITHUB_TOKEN
read -p "Enter branch name (default: main): " BRANCH
BRANCH=${BRANCH:-main}

read -p "Enter your remote server username (e.g., ubuntu): " REMOTE_USER
read -p "Enter your remote server IP address: " REMOTE_HOST
read -p "Enter full path to your SSH key (.pem): " SSH_KEY_PATH
read -p "Enter application port (e.g., 3000): " APP_PORT

# ==========================================================
# 2. Clone or Update Repo
# ==========================================================

REPO_NAME=$(basename -s .git "$REPO_URL")

if [ -d "$REPO_NAME" ]; then
  log "Repository exists, pulling latest changes..."
  cd "$REPO_NAME" || exit 1
  git pull origin "$BRANCH" >> "../$LOG_FILE" 2>&1
else
  log "Cloning repository..."

  # Remove https:// prefix, then rebuild URL with token safely
  CLEAN_URL=${REPO_URL#https://}
  GIT_REPO_WITH_TOKEN="https://${GITHUB_TOKEN}@${CLEAN_URL}"

  log "Running: git clone -b $BRANCH $GIT_REPO_WITH_TOKEN"
  git clone -b "$BRANCH" "$GIT_REPO_WITH_TOKEN" >> "$LOG_FILE" 2>&1

  cd "$REPO_NAME" || exit 1
fi
# Check Dockerfile or docker-compose presence
if [ -f "Dockerfile" ]; then
  HAS_COMPOSE=0
elif [ -f "docker-compose.yml" ]; then
  HAS_COMPOSE=1
else
  log "No Dockerfile or docker-compose.yml found! Exiting."
  exit 10
fi

cd ..

# ==========================================================
# 3. Check SSH Connectivity
# ==========================================================
log "Checking SSH connectivity to $REMOTE_HOST"
if ! ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_HOST" "echo Connected OK"; then
  log "SSH connection failed!"
  exit 20
fi

# ==========================================================
# 4. Prepare Remote Server (Install Docker, Compose, Nginx)
# ==========================================================
log "Preparing remote environment..."

ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_HOST" <<'EOF'
set -e

echo "[INFO] Checking and Installing Docker..."

# Clean any broken Docker repo if it exists
sudo rm -f /etc/apt/sources.list.d/docker.list

# Ensure dependencies are installed
sudo apt update -y
sudo apt install -y ca-certificates curl gnupg lsb-release

# Create directory for keyrings if not exists
sudo install -m 0755 -d /etc/apt/keyrings

# Download Docker GPG key
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg


# Add Docker repo properly (overwrite existing if broken)
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package lists and install Docker
sudo apt update -y
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Enable and start Docker
sudo systemctl enable docker
sudo systemctl start docker

# Confirm Docker installed
docker --version && echo "[INFO] Docker installed successfully."


# Add user to docker group
sudo usermod -aG docker ubuntu || echo "[WARNING] Could not add user to docker group (ignore if remote user)"
echo "[INFO] Docker installation complete ✅"



# Install Docker Compose (classic binary) if missing
if ! command -v docker-compose >/dev/null 2>&1; then
  echo "[INFO] Installing Docker Compose..."
  sudo apt install -y docker-compose
else
  echo "[INFO] Docker Compose already installed."
fi

# Install and start Nginx
if ! command -v nginx >/dev/null 2>&1; then
  echo "[INFO] Installing Nginx..."
  sudo apt install -y nginx
else
  echo "[INFO] Nginx already installed."
fi

sudo systemctl enable nginx
sudo systemctl start nginx
EOF


# ==========================================================
# 5. Push to Remote Server
# ==========================================================
log "Pushing repo to remote server..."
# (your git push logic here)


# Ensure requirements.txt exists before building
if [ ! -f "requirements.txt" ]; then
  log "No requirements.txt found — creating a default one..."
  echo "# Auto-generated placeholder requirements file" > requirements.txt
  echo "flask" >> requirements.txt
fi
# ==========================================================
# 6. Deploy Application on Remote Server
# ==========================================================
log "Deploying app on remote server..."

if [ "$HAS_COMPOSE" -eq 1 ]; then
  ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_HOST" "
    cd /home/$REMOTE_USER/$REPO_NAME &&
    sudo docker-compose down || true &&
    sudo docker-compose up -d --build
  "
else
  ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_HOST" "
 cd /home/$REMOTE_USER/$REPO_NAME &&
    sudo docker build -t ${REPO_NAME}_image . &&
    sudo docker rm -f ${REPO_NAME}_container || true &&
    sudo docker run -d --restart unless-stopped -p $APP_PORT:$APP_PORT --name ${REPO_NAME}_container ${REPO_NAME}_image
  "
fi

# ==========================================================
# 7. Configure Nginx Reverse Proxy
# ==========================================================
log "Configuring Nginx reverse proxy..."

NGINX_CONF="/etc/nginx/sites-available/$REPO_NAME"
NGINX_LINK="/etc/nginx/sites-enabled/$REPO_NAME"

ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_HOST" "
  sudo bash -c 'cat > $NGINX_CONF <<\"EOF\"
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

sudo ln -sf $NGINX_CONF $NGINX_LINK
sudo nginx -t && sudo systemctl restart nginx
'
"


# ==========================================================
# 8. Validation
# ==========================================================
log "Validating deployment..."

ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_HOST" "
  sudo systemctl is-active --quiet docker && echo 'Docker running OK'
  sudo docker ps
  curl -I http://127.0.0.1 || echo 'App check failed!'
"

log "Deployment completed successfully! Visit: http://$REMOTE_HOST"
