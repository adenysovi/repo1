#!/bin/bash 

set -Eeuo pipefail 

  

trap 'rc=$?; echo "ERROR: line $LINENO, exit $rc" >&2' ERR 

  

[[ $EUID -eq 0 ]] || { 

    echo "ERROR: Run as root." >&2 

    exit 1 

} 

  

for cmd in curl crontab flock install od cmp tr sed systemctl; do 

    command -v "$cmd" >/dev/null || { 

        echo "ERROR: Missing command: $cmd" >&2 

        exit 1 

    } 

done 

  

[[ "$(uname -m)" == "x86_64" ]] || { 

    echo "ERROR: These agents require an x86-64 laptop." >&2 

    exit 1 

} 

  

systemctl is-active --quiet cron || { 

    echo "ERROR: cron is not running. Start it before deployment." >&2 

    exit 1 

} 

  

dir="/opt/device42" 

base="https://raw.githubusercontent.com/adenysovi/repo1/main" 

cron_file="/etc/cron.d/device42-agents" 

tmp="$(mktemp -d)" 

trap 'rm -rf -- "$tmp"' EXIT 

  

flags='-quiet -discover-last-login -ignore-ipv6 -hostname-precedence -device-name-format 3 -ignore-domain -skip-virtual-machines -new-device-object-category "EUC" -device-tags "EUC_ubuntu"' 

  

# Download and validate both agents before installing. 

for suffix in drc2 prc2; do 

    name="d42_linuxagent_x64_$suffix" 

    echo "[*] Downloading $name" 

  

    curl -fsSL --retry 3 --connect-timeout 20 --max-time 180 "$base/$name" -o "$tmp/$name" 

  

    magic="$(od -An -tx1 -N5 "$tmp/$name" | tr -d '[:space:]')" 

    [[ "$magic" == "7f454c4602" ]] || { 

        echo "ERROR: $name is not a 64-bit ELF file." >&2 

        exit 1 

    } 

done 

  

if cmp -s "$tmp/d42_linuxagent_x64_drc2" "$tmp/d42_linuxagent_x64_prc2"; then 

    echo "ERROR: Dev and Prod binaries are identical." >&2 

    exit 1 

fi 

  

# Build the complete schedule without a heredoc. 

printf '%s\n' 'SHELL=/bin/bash' 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' > "$tmp/schedule" 

  

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

  

echo "[*] Installing agents..." 

install -d -o root -g root -m 0755 "$dir" 

  

for suffix in drc2 prc2; do 

    name="d42_linuxagent_x64_$suffix" 

    install -o root -g root -m 0755 "$tmp/$name" "$dir/$name" 

done 

  

echo "[*] Cleaning legacy root/adenysov cron entries..." 

for user in root adenysov; do 

    if id "$user" >/dev/null 2>&1 && crontab -u "$user" -l > "$tmp/old-cron" 2>/dev/null; then 

        sed '/^# D42_/d; /d42_linuxagent_x64_/d' "$tmp/old-cron" > "$tmp/clean-cron" 

        crontab -u "$user" "$tmp/clean-cron" 

    fi 

done 

  

echo "[*] Installing $cron_file..." 

install -o root -g root -m 0644 "$tmp/schedule" "$cron_file" 

  

# Verify installed files and exact schedule content. 

test -x "$dir/d42_linuxagent_x64_drc2" 

test -x "$dir/d42_linuxagent_x64_prc2" 

test -s "$cron_file" 

cmp -s "$tmp/schedule" "$cron_file" 

systemctl is-active --quiet cron 

  

cat "$cron_file" 

echo "[OK] Both agents installed; cron schedule verified and cron is running." 

 

echo "[*] Running initial Device42 scans..." 

scan_failed=0 

  

for env in dev prod; do 

    if [[ $env == dev ]]; then 

        suffix=drc2 

    else 

        suffix=prc2 

    fi 

  

    echo "[*] Running $env agent..." 

  

    if /usr/bin/flock -n -E 200 "/run/d42-$env.lock" "$dir/d42_linuxagent_x64_$suffix" -quiet -discover-last-login -ignore-ipv6 -hostname-precedence -device-name-format 3 -ignore-domain -skip-virtual-machines -new-device-object-category "EUC" -device-tags "EUC_ubuntu" >> "/var/log/d42_agent_$env.log" 2>&1; then 

        echo "[OK] $env agent completed." 

    else 

        rc=$? 

        if [[ $rc -eq 200 ]]; then 

            echo "[SKIP] $env agent is already running." 

        else 

            echo "[ERROR] $env agent exited with code $rc." 

            tail -n 30 "/var/log/d42_agent_$env.log" 

            scan_failed=1 

        fi 

    fi 

done 

  

exit "$scan_failed" 
