#!/usr/bin/env bash
set -Eeuo pipefail

readonly INSTALL_DIR="/opt/device42"
readonly DEV_AGENT="$INSTALL_DIR/d42_linuxagent_x64_drc2"
readonly PROD_AGENT="$INSTALL_DIR/d42_linuxagent_x64_prc2"
readonly CRON_FILE="/etc/cron.d/device42-agents"

readonly DEV_URL="https://raw.githubusercontent.com/adenysovi/repo1/main/d42_linuxagent_x64_drc2"
readonly PROD_URL="https://raw.githubusercontent.com/adenysovi/repo1/main/d42_linuxagent_x64_prc2"

temporary_dir="$(mktemp -d)"
trap 'rm -rf -- "$temporary_dir"' EXIT

echo "[*] Downloading Device42 agents from GitHub..."
curl --fail --location --silent --show-error --retry 3 \
    --output "$temporary_dir/d42_linuxagent_x64_drc2" \
    "$DEV_URL"

curl --fail --location --silent --show-error --retry 3 \
    --output "$temporary_dir/d42_linuxagent_x64_prc2" \
    "$PROD_URL"

# Validate non-empty 64-bit ELF binaries
for agent in \
    "$temporary_dir/d42_linuxagent_x64_drc2" \
    "$temporary_dir/d42_linuxagent_x64_prc2"
do
    [[ -s "$agent" ]] || { echo "ERROR: Empty download: $agent" >&2; exit 1; }
    magic="$(od -An -tx1 -N4 "$agent" | tr -d '[:space:]')"
    [[ "$magic" == "7f454c46" ]] || { echo "ERROR: Download is not an ELF executable: $agent" >&2; exit 1; }
done

# Ensure Dev and Prod are distinct binaries
if cmp --silent "$temporary_dir/d42_linuxagent_x64_drc2" "$temporary_dir/d42_linuxagent_x64_prc2"; then
    echo "ERROR: Dev and Prod downloads are identical." >&2
    exit 1
fi

echo "[*] Installing Device42 agents to $INSTALL_DIR..."
install -d -o root -g root -m 0755 "$INSTALL_DIR"
install -o root -g root -m 0755 "$temporary_dir/d42_linuxagent_x64_drc2" "$DEV_AGENT"
install -o root -g root -m 0755 "$temporary_dir/d42_linuxagent_x64_prc2" "$PROD_AGENT"

echo "[*] Cleaning legacy Device42 entries from user and root crontabs..."
clean_spool() {
    local target_user="$1"
    local raw_spool="$temporary_dir/${target_user}-crontab"
    local filtered_spool="$temporary_dir/${target_user}-clean"

    if crontab -u "$target_user" -l > "$raw_spool" 2>/dev/null; then
        sed -E \
            -e '/^# D42_/d' \
            -e '/d42_linuxagent_x64_/d' \
            "$raw_spool" > "$filtered_spool"

        if grep -q '[^[:space:]]' "$filtered_spool"; then
            crontab -u "$target_user" "$filtered_spool"
        else
            crontab -u "$target_user" -r 2>/dev/null || true
        fi
    fi
}

clean_spool "root"
if id -u "adenysov" >/dev/null 2>&1; then
    clean_spool "adenysov"
fi

echo "[*] Installing system cron schedule to $CRON_FILE..."
cat > "$temporary_dir/device42-agents" <<'CRON_EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Device42 development (drc2)
47 9 * * * root /usr/bin/flock -n /run/d42-dev.lock /opt/device42/d42_linuxagent_x64_drc2 -quiet -discover-last-login -ignore-ipv6 -hostname-precedence -device-name-format 3 -ignore-domain -skip-virtual-machines -new-device-object-category "EUC" -device-tags "EUC_ubuntu" >> /var/log/d42_agent_dev.log 2>&1
@reboot root /bin/sleep 900 && /usr/bin/flock -n /run/d42-dev.lock /opt/device42/d42_linuxagent_x64_drc2 -quiet -discover-last-login -ignore-ipv6 -hostname-precedence -device-name-format 3 -ignore-domain -skip-virtual-machines -new-device-object-category "EUC" -device-tags "EUC_ubuntu" >> /var/log/d42_agent_dev.log 2>&1

# Device42 production (prc2)
57 9 * * * root /usr/bin/flock -n /run/d42-prod.lock /opt/device42/d42_linuxagent_x64_prc2 -quiet -discover-last-login -ignore-ipv6 -hostname-precedence -device-name-format 3 -ignore-domain -skip-virtual-machines -new-device-object-category "EUC" -device-tags "EUC_ubuntu" >> /var/log/d42_agent_prod.log 2>&1
@reboot root /bin/sleep 900 && /usr/bin/flock -n /run/d42-prod.lock /opt/device42/d42_linuxagent_x64_prc2 -quiet -discover-last-login -ignore-ipv6 -hostname-precedence -device-name-format 3 -ignore-domain -skip-virtual-machines -new-device-object-category "EUC" -device-tags "EUC_ubuntu" >> /var/log/d42_agent_prod.log 2>&1
CRON_EOF

install -o root -g root -m 0644 "$temporary_dir/device42-agents" "$CRON_FILE"

echo "[*] Device42 agents and cron schedules installed successfully."
