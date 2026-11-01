#!/bin/bash
# ---------------------------------------------------------------------------
# Script Name: curl_downgrade_and_register.sh
# Purpose    : Downgrade curl/libcurl packages, lock libcurl, and register SUSE
# ---------------------------------------------------------------------------

set -euo pipefail
LOGFILE="/var/log/curl_downgrade.log"
TMPDIR="/tmp/curl-downgrade"
BOOTSTRAP_SCRIPT="prod-sles-15-sp3-bootstrap.sh"
BASE_URL="https://pa-susemanager.vms.ad.varian.com/pub"

echo "===== $(date) : Starting curl downgrade process =====" | tee -a "$LOGFILE"

# Step 1: Create a temporary directory
echo "[INFO] Creating temporary directory..." | tee -a "$LOGFILE"
mkdir -p "$TMPDIR"
cd "$TMPDIR"

# Step 2: Download required packages
echo "[INFO] Downloading curl and libcurl packages..." | tee -a "$LOGFILE"
wget --no-check-certificate "$BASE_URL/curl-7.66.0-150200.4.84.1.x86_64.rpm" -O curl.rpm | tee -a "$LOGFILE"
wget --no-check-certificate "$BASE_URL/libcurl4-7.66.0-150200.4.84.1.x86_64.rpm" -O libcurl4.rpm | tee -a "$LOGFILE"

# Step 3: Downgrade the packages
echo "[INFO] Downgrading packages..." | tee -a "$LOGFILE"
rpm --upgrade --force "$TMPDIR"/*.rpm | tee -a "$LOGFILE"

# Step 4: Add zypper lock on libcurl
echo "[INFO] Adding zypper lock on libcurl..." | tee -a "$LOGFILE"
zypper al curl* | tee -a "$LOGFILE"

# Step 5: Run SUSE registration bootstrap script
if [[ -f "/tmp/$BOOTSTRAP_SCRIPT" ]]; then
    echo "[INFO] Running SUSE registration script..." | tee -a "$LOGFILE"
    chmod +x "/tmp/$BOOTSTRAP_SCRIPT"
    bash "/tmp/$BOOTSTRAP_SCRIPT" | tee -a "$LOGFILE"
else
    echo "[WARNING] Bootstrap script not found in $TMPDIR — please verify." | tee -a "$LOGFILE"
fi

echo "===== $(date) : Process completed successfully =====" | tee -a "$LOGFILE"
