#!/bin/bash
# deploy.sh
# Automated Deployment Script for Dockerized Application on a Remote Server

# --- 1. Script Setup and Logging (Req 9 & 10) ---
# Exit immediately if any command fails.
set -e

# Define log file name and redirect output/errors to log file AND console.
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a $LOG_FILE) 2>&1

# --- Configuration Variables ---
REMOTE_PROJECT_DIR="/opt/devops_app" # Standard location for applications
LOCAL_PROJECT_DIR="./cloned_repo"     # Local temp folder for code cloning
CONTAINER_NAME="devops-container"
APP_INTERNAL_PORT=8080               # Requirement: Application container listens on 8080

# --- Utility Functions for Error Management and Input (FIXED PROMPTS) ---

log() {
    # Custom logger
    echo -e "\n$(date '+%Y-%m-%d %H:%M:%S') - [INFO] $1"
}

handle_error() {
    # Requirement: Report error, exit, and clean up.
    echo -e "\n$(date '+%Y-%m-%d %H:%M:%S') - [FATAL] $1" >&2
    echo "Deployment failed. Check $LOG_FILE for details." >&2
    # Cleanup on failure (Req 10)
    rm -rf "$LOCAL_PROJECT_DIR" 2>/dev/null || true
    exit 1
}

# General prompt function (Uses declare -g for safe variable assignment)
prompt_required() {
    local prompt_msg=$1
    local var_name=$2
    local input_value
    read -p "$prompt_msg" -r input_value
    if [ -z "$input_value" ]; then
        handle_error "$prompt_msg is required. Input cannot be empty."
    fi
    declare -g "$var_name=$input_value" # Global assignment
}

# Sensitive prompt function (for PAT, input hidden)
prompt_sensitive() {
    local prompt_msg=$1
    local var_name=$2
    local input_value
    read -sp "$prompt_msg" -r input_value
    echo # Newline after hidden input
    if [ -z "$input_value" ]; then
        handle_error "$prompt_msg is required. Input cannot be empty."
    fi
    declare -g "$var_name=$input_value" # Global assignment (Fix for PAT bug)
}

# --- 2. Parameter Collection and Validation (Req 1) ---
log "--- Stage 1: Collecting Required Deployment Parameters ---"

prompt_required "Enter Git Repository URL (e.g., https://github.com/user/repo.git): " GIT_REPO_URL
prompt_sensitive "Enter Git Personal Access Token (PAT - Input hidden): " GIT_PAT
prompt_required "Enter Remote Server SSH Username (e.g., ubuntu): " SSH_USER
prompt_required "Enter Remote Server IP Address: " SSH_IP
prompt_required "Enter Path to SSH Private Key (e.g., /c/Users/user/.ssh/id_rsa.pem): " SSH_KEY_PATH

# Branch name (optional; defaults to main)
read -p "Enter deployment branch name (Default: main): " APP_BRANCH
APP_BRANCH=${APP_BRANCH:-main}

log "Using branch: $APP_BRANCH"
log "Application Internal Port is fixed at: $APP_INTERNAL_PORT"

# Requirement: Validation
if [ ! -f "$SSH_KEY_PATH" ]; then
    handle_error "SSH Key not found at $SSH_KEY_PATH. Please verify the path."
fi
log "Parameters collected and validated successfully."

# --- 3. Remote Execution Wrapper and Connection Setup (Req 4) ---

# Define the remote execution function. This abstracts the SSH command.
remote_exec() {
    # FIX: Added ServerAliveInterval=60 to send keep-alive packets and prevent connection timeouts (Bug Fix).
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SSH_IP" -o BatchMode=yes -o ServerAliveInterval=60 "$1"
}

log "--- Stage 3: Establishing Remote Connection and Checking Access ---"
# Perform connectivity check
remote_exec "echo 'SSH connection successful'" || handle_error "SSH connection failed. Check key, user, IP, and firewall."
log "SSH connectivity test passed."


# --- 4. Local Repository Management (Req 2 & 3) ---
log "--- Stage 2: Cloning/Pulling Repository ---"

# Requirement: Authenticate Clone
# Insert the PAT into the Git URL for authenticated cloning.
AUTH_REPO_URL=$(echo "$GIT_REPO_URL" | sed "s|://|://x-oauth-basic:$GIT_PAT@|")

# Clean up remote log files that were in the cloned directory (from the last failed run)
# We exclude files that are definitely needed for the app.
log "Cleaning up log files from previous failed runs..."
(cd "$LOCAL_PROJECT_DIR" 2>/dev/null && rm -f *.log deploy*.sh) || true

# CRITICAL FIX: Use subshells '(...)' for 'cd' to prevent changing the main script's directory.
if [ -d "$LOCAL_PROJECT_DIR" ]; then
    log "Repository directory exists. Pulling latest code..."
    # Use subshell to cd and pull, keeping the script's main directory intact (Bug Fix).
    (cd "$LOCAL_PROJECT_DIR" && git pull) || handle_error "Failed to pull latest code. Check PAT or URL."
else
    log "Cloning repository $GIT_REPO_URL..."
    git clone "$AUTH_REPO_URL" "$LOCAL_PROJECT_DIR" || handle_error "Failed to clone repository. Check PAT or URL."
fi

# Switch to the specified branch (using a subshell for safety)
(cd "$LOCAL_PROJECT_DIR" && git checkout "$APP_BRANCH") || handle_error "Failed to checkout branch $APP_BRANCH. Does it exist?"

