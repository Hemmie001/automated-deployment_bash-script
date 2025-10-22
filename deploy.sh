#!/usr/bin/env bash

set -euo pipefail  # Exit on error, undefined variable, or pipe failure

################################################################################
# GLOBAL VARIABLES
################################################################################

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="${SCRIPT_DIR}/deploy_$(date +%Y%m%d_%H%M%S).log"
readonly TEMP_DIR="/tmp/deploy_$$"
readonly APP_NAME="dockerized-app"

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# User input variables
GIT_REPO_URL=""
GIT_PAT=""
GIT_BRANCH="main"
SSH_USER=""
SSH_HOST=""
SSH_KEY_PATH=""
APP_PORT=""
CLEANUP_MODE=false

# Deployment variables
PROJECT_NAME=""
REMOTE_APP_DIR=""

#============================================================#
# UTILITY FUNCTIONS
#============================================================#

# Print colored messages
log_info() {
    local message="$1"
    echo -e "${BLUE}[INFO]${NC} $message" | tee -a "$LOG_FILE"
}

log_success() {
    local message="$1"
    echo -e "${GREEN}[SUCCESS]${NC} $message" | tee -a "$LOG_FILE"
}

log_warning() {
    local message="$1"
    echo -e "${YELLOW}[WARNING]${NC} $message" | tee -a "$LOG_FILE"
}

log_error() {
    local message="$1"
    echo -e "${RED}[ERROR]${NC} $message" | tee -a "$LOG_FILE"
}

# Print section headers
print_section() {
    local title="$1"
    echo "" | tee -a "$LOG_FILE"
    echo "============================================================" | tee -a "$LOG_FILE"
    echo "  $title" | tee -a "$LOG_FILE"
    echo "============================================================" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
}

# Error handler
error_exit() {
    local message="$1"
    local exit_code="${2:-1}"
    log_error "$message"
    log_error "Deployment failed. Check log file: $LOG_FILE"
    cleanup_temp_files
    exit "$exit_code"
}

# Trap handler for unexpected errors
trap_handler() {
    local exit_code=$?
    log_error "Script terminated unexpectedly with exit code: $exit_code"
    cleanup_temp_files
    exit "$exit_code"
}

trap trap_handler ERR INT TERM

