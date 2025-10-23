#!/bin/bash
# deploy.sh
# Automated Deployment Script for Dockerized Application on a Remote Server

# --- 1. Script Setup and Logging ---
set -e
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a $LOG_FILE) 2>&1

# --- Configuration Variables ---
REMOTE_PROJECT_DIR="/opt/devops_app"
LOCAL_PROJECT_DIR="./cloned_repo"
CONTAINER_NAME="hng_devops_container"
APP_INTERNAL_PORT=8080

# --- Utility Functions for Error Management and Input (FIXED PROMPTS) ---

log() {
    echo -e "\n$(date '+%Y-%m-%d %H:%M:%S') - [INFO] $1"
}

handle_error() {
    echo -e "\n$(date '+%Y-%m-%d %H:%M:%S') - [FATAL] $1" >&2
    echo "Deployment failed. Check $LOG_FILE for details." >&2
    rm -rf "$LOCAL_PROJECT_DIR" 2>/dev/null || true
    exit 1
}

# General prompt function
prompt_required() {
    local prompt_msg=$1
    local var_name=$2
    local input_value
    read -p "$prompt_msg" -r input_value
    if [ -z "$input_value" ]; then
        handle_error "$prompt_msg is required. Input cannot be empty."
    fi
    # Use 'declare' to assign value to the variable name passed by reference
    declare -g "$var_name=$input_value"
}

# Sensitive prompt function (for PAT)
prompt_sensitive() {
    local prompt_msg=$1
    local var_name=$2
    local input_value
    read -sp "$prompt_msg" -r input_value
    echo # Newline after hidden input
    if [ -z "$input_value" ]; then
        handle_error "$prompt_msg is required. Input cannot be empty."
    fi
    # Use 'declare' to assign value to the variable name passed by reference
    declare -g "$var_name=$input_value"
}

# --- 2. Parameter Collection and Validation ---
log "--- Stage 1: Collecting Required Deployment Parameters ---"

# Requirement: Input Prompts
prompt_required "Enter Git Repository URL (e.g., https://github.com/user/repo.git): " GIT_REPO_URL
prompt_sensitive "Enter Git Personal Access Token (PAT - Input hidden): " GIT_PAT
prompt_required "Enter Remote Server SSH Username (e.g., ubuntu, ec2-user): " SSH_USER
prompt_required "Enter Remote Server IP Address: " SSH_IP
prompt_required "Enter Path to SSH Private Key (e.g., /c/Users/emman/.ssh/hng-devops-key.pem): " SSH_KEY_PATH

# Branch name (optional; defaults to main)
read -p "Enter branch name (Default: main): " APP_BRANCH
APP_BRANCH=${APP_BRANCH:-main}
log "Using branch: $APP_BRANCH"
log "Application Internal Port is fixed at: $APP_INTERNAL_PORT"

# Requirement: Validation
if [ ! -f "$SSH_KEY_PATH" ]; then
    handle_error "SSH Key not found at $SSH_KEY_PATH. Please verify the path."
fi
log "Parameters collected and validated successfully."

# --- 3. Local Repository Management (Directory Subshell Fix Implemented) ---
log "--- Stage 2: Cloning/Pulling Repository ---"

# Requirement: Authenticate Clone - THE PAT MUST BE HERE!
# Insert the PAT into the Git URL for authenticated cloning.
AUTH_REPO_URL=$(echo "$GIT_REPO_URL" | sed "s|://|://x-oauth-basic:$GIT_PAT@|")

# Clean up remote log files that were in the cloned directory (from the last failed run)
# We exclude files that are definitely needed for the app.
log "Cleaning up log files from previous failed runs..."
(cd "$LOCAL_PROJECT_DIR" 2>/dev/null && rm -f *.log deploy*.sh) || true

# CRITICAL FIX: Use subshells '(...)' for 'cd' to prevent changing the main script's directory.
if [ -d "$LOCAL_PROJECT_DIR" ]; then
    log "Repository directory exists. Pulling latest code..."
    (cd "$LOCAL_PROJECT_DIR" && git pull) || handle_error "Failed to pull latest code. Check PAT or URL."
else
    log "Cloning repository $GIT_REPO_URL..."
    git clone "$AUTH_REPO_URL" "$LOCAL_PROJECT_DIR" || handle_error "Failed to clone repository. Check PAT or URL."
fi

# Checkout the specified branch (using a subshell for safety)
(cd "$LOCAL_PROJECT_DIR" && git checkout "$APP_BRANCH") || handle_error "Failed to checkout branch $APP_BRANCH. Does it exist?"

# Requirement: Validate Docker recipe existence inside the cloned folder
if [ ! -f "$LOCAL_PROJECT_DIR/Dockerfile" ] && [ ! -f "$LOCAL_PROJECT_DIR/docker-compose.yml" ]; then
    handle_error "Neither Dockerfile nor docker-compose.yml found in $LOCAL_PROJECT_DIR. Cannot deploy."