# NEW FIX: Remove the local .git directory before transfer. This ensures SCP doesn't hit
# permission issues or waste time copying unnecessary Git history to the remote server.
log "Removing local .git directory from cloned repo to prepare for clean transfer..."
rm -rf "$LOCAL_PROJECT_DIR/.git" || true

# Requirement: Validate Docker recipe existence
if [ ! -f "$LOCAL_PROJECT_DIR/Dockerfile" ] && [ ! -f "$LOCAL_PROJECT_DIR/docker-compose.yml" ]; then
    handle_error "Neither Dockerfile nor docker-compose.yml found in $LOCAL_PROJECT_DIR. Cannot deploy a Dockerized app."
fi

log "Repository synchronized and validated. Code is ready for transfer."


# --- 5. Prepare the Remote Environment (Req 5) ---
log "--- Stage 4: Preparing Remote Host (Installing Dependencies) ---"

# Create target directory
remote_exec "sudo mkdir -p $REMOTE_PROJECT_DIR"

# FIX: Change ownership so the non-root SSH user can write files via SCP/rsync (Permission Bug Fix).
remote_exec "sudo chown -R $SSH_USER:$SSH_USER $REMOTE_PROJECT_DIR" || handle_error "Failed to set ownership on remote directory."

remote_exec "
    # Update and install dependencies (Req 5).
    sudo apt update
    # Using only Docker, Docker Compose, and Nginx.
    sudo apt install -y docker.io docker-compose nginx || handle_error 'Dependency installation failed.'
    
    # Add user to docker group (Req 5 - ensures deployment user can run docker commands).
    sudo usermod -aG docker $SSH_USER || handle_error 'Failed to add user to docker group.'
    
    # Enable and start services.
    sudo systemctl enable --now docker nginx || handle_error 'Failed to enable/start services.'
    
    # Check installation (Req 5)
    docker --version || handle_error 'Docker failed to install.'
    nginx -v 2>&1 || handle_error 'Nginx failed to install.'
" || handle_error "Remote dependency setup failed."

log "Remote environment prepared: Docker, Docker Compose, and NGINX are installed and running."

# --- 6. Deploy the Dockerized Application (Req 6 & 10) ---
log "--- Stage 5: Deploying Application (Transfer and Build) ---"

# Requirement: Transfer Project Files
log "Transferring project files from local machine to $REMOTE_PROJECT_DIR..."

# Using scp, which is safe because the local .git directory was deleted in Stage 2.
scp -i "$SSH_KEY_PATH" -r "$LOCAL_PROJECT_DIR/." "$SSH_USER@$SSH_IP:$REMOTE_PROJECT_DIR" || handle_error "SCP file transfer failed."

# Requirement: Build and Run Containers (Idempotent)
remote_exec "
    cd $REMOTE_PROJECT_DIR || handle_error 'Failed to enter remote project directory.'
    
    # Idempotency: Safely stop and remove old container instances (Req 10).
    log 'Stopping old container if running...'
    docker stop $CONTAINER_NAME 2>/dev/null || true
    docker rm $CONTAINER_NAME 2>/dev/null || true
    
    # Build and run using the Dockerfile.
    log 'Building and running new container image...'
    docker build -t $CONTAINER_NAME . || handle_error 'Docker build failed. Check your Dockerfile.'
    
    # CRITICAL FIX: Use --network host to ensure Nginx on the host can connect to the container (Bug Fix).
    # Removed: -p $APP_INTERNAL_PORT:$APP_INTERNAL_PORT
    docker run -d --name $CONTAINER_NAME --network host --restart unless-stopped $CONTAINER_NAME || handle_error 'Docker run failed.'
" || handle_error "Docker deployment failed."

log "Container built and launched successfully on internal port $APP_INTERNAL_PORT."

# --- 7. Configure Nginx as a Reverse Proxy (Req 7) ---
log "--- Stage 6: Configuring Nginx Reverse Proxy (Port 80 -> Port 8080) ---"

# FIX: Configuration logic placed directly inside a robust SSH block to avoid quoting failures.
remote_exec "
    # Overwrite Nginx config using a secure heredoc to pass the multi-line content to sudo tee
    # The 'EOF' must be quoted ('EOF') to prevent local variable expansion.
    sudo tee /etc/nginx/sites-available/default > /dev/null << 'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $SSH_IP;

    location / {
        # Proxy traffic to the Docker container, listening on port $APP_INTERNAL_PORT.
        proxy_pass http://localhost:$APP_INTERNAL_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
" || handle_error "Failed to write Nginx configuration remotely."


# Test config and reload Nginx
remote_exec "sudo nginx -t" || handle_error "Nginx configuration test failed. Check config syntax."
remote_exec "sudo systemctl reload nginx" || handle_error "Nginx reload failed. Check service status."

log "Nginx successfully configured and reloaded."

# --- 8. Final Deployment Validation (Req 8) ---
log "--- Stage 7: Final Validation ---"

# 1. Check Container Health
remote_exec "docker ps --filter name=$CONTAINER_NAME --format '{{.Status}}' | grep 'Up'" || handle_error "Validation failed: Container is not running or healthy."

# 2. Check Nginx Proxy (curl test on localhost:80)
remote_exec "curl -s -o /dev/null -w '%{http_code}' http://localhost/ | grep 200" || handle_error "Validation failed: Nginx proxy check returned non-200 status. Check firewall and container port."

log "🎉 SUCCESS! Application is live and accessible on http://$SSH_IP 🎉"
log "The task is complete. Proceed to commit and submit via Slack."

# --- 9. Final Cleanup (Req 10) ---
rm -rf "$LOCAL_PROJECT_DIR" 2>/dev/null || true
log "Local temporary directory cleaned up."

