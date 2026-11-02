#!/bin/bash

LOG_FILE="/var/log/disk_cleanup.log"
OMS_LOG="/var/opt/microsoft/omsconfig/omsconfig.log"
USAGE_THRESHOLD=70
CUSTOM_ROTATE_DIR="/etc/logrotate.d/custom_cleanup"

mkdir -p "$CUSTOM_ROTATE_DIR"

# Detect rsyslog rotate script or fallback
if [ -x /usr/lib/rsyslog/rsyslog-rotate ]; then
    POSTROTATE_CMD="/usr/lib/rsyslog/rsyslog-rotate"
else
    POSTROTATE_CMD="systemctl reload rsyslog || true"
fi

# Function to log actions
log_action() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Function to check if script is run as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "This script must be run as root."
        log_action "Script execution failed: not run as root."
        exit 1
    fi
}

# Function to determine the OS and log 
log_os_info() {
    if [ -f /etc/redhat-release ]; then
        os="RHEL"
    elif [ -f /etc/debian_version ]; then
        os="Debian-based"
    elif [ -f /etc/SuSE-release ]; then
        os="SUSE"
    else
        os="Unknown"
    fi
    log_action "Operating System: $os"
}

# Function to clean logs under /var/log
cleanup_logs() {
    log_action "Cleaning /var/log/journal to save space."
    journalctl --vacuum-size=512M
    log_action "Ran journalctl --vacuum-size=512M."
}

