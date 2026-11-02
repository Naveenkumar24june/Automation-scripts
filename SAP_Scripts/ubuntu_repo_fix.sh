#!/bin/bash

#############################################
# Enterprise APT Repository Sanitizer
# Supports: Ubuntu & Debian & Unix
#############################################

DATE=$(date +"%Y-%m-%d_%H-%M-%S")
BACKUP_DIR="/root/apt_repo_backup_$DATE"
LOG_FILE="/var/log/apt_repo_sanitizer_$DATE.log"

echo "====================================================" | tee -a "$LOG_FILE"
echo "APT Repository Sanitizer Started at $DATE" | tee -a "$LOG_FILE"
echo "====================================================" | tee -a "$LOG_FILE"

# Root check
if [[ $EUID -ne 0 ]]; then
   echo "ERROR: Please run as root." | tee -a "$LOG_FILE"
   exit 1
fi

#############################################
# OS Detection
#############################################

if [ -f /etc/os-release ]; then
    . /etc/os-release
else
    echo "ERROR: Cannot detect OS." | tee -a "$LOG_FILE"
    exit 1
fi

case "$ID" in
    ubuntu)
        OFFICIAL_PATTERNS="archive.ubuntu.com|security.ubuntu.com|ubuntu.com"
        echo "Detected OS: Ubuntu" | tee -a "$LOG_FILE"
        ;;
    debian)
        OFFICIAL_PATTERNS="deb.debian.org|security.debian.org|ftp.debian.org"
        echo "Detected OS: Debian" | tee -a "$LOG_FILE"
        ;;
    *)
        echo "ERROR: Unsupported OS: $ID" | tee -a "$LOG_FILE"
        exit 1
        ;;
esac

#############################################
# Create Backup
#############################################

echo "Creating backup directory: $BACKUP_DIR" | tee -a "$LOG_FILE"
mkdir -p "$BACKUP_DIR"

echo "Backing up source files..." | tee -a "$LOG_FILE"
cp -p /etc/apt/sources.list "$BACKUP_DIR/" 2>/dev/null

if [ -d /etc/apt/sources.list.d ]; then
    cp -rp /etc/apt/sources.list.d "$BACKUP_DIR/"
fi

#############################################
# Sanitize sources.list
#############################################

echo "Checking /etc/apt/sources.list..." | tee -a "$LOG_FILE"

grep -vE "$OFFICIAL_PATTERNS|^#|^$" /etc/apt/sources.list > /tmp/non_official_sources.txt

if [ -s /tmp/non_official_sources.txt ]; then
    echo "Non-OS entries found. Commenting them..." | tee -a "$LOG_FILE"
    while read -r line; do
        echo "Commenting: $line" | tee -a "$LOG_FILE"
        sed -i "s|^$line|#DISABLED_BY_SCRIPT $line|" /etc/apt/sources.list
    done < /tmp/non_official_sources.txt
else
    echo "No non-OS entries in sources.list." | tee -a "$LOG_FILE"
fi

#############################################
# Process sources.list.d
#############################################

if [ -d /etc/apt/sources.list.d ]; then
    for file in /etc/apt/sources.list.d/*; do
        if [[ -f "$file" ]]; then
            if grep -qE "$OFFICIAL_PATTERNS" "$file"; then
                echo "Keeping official repo file: $file" | tee -a "$LOG_FILE"
            else
                echo "Moving non-OS repo file: $file" | tee -a "$LOG_FILE"
                mv "$file" "$BACKUP_DIR/"
            fi
        fi
    done
fi

#############################################
# Clean and Update
#############################################

echo "Running apt clean..." | tee -a "$LOG_FILE"
apt clean >> "$LOG_FILE" 2>&1

echo "Running apt update..." | tee -a "$LOG_FILE"
APT_OUTPUT=$(apt update 2>&1)
echo "$APT_OUTPUT" >> "$LOG_FILE"

#############################################
# Validation
#############################################

if echo "$APT_OUTPUT" | grep -qE "^W:|^E:"; then
    echo "====================================================" | tee -a "$LOG_FILE"
    echo "WARNING: apt update still reports warnings/errors." | tee -a "$LOG_FILE"
    echo "Manual intervention required." | tee -a "$LOG_FILE"
    echo "Check log: $LOG_FILE"
    echo "====================================================" | tee -a "$LOG_FILE"
    exit 2
else
    echo "====================================================" | tee -a "$LOG_FILE"
    echo "SUCCESS: apt update completed cleanly." | tee -a "$LOG_FILE"
    echo "Backup stored at: $BACKUP_DIR"
    echo "Log file: $LOG_FILE"
    echo "====================================================" | tee -a "$LOG_FILE"
fi

