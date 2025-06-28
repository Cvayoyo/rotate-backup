#!/bin/bash

# === CONFIG ===
SOURCE_DIR="/home/rotate"
BACKUP_REPO="/home/rotate"
REPO_REMOTE="https://cvayoyo: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@github.com/cvayoyo/rotate-backup.git"

GIT_NAME="Rizqi Kamal"
GIT_EMAIL="rizqi@example.com"

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

# Tambahkan dan commit semua perubahan
git add .

git commit -m "Auto backup: $(date '+%Y-%m-%d %H:%M:%S')" || exit 0

# Push ke GitHub
git push origin main