# Function to create log rotation configuration
# Parameters: logfile purge_days(optional)
create_logrotate_config() {
    local logfile=$1
    local rotation_condition="weekly"
    local retention_files=4
    local purge_days=${2:-0}

    mkdir -p "$CUSTOM_ROTATE_DIR"
    cat <<EOF > "$CUSTOM_ROTATE_DIR/$(basename "$logfile")"
$logfile {
    $rotation_condition
    rotate $retention_files
    compress
    missingok
    notifempty
    create 0640 root utmp
    sharedscripts
    postrotate
        $POSTROTATE_CMD
    endscript
EOF

    if [ "$purge_days" -gt 0 ]; then
        sed -i "/sharedscripts/a\    prerotate\n        find $(dirname "$logfile") -name \"$(basename "$logfile").*\" -type f -mtime +$purge_days -exec rm -f {} \;\n    endscript" \
        "$CUSTOM_ROTATE_DIR/$(basename "$logfile")"
    fi

    log_action "Log rotation configuration for $logfile created successfully."
}

# Function to configure OMS log rotation
configure_oms_logrotate() {
    if [ -f "$OMS_LOG" ]; then
        cat <<EOF > "$CUSTOM_ROTATE_DIR/omsconfig"
$OMS_LOG {
    daily
    size 200M
    compress
    rotate 15
    maxage 15
    notifempty
    missingok
    sharedscripts
    postrotate
        $POSTROTATE_CMD
    endscript
    prerotate
        find $(dirname $OMS_LOG) -name "$(basename $OMS_LOG).*" -type f -mtime +15 -exec rm -f {} \;
    endscript
}
EOF
        log_action "OMS log rotation configured."
    else
        log_action "OMS log file not found. Skipping configuration."
    fi
}

# Function to configure logrotate based on OS
configure_logrotate() {
    if [ "$os" == "Debian-based" ]; then
        create_logrotate_config "/var/log/kern.log"
        create_logrotate_config "/var/log/messages"
        create_logrotate_config "/var/log/auth.log"
        create_logrotate_config "/var/log/boot.log"
        create_logrotate_config "/var/log/syslog"
        create_logrotate_config "/var/log/audit/audit.log"
    elif [ "$os" == "RHEL" ]; then
        create_logrotate_config "/var/log/secure"
        create_logrotate_config "/var/log/messages"
        create_logrotate_config "/var/log/boot.log"
        create_logrotate_config "/var/log/dmesg"
        create_logrotate_config "/var/log/yum.log"
        create_logrotate_config "/var/log/audit/audit.log"
    elif [ "$os" == "SUSE" ]; then
        create_logrotate_config "/var/log/messages"
        create_logrotate_config "/var/log/boot.log"
        create_logrotate_config "/var/log/syslog"
        create_logrotate_config "/var/log/auth.log"
        create_logrotate_config "/var/log/kern.log"
        create_logrotate_config "/var/log/audit/audit.log"
    else
        log_action "Unsupported OS. No log rotation configurations created."
    fi

    configure_oms_logrotate
}

# Function to gzip uncompressed rotated audit logs
gzip_audit_logs() {
    local audit_dir="/var/log/audit"
    if [ -d "$audit_dir" ]; then
        find "$audit_dir" -maxdepth 1 -type f -name "audit.log.[0-9]*" ! -name "*.gz" -exec gzip -f {} \;
        log_action "Compressed old uncompressed audit logs in $audit_dir"
    else
        log_action "Audit directory $audit_dir not found. Skipping gzip step."
    fi
}

# Remove old compressed logs older than 90 days
remove_old_zipped_logs() {
    log_action "Removing compressed log files older than 90 days."

    find /var/log -type f \( \
        -name "messages-*.gz" -o \
        -name "audit.log.*.gz" -o \
        -name "auth.log-*.gz" -o \
        -name "kern.log-*.gz" -o \
        -name "secure-*.gz" \
    \) -mtime +90 -exec rm -f {} \;

    log_action "Old compressed logs older than 90 days removed."
}

# Function to handle disk usage > threshold for all mounts
handle_disk_usage() {
    while read -r filesystem size used avail usep mount; do
        usage=${usep%\%}
        if [ "$usage" -gt $USAGE_THRESHOLD ]; then
            log_action "Disk usage in $mount is above $USAGE_THRESHOLD% ($usage%)."
            echo -e "\n==== Disk usage is $usage% on $mount ====\n"

            # Only run cleanup for /var or /
            if [[ "$mount" == "/var" || "$mount" == "/" ]]; then
                log_action "Major space consumers found under $mount. Running cleanup."
                configure_logrotate
                cleanup_logs
                gzip_audit_logs
                remove_old_zipped_logs
            else
                # For other mounts, just log the high usage, no top consumers
                log_action "Disk usage in $mount exceeds threshold but no automatic cleanup configured."
            fi
        else
            log_action "Disk usage is below threshold ($usage%) on $mount."
        fi
    done < <(df -h --output=source,size,used,avail,pcent,target | tail -n +2)
}

# Post-cleanup validation
post_cleanup_check() {
    echo -e "\n===================================================="
    echo " Post-Cleanup Disk Usage Validation"
    echo "===================================================="

    TMP_REPORT="/tmp/disk_usage_postcleanup.txt"
    > "$TMP_REPORT"

    # Get all real mount points (excluding system mounts)
    mount_points=$(df -hP | awk 'NR>1 && $6 !~ /^\/(boot|dev|proc|run|sys|tmpfs|snap)/ {print $6}')

    for mount in $mount_points; do
        usage=$(df -hP "$mount" | awk 'NR==2 {gsub("%",""); print $5}')
        if [ "$usage" -gt "$USAGE_THRESHOLD" ]; then
            echo "⚠️  $mount is still above threshold (${usage}%)" | tee -a "$TMP_REPORT"
            echo "Top consumers under $mount:" | tee -a "$TMP_REPORT"
            du -xah "$mount" 2>/dev/null | sort -rh | head -n 10 | tee -a "$TMP_REPORT"
            echo "----------------------------------------------------" | tee -a "$TMP_REPORT"
        fi
    done

    if [ -s "$TMP_REPORT" ]; then
        echo -e "\nHigh usage detected after cleanup. Details logged to $TMP_REPORT."
        log_action "Post-cleanup: Some filesystems still exceed ${USAGE_THRESHOLD}%. Details in $TMP_REPORT."
    else
        echo -e "\nAll monitored filesystems are under ${USAGE_THRESHOLD}% usage."
        log_action "Post-cleanup: All filesystems under ${USAGE_THRESHOLD}% usage."
    fi
}

# --- Main execution ---
check_root
log_os_info

echo -e "\n==== Filesystem utilization BEFORE cleanup ====\n"
df -h
log_action "Filesystem utilization before cleanup:"
df -h >> "$LOG_FILE"

handle_disk_usage
post_cleanup_check

# =====================================================================
#  Final Filesystem utilization post cleanup
# =====================================================================
{
    echo
    echo "==== Filesystem utilization post cleanup ===="
    echo
    df -hT
    echo
    echo "(Also logged to $LOG_FILE)"
} | tee -a "$LOG_FILE"


