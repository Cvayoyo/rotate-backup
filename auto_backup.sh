#!/bin/bash

# ---
# A script to automatically back up specified configuration files
# to a private Git repository.
# WARNING: This script contains a hardcoded Personal Access Token.
# ---

# === CONFIGURATION ===
# Stop script on any error
set -e
# Treat pipe failures as errors
set -o pipefail

# --- Paths and Repo ---
BACKUP_REPO="/home/rotate"
REPO_URL="https://github.com/cvayoyo/rotate-backup.git"

# --- Git Identity ---
GIT_NAME="Rizqi Kamal"
GIT_EMAIL="rizqi@example.com"

# --- Credentials (HARDCODED TOKEN) ---
# WARNING: Storing tokens directly in scripts is a security risk.
GIT_TOKEN="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"


# === SCRIPT START ===

echo "Starting backup process at $(date '+%Y-%m-%d %H:%M:%S')"

# Navigate to the backup repository directory.
cd "$BACKUP_REPO"

# Construct the remote URL with the hardcoded token.
# The username 'cvayoyo' must match your GitHub username.
REPO_REMOTE_WITH_TOKEN="https://cvayoyo:${GIT_TOKEN}@${REPO_URL#https://}"

# --- Git Configuration ---
echo "Configuring Git identity..."
git config user.name "$GIT_NAME"
git config user.email "$GIT_EMAIL"


# === BACKUP TASKS ===

echo "Backing up configuration files..."

# Backup /etc/shadowsocks using rsync
SS_BACKUP_DIR="$BACKUP_REPO/shadowsocks-backup"
mkdir -p "$SS_BACKUP_DIR"
rsync -a --delete /etc/shadowsocks/ "$SS_BACKUP_DIR/"
echo "✓ Shadowsocks config backed up."

# Backup /etc/hosts
cp /etc/hosts "$BACKUP_REPO/hosts-backup"
echo "✓ Hosts file backed up."


# === GIT OPERATIONS ===

# Initialize Git repository if it's not already initialized
if [ ! -d ".git" ]; then
    echo "Initializing new Git repository..."
    git init
    git branch -M main
    git remote add origin "$REPO_URL"
fi

# Ensure the remote URL in the config is the clean one (without token)
git remote set-url origin "$REPO_URL"

# Add all changes to the staging area
git add .

# Check if there are any changes to commit
if git diff --cached --quiet; then
    echo "✅ No changes to commit. Backup is up-to-date."
else
    echo "Changes detected. Committing and pushing to remote..."
    # Commit the changes with a timestamp
    git commit -m "Auto backup: $(date '+%Y-%m-%d %H:%M:%S')"

    # Pull latest changes from remote before pushing
    # Temporarily disable any credential helper to force use of the token
    echo "Pulling latest changes from remote..."
    git -c credential.helper= pull --rebase "$REPO_REMOTE_WITH_TOKEN" main

    # Push the new commit to the remote repository
    # Temporarily disable any credential helper here as well
    echo "Pushing changes to remote..."
    git -c credential.helper= push "$REPO_REMOTE_WITH_TOKEN" main
    echo "🎉 Backup successfully pushed to remote."
fi

echo "Backup process finished."

