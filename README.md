## Automated Deployment Script (deploiy.sh) ##

This project contains a single Bash script designed to automate the deployment of a Dockerized application from a Git repository to a remote Ubuntu server via SSH and SCP.

The script ensures high robustness through:

Idempotency: It safely stops and removes old containers and avoids creating duplicate Nginx configurations.

Authentication: It uses a Personal Access Token (PAT) for Git authentication and an SSH key for server access.

Robustness: It includes client-side fixes (SSH keep-alive) and server-side fixes (directory ownership/permissions) to ensure reliable execution.

Logging: All actions and errors are logged to a timestamped file.

### Prerequisites ###

Remote Server: An Ubuntu-based server accessible via SSH.

SSH Key: A local SSH private key file (.pem or similar) with appropriate permissions (chmod 400).

GitHub PAT: A GitHub Personal Access Token with the repo scope enabled.

Local Environment: Git Bash (or any standard Linux/macOS terminal) where the script will be executed.

### Usage ###

Make Executable: Ensure the script has executable permissions:

chmod +x deploy.sh


Run the Script: Execute the script from your local machine:

./deploy.sh


Follow Prompts: The script will guide you through entering the following required parameters:

Git Repository URL

Personal Access Token (PAT) - Input is hidden for security

Remote Server SSH Username (e.g., ubuntu)

Remote Server IP Address

Path to SSH Private Key (e.g., /c/Users/emman/.ssh/hng-devops-key.pem)

Deployment Branch Name (defaults to main)

### Deployment Stages ###

The script executes the following stages sequentially:

Stage

Description

Key Command

Stage 1

Parameter Collection & Validation

prompt_required

Stage 2

Local Repository Management

git clone/pull (uses PAT)

Stage 3

SSH Connection Test

ssh

Stage 4

Remote Environment Setup

sudo apt install docker.io nginx / sudo chown

Stage 5

File Transfer & Build

scp / docker build

Stage 6

Nginx Proxy Configuration

sudo tee /etc/nginx/sites-available/default

Stage 7

Final Validation

docker ps / curl http://localhost/