fi

log "Repository synchronized and validated. Code is ready for transfer."

# --- 4. Remote Execution Wrapper and Connection Test ---

# Define the remote execution function. This abstracts the SSH command.
remote_exec() {
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SSH_IP" -o BatchMode=yes -o ServerAliveInterval=60 "$1"
}

log "--- Stage 3: Establishing Remote Connection and Checking Access ---"
remote_exec "echo 'SSH connection successful'" || handle_error "SSH connection failed. Check key, user, IP, and firewall."
log "SSH connectivity test passed."

# --- 5. Prepare the Remote Environment (Idempotent) ---
log "--- Stage 4: Preparing Remote Host (Installing Docker/Nginx) ---"

# Create target directory
remote_exec "sudo mkdir -p $REMOTE_PROJECT_DIR"

# FIX: Add chown to grant user ownership of the application directory
remote_exec "sudo chown -R $SSH_USER:$SSH_USER $REMOTE_PROJECT_DIR" || handle_error "Failed to set ownership on remote directory."

remote_exec "
    sudo apt update
    sudo apt install -y docker.io docker-compose nginx || handle_error 'Dependency installation failed.'
    
    sudo usermod -aG docker $SSH_USER || handle_error 'Failed to add user to docker group.'
    
    sudo systemctl enable --now docker nginx || handle_error 'Failed to enable/start services.'
" || handle_error "Remote dependency setup failed."

log "Remote environment prepared: Docker, Docker Compose, and NGINX are installed and running."

# --- 6. Deploy the Dockerized Application (SCP Path is now correct) ---
log "--- Stage 5: Deploying Application (Transfer and Build) ---"

# Requirement: Transfer Project Files
log "Transferring project files from local machine to $REMOTE_PROJECT_DIR..."
# The script is in the project root, so ./cloned_repo is the correct source path.
scp -i "$SSH_KEY_PATH" -r "$LOCAL_PROJECT_DIR/." "$SSH_USER@$SSH_IP:$REMOTE_PROJECT_DIR" || handle_error "SCP file transfer failed."

# Requirement: Build and Run Containers (Idempotent)
remote_exec "
    cd $REMOTE_PROJECT_DIR || handle_error 'Failed to enter remote project directory.'
    
    log 'Stopping old container if running...'
    docker stop $CONTAINER_NAME 2>/dev/null || true
    docker rm $CONTAINER_NAME 2>/dev/null || true
    
    log 'Building and running new container image...'
    docker build -t $CONTAINER_NAME . || handle_error 'Docker build failed. Check your Dockerfile.'
    
    docker run -d --name $CONTAINER_NAME -p $APP_INTERNAL_PORT:$APP_INTERNAL_PORT --restart unless-stopped $CONTAINER_NAME || handle_error 'Docker run failed.'
" || handle_error "Docker deployment failed."

log "Container built and launched successfully on internal port $APP_INTERNAL_PORT."

# --- 7. Configure Nginx as a Reverse Proxy ---
log "--- Stage 6: Configuring Nginx Reverse Proxy (Port 80 -> Port 8080) ---"

# Dynamically create Nginx config using Heredoc
read -r -d '' NGINX_CONF_CONTENT << EOL
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $SSH_IP;

    location / {
        proxy_pass http://localhost:$APP_INTERNAL_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOL

log "Overwriting /etc/nginx/sites-available/default with reverse proxy settings."
echo "$NGINX_CONF_CONTENT" | remote_exec "sudo tee /etc/nginx/sites-available/default > /dev/null" || handle_error "Failed to write Nginx config."

remote_exec "sudo ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default"

remote_exec "sudo nginx -t" || handle_error "Nginx configuration test failed. Check config syntax."
remote_exec "sudo systemctl reload nginx" || handle_error "Nginx reload failed. Check service status."

log "Nginx successfully configured and reloaded. Old configuration is replaced."

# --- 8. Final Deployment Validation ---
log "--- Stage 7: Final Validation ---"

remote_exec "docker ps --filter name=$CONTAINER_NAME --format '{{.Status}}' | grep 'Up'" || handle_error "Validation failed: Container is not running or healthy."

remote_exec "curl -s -o /dev/null -w '%{http_code}' http://localhost/ | grep 200" || handle_error "Validation failed: Nginx proxy check returned non-200 status. Check firewall and container port."

log "🎉 SUCCESS! Application is live and accessible on http://$SSH_IP 🎉"
log "The task is complete. Proceed to commit and submit via Slack."

# Clean up local cloned repo on successful exit
rm -rf "$LOCAL_PROJECT_DIR" 2>/dev/null || true
log "Local temporary directory cleaned up."

