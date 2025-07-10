#!/bin/bash

# === CONFIG ===
SOURCE_DIR="/home/rotate"
BACKUP_REPO="/home/rotate"
REPO_REMOTE="https://cvayoyo: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@github.com/cvayoyo/rotate-backup.git"

GIT_NAME="Cvayoyo"
GIT_EMAIL="akunqwiklabs.05@gmail.com"

cd "$BACKUP_REPO"

# Set git identity if not set
if ! git config user.name > /dev/null; then
  git config user.name "$GIT_NAME"
fi

if ! git config user.email > /dev/null; then
  git config user.email "$GIT_EMAIL"
fi

# === BACKUP START ===

# Backup /etc/shadowsocks ke dalam folder khusus
SS_BACKUP_DIR="$BACKUP_REPO/shadowsocks-backup"
mkdir -p "$SS_BACKUP_DIR"
rsync -a --delete /etc/shadowsocks/ "$SS_BACKUP_DIR/"

# Backup /etc/hosts
cp /etc/hosts "$BACKUP_REPO/hosts-backup"

# Inisialisasi Git jika belum
if [ ! -d ".git" ]; then
  git init
  git remote add origin "$REPO_REMOTE"
  git branch -M main
fi

# Add and commit if needed
git add .

if ! git diff --cached --quiet; then
  git commit -m "Auto backup: $(date '+%Y-%m-%d %H:%M:%S')"

  # Pull dulu biar sinkron, lalu push
  git pull --rebase origin main
  git push origin main
else
  echo "✅ No changes to commit"
fi
