#!/bin/bash
# full_deployment.sh
# Complete, unified script for automated deployment, including the Nginx port fix.

# --- 1. Script Setup and Logging ---
set -e

# Define log file name and redirect output/errors to log file AND console.
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a $LOG_FILE) 2>&1

# --- Configuration Variables ---
REMOTE_PROJECT_DIR="/opt/devops_app" # Standard location for applications
LOCAL_PROJECT_DIR="./temp_deployment_context" # Local temp folder for build context
CONTAINER_NAME="devops-container"
APP_INTERNAL_PORT=8080               # Fixed internal port to resolve "Address in use" error

# --- Utility Functions for Error Management and Input ---

log() {
    # Custom logger
    echo -e "\n$(date '+%Y-%m-%d %H:%M:%S') - [INFO] $1"
}

handle_error() {
    # Requirement: Report error, exit, and clean up.
    echo -e "\n$(date '+%Y-%m-%d %H:%M:%S') - [FATAL] $1" >&2
    echo "Deployment failed. Check $LOG_FILE for details." >&2
    # Cleanup on failure
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
    declare -g "$var_name=$input_value" # Global assignment
}

# Define the remote execution function.
remote_exec() {
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SSH_IP" -o BatchMode=yes -o ServerAliveInterval=60 "$1"
}

# --- 2. Parameter Collection and Validation ---
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

if [ ! -f "$SSH_KEY_PATH" ]; then
    handle_error "SSH Key not found at $SSH_KEY_PATH. Please verify the path."
fi
log "Parameters collected and validated successfully."


# --- 3. Local Repository Management & Nginx Fix Integration ---
log "--- Stage 2: Creating Local Build Context & Applying Fixes ---"

# Requirement: Authenticate Clone
# Insert the PAT into the Git URL for authenticated cloning.
AUTH_REPO_URL=$(echo "$GIT_REPO_URL" | sed "s|://|://x-oauth-basic:$GIT_PAT@|")

# Cleanup previous temp folder and create new one
log "Cleaning up old context and creating new temporary directory: $LOCAL_PROJECT_DIR"
rm -rf "$LOCAL_PROJECT_DIR" 2>/dev/null || true
mkdir -p "$LOCAL_PROJECT_DIR" || handle_error "Failed to create local deployment context directory."

# Clone/Pull into a dedicated 'app' sub-directory within the context folder
APP_SOURCE_DIR="$LOCAL_PROJECT_DIR/app"

if [ -d "$APP_SOURCE_DIR" ]; then
    log "Application source directory exists. Pulling latest code..."
    # Use subshell to cd and pull, keeping the script's main directory intact.
    (cd "$APP_SOURCE_DIR" && git pull) || handle_error "Failed to pull latest code. Check PAT or URL."
else
    log "Cloning repository $GIT_REPO_URL into $APP_SOURCE_DIR..."
    git clone "$AUTH_REPO_URL" "$APP_SOURCE_DIR" || handle_error "Failed to clone repository. Check PAT or URL."
fi

# Switch to the specified branch
(cd "$APP_SOURCE_DIR" && git checkout "$APP_BRANCH") || handle_error "Failed to checkout branch $APP_BRANCH. Does it exist?"