# Cleanup temporary files
cleanup_temp_files() {
    if [[ -d "$TEMP_DIR" ]]; then
        log_info "Cleaning up temporary files..."
        rm -rf "$TEMP_DIR"
    fi
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Validate URL format
validate_url() {
    local url="$1"
    if [[ "$url" =~ ^https?:// ]] || [[ "$url" =~ ^git@ ]]; then
        return 0
    fi
    return 1
}

# Validate IP address
validate_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    elif [[ "$ip" =~ ^[a-zA-Z0-9][a-zA-Z0-9\-\.]*[a-zA-Z0-9]$ ]]; then
        # Also accept hostnames
        return 0
    fi
    return 1
}

# Validate port number
validate_port() {
    local port="$1"
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    fi
    return 1
}

#============================================================#
# INPUT COLLECTION AND VALIDATION
#============================================================#

collect_user_input() {
    print_section "Step 1: Collecting Deployment Parameters..."
    
    # Git Repository URL
    while true; do
        read -rp "Enter Git Repository URL: " GIT_REPO_URL
        if validate_url "$GIT_REPO_URL"; then
            log_success "Valid repository URL provided"
            break
        else
            log_error "Invalid URL format. Please provide a valid github repo URL."
        fi
    done
    
    # Personal Access Token
    while true; do
        read -rsp "Enter Personal Access Token (PAT): " GIT_PAT
        echo ""
        if [[ -n "$GIT_PAT" ]]; then
            log_success "PAT received"
            break
        else
            log_error "PAT cannot be empty"
        fi
    done
    
    # Branch name
    read -rp "Enter branch name [default: main]: " GIT_BRANCH
    GIT_BRANCH="${GIT_BRANCH:-main}"
    log_info "Using branch: $GIT_BRANCH"
    
    # SSH Username
    while true; do
        read -rp "Enter server username: " SSH_USER
        if [[ -n "$SSH_USER" ]]; then
            log_success "Server username: $SSH_USER"
            break
        else
            log_error "Username cannot be empty"
        fi
    done
    
    # SSH Host
    while true; do
        read -rp "Enter server IP address or hostname: " SSH_HOST
        if validate_ip "$SSH_HOST"; then
            log_success "Server address: $SSH_HOST"
            break
        else
            log_error "Invalid IP address or hostname"
        fi
    done
    
    # SSH Key Path
    while true; do
        read -rp "Enter SSH key path [default: ~/.ssh/id_rsa]: " SSH_KEY_PATH
        SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa}"
        if [[ -f "$SSH_KEY_PATH" ]]; then
            log_success "SSH key found: $SSH_KEY_PATH"
            break
        else
            log_error "SSH key not found at: $SSH_KEY_PATH"
        fi
    done
    
    # Application Port
    while true; do
        read -rp "Enter application internal port: " APP_PORT
        if validate_port "$APP_PORT"; then
            log_success "Application port: $APP_PORT"
            break
        else
            log_error "Invalid port number (must be 1-65535)"
        fi
    done
    
    # Extract project name from repo URL
    PROJECT_NAME=$(basename "$GIT_REPO_URL" .git)
    REMOTE_APP_DIR="/opt/$PROJECT_NAME"
    
    log_info "Project name: $PROJECT_NAME"
    log_info "Remote deployment directory: $REMOTE_APP_DIR"
    
    # Confirmation
    echo ""
    log_warning "Please review the deployment configuration:"
    echo "  Repository: $GIT_REPO_URL"
    echo "  Branch: $GIT_BRANCH"
    echo "  Server: $SSH_USER@$SSH_HOST"
    echo "  App Port: $APP_PORT"
    echo "  Remote Directory: $REMOTE_APP_DIR"
    echo ""
    read -rp "Proceed with deployment? (yes/no): " confirm
    if [[ ! "$confirm" =~ ^[Yy][Ee][Ss]$ ]]; then
        error_exit "Deployment cancelled by user" 0
    fi
}

#============================================================#
# REPOSITORY CLONING AND VALIDATION
#============================================================#

clone_repository() {
    print_section "Step 2: Cloning Repository (using GitHub PAT)"

    mkdir -p "$TEMP_DIR"
    cd "$TEMP_DIR" || error_exit "Failed to enter temp dir: $TEMP_DIR" 10

    # Resolve GitHub username from PAT
    log_info "Resolving GitHub username from PAT..."
    local gh_user
    gh_user=$(curl -s -H "Authorization: token ${GIT_PAT}" https://api.github.com/user | sed -n 's/.*"login":[[:space:]]*"\([^"]*\)".*/\1/p' || true)

    if [[ -z "$gh_user" ]]; then
        error_exit "Failed to retrieve GitHub username using provided PAT. Ensure the PAT is valid and has 'read:user' or repo scope." 10
    fi
    log_success "GitHub username resolved: $gh_user"

    # Normalize repo URL to HTTPS and inject credentials (do not print the full URL with PAT)
    local clone_url
    if [[ "$GIT_REPO_URL" =~ ^git@github\.com:([^/]+)/(.+)(\.git)?$ ]]; then
        # Convert SSH style git@github.com:owner/repo.git to HTTPS
        local owner="${BASH_REMATCH[1]}"
        local repo="${BASH_REMATCH[2]}"
        clone_url="https://${gh_user}:${GIT_PAT}@github.com/${owner}/${repo}.git"
    elif [[ "$GIT_REPO_URL" =~ ^https?:// ]]; then
        # Remove any trailing '/' then inject credentials after scheme
        local stripped="${GIT_REPO_URL#http://}"
        stripped="${stripped#https://}"
        clone_url="https://${gh_user}:${GIT_PAT}@${stripped}"
    else
        # Fallback: attempt to treat as HTTPS path
        clone_url="https://${gh_user}:${GIT_PAT}@${GIT_REPO_URL}"
    fi

    log_info "Cloning repository from GitHub as user ${gh_user}..."
    if [[ -d "$PROJECT_NAME" ]]; then
        log_info "Local checkout exists, updating remote URL and pulling latest changes..."
        cd "$PROJECT_NAME" || error_exit "Failed to enter project dir: $PROJECT_NAME" 11

        # Ensure origin uses credentialed HTTPS URL so pulls succeed
        if ! git remote set-url origin "$clone_url" >> "$LOG_FILE" 2>&1; then
            error_exit "Failed to set remote URL for existing repository" 11
        fi

        if ! git fetch origin >> "$LOG_FILE" 2>&1; then
            error_exit "Failed to fetch from origin" 11
        fi

        if ! git checkout "$GIT_BRANCH" >> "$LOG_FILE" 2>&1; then
            error_exit "Failed to checkout branch: $GIT_BRANCH" 12
        fi

        if ! git pull origin "$GIT_BRANCH" >> "$LOG_FILE" 2>&1; then
            error_exit "Failed to pull latest changes" 11
        fi
    else
        if ! git clone "$clone_url" "$PROJECT_NAME" >> "$LOG_FILE" 2>&1; then
            error_exit "Failed to clone repository" 10
        fi
        cd "$PROJECT_NAME" || error_exit "Failed to enter project dir after clone" 10

        if ! git checkout "$GIT_BRANCH" >> "$LOG_FILE" 2>&1; then
            # Try to fetch remote branches then checkout
            git fetch origin >> "$LOG_FILE" 2>&1 || true
            if ! git checkout "$GIT_BRANCH" >> "$LOG_FILE" 2>&1; then
                error_exit "Failed to checkout branch: $GIT_BRANCH" 12
            fi
        fi
    fi

    log_success "Repository prepared and on branch: $GIT_BRANCH"
}

validate_project_structure() {
    print_section "Step 3: Validating Project Structure"
    
    local dockerfile_exists=false
    local compose_exists=false
    
    if [[ -f "Dockerfile" ]]; then
        log_success "Dockerfile found"
        dockerfile_exists=true
    fi
    
    if [[ -f "docker-compose.yml" ]] || [[ -f "docker-compose.yaml" ]]; then
        log_success "docker-compose.yml found"
        compose_exists=true
    fi
    
    if [[ "$dockerfile_exists" == false ]] && [[ "$compose_exists" == false ]]; then
        error_exit "Neither Dockerfile nor docker-compose.yml found in repository" 20
    fi
    
    log_success "Project structure validated"
}

#============================================================#
# SSH CONNECTIVITY AND REMOTE EXECUTION
#============================================================#

test_ssh_connection() {
    print_section "Step 4: Testing SSH Connection"
    
    log_info "Testing SSH connectivity to $SSH_USER@$SSH_HOST..."
    
    if ! ssh -i "$SSH_KEY_PATH" -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "$SSH_USER@$SSH_HOST" "echo 'SSH connection successful'" >> "$LOG_FILE" 2>&1; then
        error_exit "Failed to establish SSH connection" 30
    fi
    
    log_success "SSH connection established successfully"
}

execute_remote_command() {
    local command="$1"
    local error_message="${2:-Remote command failed}"
    local exit_code="${3:-40}"
    
    if ! ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no \
        "$SSH_USER@$SSH_HOST" "$command" >> "$LOG_FILE" 2>&1; then
        error_exit "$error_message" "$exit_code"
    fi
}

execute_remote_command_output() {
    local command="$1"
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no \
        "$SSH_USER@$SSH_HOST" "$command" 2>&1 | tee -a "$LOG_FILE"
}

#============================================================#
# REMOTE ENVIRONMENT PREPARATION
v

prepare_remote_environment() {
    print_section "Step 5: Preparing Remote Environment"
    
    log_info "Updating system packages..."
    execute_remote_command \
        "sudo apt-get update -qq" \
        "Failed to update system packages" \
        50
    
    log_success "System packages updated"
    
    # Install Docker
    log_info "Checking and installing Docker..."
    execute_remote_command \
        "if ! command -v docker &> /dev/null; then
            curl -fsSL https://get.docker.com -o get-docker.sh && \
            sudo sh get-docker.sh && \
            rm get-docker.sh
        fi" \
        "Failed to install Docker" \
        51
    
    # Install Docker Compose
    log_info "Checking and installing Docker Compose..."
    execute_remote_command \
        "if ! command -v docker-compose &> /dev/null; then
            sudo apt-get install -y docker-compose || \
            (sudo curl -L \"https://github.com/docker/compose/releases/latest/download/docker-compose-\$(uname -s)-\$(uname -m)\" -o /usr/local/bin/docker-compose && \
            sudo chmod +x /usr/local/bin/docker-compose)
        fi" \
        "Failed to install Docker Compose" \
        52
    
    # Install Nginx
    log_info "Checking and installing Nginx..."
    execute_remote_command \
        "if ! command -v nginx &> /dev/null; then
            sudo apt-get install -y nginx
        fi" \
        "Failed to install Nginx" \
        53
    
    # Add user to Docker group
    log_info "Adding user to Docker group..."
    execute_remote_command \
        "sudo usermod -aG docker $SSH_USER || true" \
        "Failed to add user to Docker group" \
        54
    
    # Enable and start services
    log_info "Enabling and starting services..."
    execute_remote_command \
        "sudo systemctl enable docker && \
         sudo systemctl start docker && \
         sudo systemctl enable nginx && \
         sudo systemctl start nginx" \
        "Failed to enable/start services" \
        55
    
    # Verify installations
    log_info "Verifying installations..."
    log_info "Docker version:"
    execute_remote_command_output "docker --version"
    
    log_info "Docker Compose version:"
    execute_remote_command_output "docker-compose --version || docker compose version"
    
    log_info "Nginx version:"
    execute_remote_command_output "nginx -v"
    
    log_success "Remote environment prepared successfully"
}

#============================================================#
# APPLICATION DEPLOYMENT
#============================================================#

transfer_application_files() {
    print_section "Step 6: Transferring Application Files"

    local local_path="$TEMP_DIR/$PROJECT_NAME"

    log_info "Creating remote directory..."
    execute_remote_command \
        "sudo mkdir -p $REMOTE_APP_DIR && sudo chown $SSH_USER:$SSH_USER $REMOTE_APP_DIR" \
        "Failed to create remote directory" \
        60

    log_info "Transferring files via rsync..."
    if ! rsync -avz --delete -e "ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no" \
        "$local_path/" "$SSH_USER@$SSH_HOST:$REMOTE_APP_DIR/" >> "$LOG_FILE" 2>&1; then
        error_exit "Failed to transfer files" 61
    fi
    
    log_success "Files transferred successfully"
}

deploy_docker_application() {
    print_section "Step 7: Deploying Docker Application"
    
    log_info "Stopping and removing old containers..."
    execute_remote_command \
        "cd $REMOTE_APP_DIR && \
         (docker-compose down 2>/dev/null || true) && \
         (docker stop $APP_NAME 2>/dev/null || true) && \
         (docker rm $APP_NAME 2>/dev/null || true)" \
        "Failed during cleanup" \
        70

    # Check if docker-compose file exists
    local has_compose
    has_compose=$(execute_remote_command_output "[ -f $REMOTE_APP_DIR/docker-compose.yml ] || [ -f $REMOTE_APP_DIR/docker-compose.yaml ] && echo 'yes' || echo 'no'")
    
    if [[ "$has_compose" == *"yes"* ]]; then
        log_info "Deploying with docker-compose..."
        execute_remote_command \
            "cd $REMOTE_APP_DIR && docker-compose up -d --build" \
            "Failed to deploy with docker-compose" \
            71
    else
        log_info "Deploying with docker build and run..."
        execute_remote_command \
            "cd $REMOTE_APP_DIR && \
             docker build -t $APP_NAME:latest . && \
             docker run -d --name $APP_NAME --restart unless-stopped -p $APP_PORT:$APP_PORT $APP_NAME:latest" \
            "Failed to deploy with docker" \
            72
    fi

    log_success "Docker application deployed"

    # Wait for container to start
    log_info "Waiting for container to start..."
    sleep 5

    # Check container health
    log_info "Checking container status..."
    execute_remote_command_output "docker ps | grep -E '$APP_NAME|CONTAINER'"

    log_info "Checking container logs (last 20 lines)..."
    execute_remote_command_output "docker logs --tail 20 \$(docker ps -q --filter name=$APP_NAME) 2>&1 || docker-compose -f $REMOTE_APP_DIR/docker-compose.yml logs --tail 20 2>&1"

    log_success "Application deployment completed"
}

#============================================================#
# NGINX CONFIGURATION
#============================================================#

configure_nginx() {
    print_section "Step 8: Configuring Nginx Reverse Proxy"

    local nginx_config="/etc/nginx/sites-available/$APP_NAME"
    local nginx_enabled="/etc/nginx/sites-enabled/$APP_NAME"

    log_info "Creating Nginx configuration..."

    # Create Nginx config
    execute_remote_command \
        "cat <<'EOF' | sudo tee $nginx_config
server {
    listen 80;
    server_name $SSH_HOST _;

    access_log /var/log/nginx/${APP_NAME}_access.log;
    error_log /var/log/nginx/${APP_NAME}_error.log;

    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \\\$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \\\$host;
        proxy_cache_bypass \\\$http_upgrade;
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \\\$scheme;
        
        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    # Health check endpoint
    location /health {
        access_log off;
        proxy_pass http://localhost:$APP_PORT/health;
    }
}
EOF" \
        "Failed to create Nginx configuration" \
        80
    
    log_info "Enabling Nginx site..."
    execute_remote_command \
        "sudo ln -sf $nginx_config $nginx_enabled" \
        "Failed to enable Nginx site" \
        81
    
    log_info "Removing default Nginx site..."
    execute_remote_command \
        "sudo rm -f /etc/nginx/sites-enabled/default" \
        "Failed to remove default site" \
        82
    
    log_info "Testing Nginx configuration..."
    execute_remote_command \
        "sudo nginx -t" \
        "Nginx configuration test failed" \
        83
    
    log_info "Reloading Nginx..."
    execute_remote_command \
        "sudo systemctl reload nginx" \
        "Failed to reload Nginx" \
        84
    
    log_success "Nginx configured successfully"
}

#============================================================#
# VALIDATION
#============================================================#

validate_deployment() {
    print_section "Step 9: Validating Deployment"

    # Check Docker service
    log_info "Checking Docker service status..."
    execute_remote_command_output "sudo systemctl is-active docker"

    # Check container status
    log_info "Checking container health..."
    local container_status
    container_status=$(execute_remote_command_output "docker ps --filter name=$APP_NAME --format '{{.Status}}'")

    if [[ -z "$container_status" ]]; then
        log_error "Container is not running"
        error_exit "Container health check failed" 90
    fi
    
    log_success "Container is running: $container_status"
    
    # Check Nginx status
    log_info "Checking Nginx service status..."
    execute_remote_command_output "sudo systemctl is-active nginx"
    
    # Test local connectivity on server
    log_info "Testing local application connectivity..."
    execute_remote_command \
        "curl -f -s -o /dev/null -w '%{http_code}' http://localhost:$APP_PORT || true" \
        "Local connectivity test warning (this may be OK if app has no root route)" \
        0  # Don't fail on this
    
    # Test Nginx proxy
    log_info "Testing Nginx reverse proxy..."
    local http_status
    http_status=$(execute_remote_command_output "curl -f -s -o /dev/null -w '%{http_code}' http://localhost || echo 'failed'")
    
    log_info "HTTP Status from Nginx: $http_status"
    
    # Test from local machine
    log_info "Testing external connectivity..."
    local external_status
    external_status=$(curl -f -s -o /dev/null -w '%{http_code}' "http://$SSH_HOST" 2>/dev/null || echo 'failed')
    
    if [[ "$external_status" =~ ^[0-9]+$ ]]; then
        log_success "External connectivity test: HTTP $external_status"
    else
        log_warning "External connectivity test failed. Check firewall rules."
    fi
    
    log_success "Deployment validation completed"
}

#============================================================#
# CLEANUP FUNCTIONALITY
#============================================================#

cleanup_deployment() {
    print_section "Cleanup Mode: Removing Deployment"
    
    log_warning "This will remove all deployed resources for $APP_NAME"
    read -rp "Are you sure you want to continue? (yes/no): " confirm
    
    if [[ ! "$confirm" =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Cleanup cancelled"
        exit 0
    fi
    
    log_info "Stopping and removing containers..."
    execute_remote_command \
        "cd $REMOTE_APP_DIR && \
         (docker-compose down -v 2>/dev/null || true) && \
         (docker stop $APP_NAME 2>/dev/null || true) && \
         (docker rm $APP_NAME 2>/dev/null || true) && \
         (docker rmi $APP_NAME:latest 2>/dev/null || true)" \
        "Cleanup warning: Some resources may not have been removed" \
        0
    
    log_info "Removing Nginx configuration..."
    execute_remote_command \
        "sudo rm -f /etc/nginx/sites-enabled/$APP_NAME && \
         sudo rm -f /etc/nginx/sites-available/$APP_NAME && \
         sudo systemctl reload nginx" \
        "Cleanup warning: Nginx config may not have been removed" \
        0
    
    log_info "Removing application directory..."
    execute_remote_command \
        "sudo rm -rf $REMOTE_APP_DIR" \
        "Cleanup warning: App directory may not have been removed" \
        0
    
    log_success "Cleanup completed successfully"
    cleanup_temp_files
    exit 0
}

#============================================================#
# MAIN EXECUTION
#============================================================#

print_banner() {
    echo ""
    echo "#============================================================#"
    echo "                   Dockerized Application Deployment Script By Kefas Lungu, for HNG 13 stage 1 task                    "
    echo "                              Version 1.0.1                                     "
    echo "#============================================================#"
    echo ""
}

main() {
    print_banner
    
    log_info "Deployment started at $(date)"
    log_info "Log file: $LOG_FILE"
    
    # Check for cleanup flag
    if [[ "${1:-}" == "--cleanup" ]]; then
        CLEANUP_MODE=true
        collect_user_input
        cleanup_deployment
    fi
    
    # Prerequisite checks
    log_info "Checking prerequisites..."
    command_exists git || error_exit "Git is not installed" 1
    command_exists ssh || error_exit "SSH is not installed" 2
    command_exists rsync || error_exit "Rsync is not installed" 3
    command_exists curl || error_exit "Curl is not installed" 4
    log_success "All prerequisites met"
    
    # Execute deployment steps
    collect_user_input
    clone_repository
    validate_project_structure
    test_ssh_connection
    prepare_remote_environment
    transfer_application_files
    deploy_docker_application
    configure_nginx
    validate_deployment
    
    # Final summary
    print_section "Deployment Summary"
    log_success "Deployment completed successfully!"
    echo ""
    echo "  Application URL: http://$SSH_HOST"
    echo "  Internal Port: $APP_PORT"
    echo "  Remote Directory: $REMOTE_APP_DIR"
    echo "  Log File: $LOG_FILE"
    echo ""
    log_info "You can access your application at: http://$SSH_HOST"
    log_info "To clean up this deployment, run: ./deploy.sh --cleanup"
    echo ""
    
    cleanup_temp_files
}

# Execute main function
main "$@"
