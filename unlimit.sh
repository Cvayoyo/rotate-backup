#!/bin/bash

set -e

TARGET_NOFILE=65535
LIMITS_CONF="/etc/security/limits.conf"
PAM_COMMON="/etc/pam.d/common-session"

echo "🔧 Menyesuaikan ulimit ke $TARGET_NOFILE ..."

# 1. Tampilkan nilai ulimit saat ini
current=$(ulimit -n)
echo "📊 open files (ulimit -n) saat ini: $current"

# 2. Tambahkan ke /etc/security/limits.conf jika belum ada
echo "📁 Memastikan konfigurasi di $LIMITS_CONF ..."
grep -q "^\* soft nofile $TARGET_NOFILE" $LIMITS_CONF || echo "* soft nofile $TARGET_NOFILE" | sudo tee -a $LIMITS_CONF
grep -q "^\* hard nofile $TARGET_NOFILE" $LIMITS_CONF || echo "* hard nofile $TARGET_NOFILE" | sudo tee -a $LIMITS_CONF
grep -q "^root soft nofile $TARGET_NOFILE" $LIMITS_CONF || echo "root soft nofile $TARGET_NOFILE" | sudo tee -a $LIMITS_CONF
grep -q "^root hard nofile $TARGET_NOFILE" $LIMITS_CONF || echo "root hard nofile $TARGET_NOFILE" | sudo tee -a $LIMITS_CONF

# 3. Pastikan pam_limits.so aktif di PAM session
echo "📁 Memastikan pam_limits.so aktif di $PAM_COMMON ..."
grep -q "pam_limits.so" $PAM_COMMON || echo "session required pam_limits.so" | sudo tee -a $PAM_COMMON

# 4. Tambah juga ke ~/.bashrc agar berlaku saat login shell
if ! grep -q "ulimit -n $TARGET_NOFILE" ~/.bashrc; then
    echo "ulimit -n $TARGET_NOFILE" >> ~/.bashrc
    echo "✅ Ditambahkan ke ~/.bashrc (aktif saat login ulang)"
fi

# 5. Tambahkan juga ke ~/.profile jika digunakan
if ! grep -q "ulimit -n $TARGET_NOFILE" ~/.profile; then
    echo "ulimit -n $TARGET_NOFILE" >> ~/.profile
fi

# 6. Aktifkan untuk sesi saat ini
ulimit -n $TARGET_NOFILE

echo "✅ ulimit berhasil disetel ke $(ulimit -n)"

echo -e "\n⚠️  Silakan logout & login ulang atau reboot agar limit ini aktif penuh di semua sesi."

