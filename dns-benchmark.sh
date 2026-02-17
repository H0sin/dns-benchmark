#!/usr/bin/env bash
#
# DNS Benchmark Script for MarzG Nodes
# Run on each node server to find the best DNS for that region
#
# Usage: bash dns-benchmark.sh
#        bash dns-benchmark.sh --json    (JSON output for copy-paste)
#

set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ─── DNS Servers to Test ─────────────────────────────────────────────
declare -A DNS_SERVERS=(
    # Global
    ["8.8.8.8"]="Google Primary"
    ["8.8.4.4"]="Google Secondary"
    ["1.1.1.1"]="Cloudflare Primary"
    ["1.0.0.1"]="Cloudflare Secondary"
    ["9.9.9.9"]="Quad9 Primary"
    ["149.112.112.112"]="Quad9 Secondary"
    ["208.67.222.222"]="OpenDNS Primary"
    ["208.67.220.220"]="OpenDNS Secondary"

    # Europe
    ["185.228.168.9"]="CleanBrowsing EU"
    ["80.80.80.80"]="Freenom EU (NL)"
    ["80.80.81.81"]="Freenom EU2 (NL)"
    ["195.46.39.39"]="SafeDNS EU"
    ["195.46.39.40"]="SafeDNS EU2"

    # Middle East / Turkey
    ["76.76.2.0"]="ControlD Primary"
    ["76.76.10.0"]="ControlD Secondary"
    ["94.140.14.14"]="AdGuard Primary"
    ["94.140.15.15"]="AdGuard Secondary"

    # Asia
    ["119.29.29.29"]="DNSPod (CN)"
    ["223.5.5.5"]="AliDNS (CN)"
    ["168.95.1.1"]="HiNet (TW)"
    ["101.101.101.101"]="TWNIC (TW)"

    # Americas
    ["64.6.64.6"]="Verisign Primary"
    ["64.6.65.6"]="Verisign Secondary"
    ["185.228.168.168"]="CleanBrowsing US"
    ["76.76.19.19"]="Alternate DNS"
)

# Test domains (mix of popular + CDN)
TEST_DOMAINS=(
    "google.com"
    "cloudflare.com"
    "youtube.com"
    "facebook.com"
    "amazon.com"
)

ROUNDS=3           # queries per domain per DNS
TIMEOUT=2           # seconds
JSON_MODE=false

[[ "${1:-}" == "--json" ]] && JSON_MODE=true

# ─── Detect server location ─────────────────────────────────────────
detect_location() {
    local info
    info=$(curl -s --max-time 5 "http://ip-api.com/json/?fields=query,country,countryCode,regionName,city,isp,as" 2>/dev/null || echo '{}')

    SERVER_IP=$(echo "$info" | grep -oP '"query"\s*:\s*"\K[^"]+' 2>/dev/null || echo "unknown")
    SERVER_COUNTRY=$(echo "$info" | grep -oP '"country"\s*:\s*"\K[^"]+' 2>/dev/null || echo "unknown")
    SERVER_CC=$(echo "$info" | grep -oP '"countryCode"\s*:\s*"\K[^"]+' 2>/dev/null || echo "??")
    SERVER_CITY=$(echo "$info" | grep -oP '"city"\s*:\s*"\K[^"]+' 2>/dev/null || echo "unknown")
    SERVER_ISP=$(echo "$info" | grep -oP '"isp"\s*:\s*"\K[^"]+' 2>/dev/null || echo "unknown")
    SERVER_AS=$(echo "$info" | grep -oP '"as"\s*:\s*"\K[^"]+' 2>/dev/null || echo "unknown")

    # Detect region for recommendation
    case "$SERVER_CC" in
        DE|NL|FR|GB|SE|PL|ES|IT|RU|UA|RO|CZ|AT|CH|DK|NO|FI|BE|PT|IE|HU|BG|HR|SK|SI|LT|LV|EE|LU|MT|CY|IS|AL|BA|ME|MK|RS|XK)
            SERVER_REGION="europe" ;;
        AE|SA|QA|BH|OM|KW|IQ|JO|LB|TR|IR|PK|AF|EG|IL|PS|SY|YE)
            SERVER_REGION="middle_east" ;;
        JP|KR|SG|AU|HK|TW|TH|MY|ID|PH|VN|IN|BD|LK|NP|MM|KH|LA|MN|NZ)
            SERVER_REGION="asia" ;;
        US|CA|BR|MX|AR|CL|CO|PE|VE|EC|BO|PY|UY|CR|PA|DO|CU|GT|HN|SV|NI)
            SERVER_REGION="americas" ;;
        *)
            SERVER_REGION="global" ;;
    esac
}

# ─── DNS query timing ───────────────────────────────────────────────
query_dns() {
    local dns_server="$1"
    local domain="$2"
    local result

    # Try dig first, fallback to nslookup
    if command -v dig &>/dev/null; then
        result=$(dig "@${dns_server}" "$domain" +noall +stats +time="$TIMEOUT" +tries=1 2>/dev/null \
            | grep "Query time" | awk '{print $4}')
    elif command -v nslookup &>/dev/null; then
        local start end
        start=$(date +%s%N)
        nslookup "$domain" "$dns_server" >/dev/null 2>&1 && {
            end=$(date +%s%N)
            result=$(( (end - start) / 1000000 ))
        } || result=""
    else
        echo ""
        return
    fi

    echo "${result:-}"
}