# NEW AUTOMATED FIX: Create the Nginx configuration file in the build context
log "--- Applying Automated Fix: Creating default.conf (Port 8080) ---"
cat << EOF > "$LOCAL_PROJECT_DIR/default.conf"
# Fixes the 'bind() to 0.0.0.0:80 failed (98: Address in use)' error inside the container
server {
    listen 8080;
    listen [::]:8080;
    server_name _;
    root /usr/share/nginx/html;
    include /etc/nginx/mime.types;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
log "✅ Created $LOCAL_PROJECT_DIR/default.conf to listen on internal port 8080."

# NEW AUTOMATED FIX: Create the Dockerfile in the build context
log "--- Applying Automated Fix: Creating corrected Dockerfile ---"
cat << EOF > "$LOCAL_PROJECT_DIR/Dockerfile"
# Use a lightweight Nginx image
FROM nginx:alpine

# Remove the original default configuration file
RUN rm /etc/nginx/conf.d/default.conf

# Copy the new configuration file that listens on 8080
COPY default.conf /etc/nginx/conf.d/default.conf

# Copy your application files from the cloned 'app' subfolder into Nginx serving directory
COPY ./app /usr/share/nginx/html

# Expose port 8080
EXPOSE 8080

# Start Nginx
CMD ["nginx", "-g", "daemon off;"]
EOF
log "✅ Created corrected $LOCAL_PROJECT_DIR/Dockerfile."

# Cleanup before transfer
log "Removing local .git directory from cloned repo to prepare for clean transfer..."
rm -rf "$APP_SOURCE_DIR/.git" || true

# Validation: Check for required Dockerfile in the context root
if [ ! -f "$LOCAL_PROJECT_DIR/Dockerfile" ]; then
    handle_error "Dockerfile not found in $LOCAL_PROJECT_DIR. Cannot deploy a Dockerized app."
fi

log "Local build context successfully created and fixed."


# --- 4. Remote Execution Wrapper and Connection Setup ---
log "--- Stage 3: Establishing Remote Connection and Checking Access ---"
remote_exec "echo 'SSH connection successful'" || handle_error "SSH connection failed. Check key, user, IP, and firewall."
log "SSH connectivity test passed."


# --- 5. Prepare the Remote Environment (Req 5) ---
log "--- Stage 4: Preparing Remote Host (Installing Dependencies) ---"

# Create target directory
remote_exec "sudo mkdir -p $REMOTE_PROJECT_DIR"

# Change ownership so the non-root SSH user can write files via SCP/rsync
remote_exec "sudo chown -R $SSH_USER:$SSH_USER $REMOTE_PROJECT_DIR" || handle_error "Failed to set ownership on remote directory."

remote_exec "
    # Update and install dependencies
    sudo apt update
    sudo apt install -y docker.io docker-compose nginx || handle_error 'Dependency installation failed.'
    
    # Add user to docker group
    sudo usermod -aG docker $SSH_USER || handle_error 'Failed to add user to docker group.'
    
    # Enable and start services.
    sudo systemctl enable --now docker nginx || handle_error 'Failed to enable/start services.'
    
    # Check installation
    docker --version || handle_error 'Docker failed to install.'
    nginx -v 2>&1 || handle_error 'Nginx failed to install.'
" || handle_error "Remote dependency setup failed."

log "Remote environment prepared: Docker, Docker Compose, and NGINX are installed and running."

# --- 6. Deploy the Dockerized Application ---
log "--- Stage 5: Deploying Application (Transfer and Build) ---"

# Requirement: Transfer Project Files
log "Transferring project files from local context ($LOCAL_PROJECT_DIR) to $REMOTE_PROJECT_DIR..."

# Transfer the contents of the local context
scp -i "$SSH_KEY_PATH" -r "$LOCAL_PROJECT_DIR/." "$SSH_USER@$SSH_IP:$REMOTE_PROJECT_DIR" || handle_error "SCP file transfer failed."

# Requirement: Build and Run Containers (Idempotent)
remote_exec "
    cd $REMOTE_PROJECT_DIR || handle_error 'Failed to enter remote project directory.'
    
    # Idempotency: Safely stop and remove old container instances.
    log 'Stopping old container if running...'
    docker stop $CONTAINER_NAME 2>/dev/null || true
    docker rm $CONTAINER_NAME 2>/dev/null || true
    
    # Build and run using the corrected Dockerfile.
    log 'Building and running new container image...'
    docker build -t $CONTAINER_NAME . || handle_error 'Docker build failed. Check your Dockerfile.'
    
    # Use --network host to allow Nginx on the host to connect easily to the container's 8080 port.
    docker run -d --name $CONTAINER_NAME --network host --restart unless-stopped $CONTAINER_NAME || handle_error 'Docker run failed.'
" || handle_error "Docker deployment failed."

log "Container built and launched successfully on internal port $APP_INTERNAL_PORT. The Nginx internal port conflict has been resolved."

# --- 7. Configure Nginx as a Reverse Proxy ---
log "--- Stage 6: Configuring Nginx Reverse Proxy (Port 80 -> Port 8080) ---"

# Configure Nginx to proxy traffic from 80 to the container's 8080.
remote_exec "
    # Overwrite Nginx config using a secure heredoc
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

# --- 8. Final Deployment Validation ---
log "--- Stage 7: Final Validation ---"

# 1. Check Container Health
remote_exec "
    if ! docker ps --filter name=$CONTAINER_NAME --format '{{.Status}}' | grep 'Up'; then
        echo 'CRITICAL: Container failed to start. Dumping logs for diagnosis:'
        docker logs $CONTAINER_NAME
        exit 1 # Fails the remote command, triggering the local handle_error
    fi
" || handle_error "Validation failed: Container is not running or healthy. The fix may not have resolved a different internal issue. See logs for crash reason."

# 2. Check Nginx Proxy (curl test on localhost:80)
remote_exec "curl -s -o /dev/null -w '%{http_code}' http://localhost/ | grep 200" || handle_error "Validation failed: Nginx proxy check returned non-200 status. Check firewall and container port."

log "SUCCESS! Application is live and accessible on http://$SSH_IP 🎉"
log "The task is complete. Proceed to commit and submit via Slack."

# --- 9. Final Cleanup ---
rm -rf "$LOCAL_PROJECT_DIR" 2>/dev/null || true
log "Local temporary directory cleaned up."

