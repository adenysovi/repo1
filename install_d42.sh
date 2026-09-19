#!/bin/bash 

set -Eeuo pipefail 

[[ $EUID -eq 0 ]] || { echo "ERROR: Run as root." >&2; exit 1; } 

for cmd in curl crontab flock install od cmp; do 

    command -v "$cmd" >/dev/null || { 

        echo "ERROR: Missing command: $cmd" >&2 

        exit 1 

    } 

done 

dir="/opt/device42" 

base="https://raw.githubusercontent.com/adenysovi/repo1/main" 

tmp="$(mktemp -d)" 

trap 'rm -rf -- "$tmp"' EXIT 

flags='-quiet -discover-last-login -ignore-ipv6 -hostname-precedence -device-name-format 3 -ignore-domain -skip-virtual-machines -new-device-object-category "EUC" -device-tags "EUC_ubuntu"' 

# Download and validate both agents before installing either. 

for suffix in drc2 prc2; do 

    name="d42_linuxagent_x64_$suffix" 

    echo "[*] Downloading $name" 

    curl -fsSL --retry 3 --connect-timeout 20 --max-time 180 \ 

        "$base/$name" -o "$tmp/$name" 

  

    [[ "$(od -An -tx1 -N5 "$tmp/$name" | tr -d '[:space:]')" == "7f454c4602" ]] || { 

        echo "ERROR: $name is not a 64-bit ELF file." >&2 

        exit 1 

    } 

done 

if cmp -s "$tmp/d42_linuxagent_x64_drc2" "$tmp/d42_linuxagent_x64_prc2"; then 

    echo "ERROR: Dev and Prod binaries are identical." >&2 

    exit 1 

fi 

install -d -o root -g root -m 0755 "$dir" 

for suffix in drc2 prc2; do 

    name="d42_linuxagent_x64_$suffix" 

    install -o root -g root -m 0755 "$tmp/$name" "$dir/$name" 

done 

# Remove matching legacy entries, preserving unrelated cron jobs. 

for user in root adenysov; do 

    if id "$user" >/dev/null 2>&1 && 

       crontab -u "$user" -l > "$tmp/old-cron" 2>/dev/null; then 

        sed '/^# D42_/d; /d42_linuxagent_x64_/d' \ 

            "$tmp/old-cron" > "$tmp/clean-cron" 

        crontab -u "$user" "$tmp/clean-cron" 

    fi 

done 

# Build daily and boot schedules. 

cat > "$tmp/schedule" <<'EOF' 

SHELL=/bin/bash 

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin 

EOF 

for env in dev prod; do 

    if [[ $env == dev ]]; then 

        suffix=drc2 

        minute=47 

    else 

        suffix=prc2 

        minute=57 

    fi 

    job="/usr/bin/flock -n /run/d42-$env.lock $dir/d42_linuxagent_x64_$suffix $flags >> /var/log/d42_agent_$env.log 2>&1" 

    printf '%s 9 * * * root %s\n' "$minute" "$job" >> "$tmp/schedule" 

    printf '@reboot root /bin/sleep 900 && %s\n' "$job" >> "$tmp/schedule" 

done 

install -o root -g root -m 0644 "$tmp/schedule" /etc/cron.d/device42-agents 

echo "[OK] Device42 Dev/Prod agents and schedules installed." 