# ─── Benchmark a single DNS server ──────────────────────────────────
benchmark_dns() {
    local dns_ip="$1"
    local total=0
    local count=0
    local failures=0
    local min=999999
    local max=0

    for domain in "${TEST_DOMAINS[@]}"; do
        for ((r=1; r<=ROUNDS; r++)); do
            local ms
            ms=$(query_dns "$dns_ip" "$domain")
            if [[ -n "$ms" && "$ms" =~ ^[0-9]+$ ]]; then
                total=$((total + ms))
                count=$((count + 1))
                ((ms < min)) && min=$ms
                ((ms > max)) && max=$ms
            else
                failures=$((failures + 1))
            fi
        done
    done

    if ((count > 0)); then
        local avg=$((total / count))
        echo "${avg}|${min}|${max}|${count}|${failures}"
    else
        echo "9999|9999|9999|0|$((ROUNDS * ${#TEST_DOMAINS[@]}))"
    fi
}

# ─── Main ────────────────────────────────────────────────────────────

# Check dependencies
if ! command -v dig &>/dev/null && ! command -v nslookup &>/dev/null; then
    echo -e "${RED}Error: Neither 'dig' nor 'nslookup' found.${NC}"
    echo "Install with: apt install dnsutils  OR  yum install bind-utils"
    exit 1
fi

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║         🌐  MarzG DNS Benchmark Tool  🌐               ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# Detect location
echo -e "${DIM}Detecting server location...${NC}"
detect_location

echo -e "${CYAN}┌��────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│${NC} ${BOLD}Server Info${NC}                              ${CYAN}│${NC}"
echo -e "${CYAN}├─────────────────────────────────────────┤${NC}"
echo -e "${CYAN}│${NC}  IP:       ${GREEN}${SERVER_IP}${NC}"
echo -e "${CYAN}│${NC}  Location: ${GREEN}${SERVER_CITY}, ${SERVER_COUNTRY} (${SERVER_CC})${NC}"
echo -e "${CYAN}│${NC}  ISP:      ${GREEN}${SERVER_ISP}${NC}"
echo -e "${CYAN}│${NC}  AS:       ${GREEN}${SERVER_AS}${NC}"
echo -e "${CYAN}│${NC}  Region:   ${YELLOW}${SERVER_REGION}${NC}"
echo -e "${CYAN}└─────────────────────────────────────────┘${NC}"
echo ""

total_dns=${#DNS_SERVERS[@]}
echo -e "${BOLD}Testing ${total_dns} DNS servers × ${#TEST_DOMAINS[@]} domains × ${ROUNDS} rounds...${NC}"
echo -e "${DIM}(timeout: ${TIMEOUT}s per query)${NC}"
echo ""

# Run benchmarks
declare -A RESULTS
current=0

for dns_ip in "${!DNS_SERVERS[@]}"; do
    current=$((current + 1))
    printf "\r  [%d/%d] Testing %-18s %-25s" "$current" "$total_dns" "$dns_ip" "${DNS_SERVERS[$dns_ip]}"
    RESULTS["$dns_ip"]=$(benchmark_dns "$dns_ip")
done
echo ""
echo ""

# Sort results by average latency
echo -e "${BOLD}═══════════════════════════════════════════════════════════════════════════════${NC}"
printf "${BOLD}%-4s  %-18s  %-22s  %6s  %6s  %6s  %5s  %s${NC}\n" \
    "Rank" "DNS Server" "Name" "Avg" "Min" "Max" "Fail" "Rating"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════════════════════${NC}"

# Sort by average latency
sorted_dns=()
while IFS= read -r line; do
    sorted_dns+=("$line")
done < <(
    for dns_ip in "${!DNS_SERVERS[@]}"; do
        avg=$(echo "${RESULTS[$dns_ip]}" | cut -d'|' -f1)
        echo "${avg}|${dns_ip}"
    done | sort -t'|' -k1 -n
)

rank=0
best_dns=""
best_avg=9999
json_results=()

for entry in "${sorted_dns[@]}"; do
    rank=$((rank + 1))
    avg=$(echo "$entry" | cut -d'|' -f1)
    dns_ip=$(echo "$entry" | cut -d'|' -f2)
    result="${RESULTS[$dns_ip]}"

    min=$(echo "$result" | cut -d'|' -f2)
    max=$(echo "$result" | cut -d'|' -f3)
    ok=$(echo "$result" | cut -d'|' -f4)
    fail=$(echo "$result" | cut -d'|' -f5)
    name="${DNS_SERVERS[$dns_ip]}"

    # Rating
    if ((avg < 10)); then
        rating="${GREEN}★★★★★ EXCELLENT${NC}"
    elif ((avg < 30)); then
        rating="${GREEN}★★★★☆ GREAT${NC}"
    elif ((avg < 60)); then
        rating="${YELLOW}★★★☆☆ GOOD${NC}"
    elif ((avg < 100)); then
        rating="${YELLOW}★★☆☆☆ OK${NC}"
    elif ((avg < 9999)); then
        rating="${RED}★☆☆☆☆ SLOW${NC}"
    else
        rating="${RED}✗ FAILED${NC}"
    fi

    # Highlight top 3
    if ((rank <= 3)); then
        color="${GREEN}"
    elif ((avg >= 9999)); then
        color="${RED}"
    else
        color="${NC}"
    fi

    printf "${color}%-4s  %-18s  %-22s  %4sms  %4sms  %4sms  %3s/%d  ${NC}" \
        "#${rank}" "$dns_ip" "$name" "$avg" "$min" "$max" "$fail" "$((ROUNDS * ${#TEST_DOMAINS[@]}))"
    echo -e "  $rating"

    # Track best
    if ((rank == 1)) && ((avg < 9999)); then
        best_dns="$dns_ip"
        best_avg="$avg"
    fi

    # JSON output
    json_results+=("    {\"dns\": \"${dns_ip}\", \"name\": \"${name}\", \"avg_ms\": ${avg}, \"min_ms\": ${min}, \"max_ms\": ${max}, \"failures\": ${fail}}")
done

echo -e "${BOLD}═══════════════════════════════════════════════════════════════════════════════${NC}"

# Top 3 recommendation
echo ""
echo -e "${BOLD}🏆 RECOMMENDED DNS for this node (${SERVER_CITY}, ${SERVER_CC} — ${SERVER_REGION}):${NC}"
echo ""

top_count=0
rec_dns=()
for entry in "${sorted_dns[@]}"; do
    top_count=$((top_count + 1))
    ((top_count > 3)) && break

    avg=$(echo "$entry" | cut -d'|' -f1)
    ((avg >= 9999)) && continue

    dns_ip=$(echo "$entry" | cut -d'|' -f2)
    name="${DNS_SERVERS[$dns_ip]}"
    rec_dns+=("$dns_ip")

    case $top_count in
        1) medal="🥇" ;;
        2) medal="🥈" ;;
        3) medal="🥉" ;;
    esac

    echo -e "  ${medal}  ${GREEN}${dns_ip}${NC}  (${name}) — ${avg}ms avg"
done

echo ""
echo -e "${CYAN}┌───────────────────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│${NC} ${BOLD}📋 Copy-paste for MarzG Balancer Endpoint:${NC}               ${CYAN}│${NC}"
echo -e "${CYAN}├───────────────────────────────────────────────────────────┤${NC}"
echo -e "${CYAN}│${NC}                                                           ${CYAN}│${NC}"
echo -e "${CYAN}│${NC}  Server:  ${GREEN}${SERVER_IP}${NC} (${SERVER_CITY}, ${SERVER_CC})"
echo -e "${CYAN}│${NC}  Region:  ${YELLOW}${SERVER_REGION}${NC}"
echo -e "${CYAN}│${NC}                                                           ${CYAN}│${NC}"
echo -e "${CYAN}│${NC}  ${BOLD}Primary DNS:${NC}    ${GREEN}${rec_dns[0]:-N/A}${NC}"
echo -e "${CYAN}│${NC}  ${BOLD}Secondary DNS:${NC}  ${GREEN}${rec_dns[1]:-N/A}${NC}"
echo -e "${CYAN}│${NC}  ${BOLD}Tertiary DNS:${NC}   ${GREEN}${rec_dns[2]:-N/A}${NC}"
echo -e "${CYAN}│${NC}                                                           ${CYAN}│${NC}"
echo -e "${CYAN}└───────────────────────────────────────────────────────────┘${NC}"
echo ""

# JSON output mode
if $JSON_MODE; then
    echo ""
    echo -e "${BOLD}📄 JSON Output:${NC}"
    echo ""
    echo "{"
    echo "  \"server_ip\": \"${SERVER_IP}\","
    echo "  \"server_location\": \"${SERVER_CITY}, ${SERVER_COUNTRY}\","
    echo "  \"server_country_code\": \"${SERVER_CC}\","
    echo "  \"server_region\": \"${SERVER_REGION}\","
    echo "  \"recommended_dns\": ["
    for i in "${!rec_dns[@]}"; do
        comma=","
        ((i == ${#rec_dns[@]} - 1)) && comma=""
        echo "    \"${rec_dns[$i]}\"${comma}"
    done
    echo "  ],"
    echo "  \"results\": ["
    for i in "${!json_results[@]}"; do
        comma=","
        ((i == ${#json_results[@]} - 1)) && comma=""
        echo "${json_results[$i]}${comma}"
    done
    echo "  ]"
    echo "}"
fi

echo ""
echo -e "${DIM}Done! Run on each node server to find the best DNS per region.${NC}"
echo -e "${DIM}Tip: Use --json flag for machine-readable output.${NC}"
echo ""
