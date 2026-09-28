#!/usr/bin/env bash
# ===================================================================
#  install.sh - Cai dat VPS chay website HTML tinh (Nginx + SFTP)
#  Ho tro: Ubuntu 20.04 / 22.04 / 24.04, Debian 11 / 12 (can systemd)
#  CHI chay tren VPS MOI CAI he dieu hanh:  bash install.sh
#
#  Trinh tu: KIEM TRA toan bo truoc -> chi khi dat moi thay doi he thong.
#  Chay lai nhieu lan van an toan. Thong so: /etc/vhost/vhost.conf
# ===================================================================
set -Eeuo pipefail
umask 022
export LC_ALL=C.UTF-8

VHOST_BIN="/usr/local/bin/vhost"
LOG="/var/log/vhost-install.log"
CURRENT_STEP="khoi dong"
TMP_BIN=""

step() { CURRENT_STEP="$*"; echo; echo "==> $*"; }
warn() { echo "   [CANH BAO] $*"; }
die()  { echo; echo "!!! LOI: $*"; echo "    Log day du: $LOG"; exit 1; }
cleanup() { [[ -n "$TMP_BIN" ]] && rm -f "$TMP_BIN"; }
trap cleanup EXIT
trap 'die "Buoc \"$CURRENT_STEP\" that bai tai dong $LINENO: $BASH_COMMAND"' ERR

[[ $EUID -eq 0 ]] || { echo "Vui long chay bang root: sudo bash install.sh"; exit 1; }
[[ -d /run/systemd/system ]] || { echo "He thong khong chay systemd - khong ho tro."; exit 1; }
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}-${VERSION_ID:-}" in
  ubuntu-20.04|ubuntu-22.04|ubuntu-24.04|debian-11|debian-12) ;;
  *) echo "He dieu hanh chua duoc ho tro: ${PRETTY_NAME:-khong ro}"; exit 1 ;;
esac

exec > >(tee -a "$LOG") 2>&1
TEE_PID=$!
echo "===== $(date -Iseconds) - $PRETTY_NAME ====="

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
APT_OPTS=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o DPkg::Lock::Timeout=900)

# Ban vhost di kem script: dung ban tam de doc cau hinh, CHUA cai vao he thong
TMP_BIN=$(mktemp)
cat > "$TMP_BIN" <<'VHOSTEOF'
#!/usr/bin/env bash
# ===================================================================
#  vhost - Quan ly website HTML tinh tren Nginx (moi website 1 tai khoan SFTP)
#
#  vhost                      Mo menu
#  vhost add|ssl|passwd|del <domain>
#  vhost list | status
#  vhost config               Sua cau hinh he thong roi ap dung
#  vhost apply                Ap dung /etc/vhost/vhost.conf
#  vhost get <KHOA>           In gia tri mot tuy chon
# ===================================================================
set -uo pipefail
umask 022
export LC_ALL=C.UTF-8

readonly CONF_DIR="/etc/vhost"
readonly CONF_FILE="$CONF_DIR/vhost.conf"
readonly STATE_DIR="$CONF_DIR/sites"
readonly UFW_STATE="$CONF_DIR/ufw-rules"
readonly LOCK_FILE="/run/vhost.lock"
readonly NGX="/etc/nginx"
readonly NGX_AVAIL="$NGX/sites-available"
readonly NGX_ENABLED="$NGX/sites-enabled"
readonly NGX_VHOST="$NGX/vhost"
readonly NGX_SITE_EXTRA="$NGX/vhost.d"
readonly NGX_CF="$NGX/conf.d/vhost-cloudflare.conf"
readonly NGX_MAIN_ERRLOG="/var/log/nginx/error.log"
readonly SSHD_CFG="/etc/ssh/sshd_config"
readonly SSHD_DROPIN="/etc/ssh/sshd_config.d/00-vhost-hardening.conf"
readonly CRON_CF="/etc/cron.d/vhost-cloudflare"
readonly JOURNAL_DROPIN="/etc/systemd/journald.conf.d/99-vhost.conf"
readonly USER_PREFIX="w_"
readonly EXIT_LOCKED=75


# ===================================================================
#  TUY CHON CAU HINH: ten | mac dinh | kiem tra hop le | ghi chu
#  Bo kiem tra khong cho phep ky tu ; { } " ' \ $ nen khong the chen lenh.
# ===================================================================
declare -A DEF=() VAL=() CMT=() C=()
ORDER=()
spec()    { ORDER+=("$1"); DEF[$1]="$2"; VAL[$1]="$3"; CMT[$1]="${4:-}"; }
section() { ORDER+=("#$1"); }
YN='^(yes|no)$'
DUR='^[0-9]+[smhdw]?$'

section "WEBSITE & TAI KHOAN"
spec WEB_ROOT        "/var/www"   '^/[A-Za-z0-9._/-]*[A-Za-z0-9_-]$' "Thu muc chua website (chi ap dung cho website tao moi)"
spec SFTP_GROUP      "sftpusers"  '^[a-z_][a-z0-9_-]{0,30}$'          "Nhom he thong cua tai khoan SFTP (chi ap dung cho website tao moi)"
spec SFTP_UMASK      "0027"       '^0[0-7]{3}$'                        "Umask file upload qua SFTP. 0027 = nginx doc duoc, user khac khong doc duoc"
spec MAX_SITES       "0"          '^[0-9]+$'                           "So website toi da. 0 = khong gioi han"
spec SERVER_ALIASES  "www"        '^([a-z0-9-]+( [a-z0-9-]+)*)?$'      "Ten mien phu tu dong them cho website moi (vd: www). De trong = khong them"
spec INDEX_FILES     "index.html index.htm" '^[A-Za-z0-9._-]+( [A-Za-z0-9._-]+)*$' "File trang chu"
spec LISTEN_IPV6     "auto"       '^(auto|yes|no)$'                    "Lang nghe IPv6. auto = tu phat hien"

section "NGINX - HIEU NANG"
spec NGINX_WORKER_PROCESSES   "auto" '^(auto|[1-9][0-9]*)$' "auto = bang so CPU"
spec NGINX_WORKER_CONNECTIONS "1024" '^[1-9][0-9]*$'        "So ket noi dong thoi moi worker"
spec KEEPALIVE_TIMEOUT        "15s"  "$DUR"                  ""
spec GZIP                     "yes"  "$YN"                   "Nen du lieu gui ve trinh duyet"
spec GZIP_LEVEL               "5"    '^[1-9]$'               "1 (nhe CPU) - 9 (nen manh)"
spec STATIC_EXTENSIONS "css js mjs json xml txt jpg jpeg png gif webp avif ico svg woff woff2 ttf otf eot mp4 webm pdf" '^([a-z0-9]+( [a-z0-9]+)*)?$' "Duoi file tinh duoc cache tren trinh duyet"
spec STATIC_CACHE             "30d"  '^(off|[0-9]+[smhdwMy])$' "Thoi gian cache file tinh. off = tat"

section "NGINX - BAO MAT"
spec BLOCK_UNKNOWN_HOST "yes" "$YN" "Ngat ket noi khi truy cap bang IP hoac domain khong co tren VPS"
spec BLOCK_HIDDEN_FILES "yes" "$YN" "Chan file/thu muc an (.env, .git, .htpasswd...)"
spec BLOCKED_EXTENSIONS "php phtml phar env ini log sql sqlite db bak old orig save swp tmp conf cfg yml yaml sh py pl rb md zip tar gz tgz bz2 rar 7z" '^([a-z0-9]+( [a-z0-9]+)*)?$' "Duoi file bi chan truy cap. De trong = khong chan"
spec ALLOWED_METHODS    "GET HEAD" '^[A-Z]+( [A-Z]+)*$' "HTTP method duoc phep. File tinh luon chi nhan GET/HEAD; method khac chi co tac dung voi cau hinh rieng trong vhost.d"
spec DISABLE_SYMLINKS   "yes" "$YN" "Khong theo symlink tro toi file cua nguoi khac"
spec CLIENT_MAX_BODY_SIZE "1m"  '^[0-9]+[kKmMgG]?$' "Kich thuoc request toi da"
spec CLIENT_TIMEOUT       "10s" "$DUR"                "Timeout doc request (chong slowloris)"
spec RATE_LIMIT  "30r/s" '^(off|[1-9][0-9]*r/[sm])$' "Gioi han request moi IP. off = tat. Luu y: mang di dong VN (CGNAT) nhieu nguoi dung chung 1 IP - dung dat qua thap"
spec RATE_BURST  "300"   '^[0-9]+$'                  "So request vuot muc duoc phuc vu ngay (1 trang landing ~20-60 request)"
spec CONN_LIMIT  "100"   '^[0-9]+$'                  "So ket noi dong thoi moi IP. 0 = tat"
spec TLS_PROTOCOLS "TLSv1.2 TLSv1.3" '^TLSv1(\.[0-3])?( TLSv1(\.[0-3])?)*$' "Cho server mac dinh (site da cai SSL dung cau hinh TLS cua Certbot: TLS 1.2+)"
spec HSTS_MAX_AGE  "0"   '^[0-9]+$' "Giay. 0 = tat. CHI bat khi TAT CA website deu da co SSL va se giu SSL lau dai"
spec FRAME_OPTIONS "SAMEORIGIN" '^(|DENY|SAMEORIGIN)$' "Chong nhung trang vao iframe. De trong = tat"
spec REFERRER_POLICY "strict-origin-when-cross-origin" '^[a-z-]*$' "De trong = tat"
spec PERMISSIONS_POLICY "camera=(), microphone=(), geolocation=(), payment=()" '^[A-Za-z0-9=(), *.:/_-]*$' "De trong = tat"
spec CLOUDFLARE_REAL_IP "yes" "$YN" "Lay IP that cua khach khi dung Cloudflare proxy (tu cap nhat danh sach IP hang tuan)"

section "SSL (LET'S ENCRYPT)"
spec SSL_EMAIL    ""    '^([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})?$' "Email dang ky (khong bat buoc)"
spec SSL_REDIRECT "yes" "$YN" "Tu chuyen HTTP sang HTTPS"

section "SSH / SFTP"
spec SSH_DISABLE_ROOT_PASSWORD "auto" '^(auto|yes|no)$' "Chan root dang nhap bang mat khau. auto = chi chan khi root co SSH key hop le VA da tung dang nhap thanh cong bang key. yes = chan neu co key hop le. no = khong chan"
spec SSH_MAX_AUTH_TRIES   "3"  '^[1-9][0-9]?$' "So lan thu mat khau moi ket noi"
spec SSH_LOGIN_GRACE_TIME "30" "$DUR"          "Thoi gian toi da de dang nhap"

section "FAIL2BAN"
spec F2B_ENABLED          "yes" "$YN" "Chan IP do mat khau SSH/SFTP"
spec F2B_BANTIME          "1h"  "$DUR" "Thoi gian chan"
spec F2B_FINDTIME         "10m" "$DUR" "Khoang thoi gian dem so lan sai"
spec F2B_MAXRETRY         "5"   '^[1-9][0-9]*$' "So lan sai mat khau SSH/SFTP truoc khi bi chan"
spec F2B_RECIDIVE_BANTIME "1w"  "$DUR" "Thoi gian chan IP tai pham nhieu lan"
spec F2B_WEB_ENABLED      "no"  "$YN" "Chan IP vuot gioi han toc do web. Mac dinh TAT vi mang di dong VN (CGNAT) dung chung IP -> co the chan nham ca tram khach that"
spec F2B_WEB_MAXRETRY     "50"  '^[1-9][0-9]*$' "So lan vuot gioi han toc do web truoc khi bi chan"
spec F2B_IGNORE_IP        ""    '^([0-9a-fA-F:./]+( [0-9a-fA-F:./]+)*)?$' "IP khong bao gio bi chan (vd IP nha/cong ty), cach nhau dau cach"

section "HE THONG"
spec FIREWALL              "yes" "$YN" "Bat tuong lua UFW (vhost quan ly cac rule co ghi chu 'vhost')"
spec EXTRA_TCP_PORTS       ""    '^([0-9]+( [0-9]+)*)?$' "Port TCP mo them ngoai SSH/80/443"
spec AUTO_SECURITY_UPDATES "yes" "$YN" "Tu dong cai ban va bao mat"
spec JOURNAL_MAX_USE       "200M" '^(|[1-9][0-9]*[KMG])$' "Dung luong toi da log he thong (journald). De trong = mac dinh cua he thong"
spec MIN_FREE_DISK_MB      "1024" '^[0-9]+$' "Dung luong trong toi thieu (MB) phai con lai sau khi tao swap, kiem tra truoc khi cai dat"
spec SWAP_SIZE             "auto" '^(auto|0|[1-9][0-9]*[MG])$' "Chi dung khi chay install.sh. auto = bang RAM neu RAM <= 2GB. Swap bi thu nho/bo qua neu khong du MIN_FREE_DISK_MB"
spec SWAPPINESS            "10"  '^([0-9]|[1-9][0-9]|100)$' "0-100"

# ===================================================================
#  Doc / ghi cau hinh
# ===================================================================
CONFIG_ERRORS=""

load_config() {
  local k line key val n=0
  for k in "${!DEF[@]}"; do C[$k]="${DEF[$k]}"; done
  CONFIG_ERRORS=""
  [[ -f "$CONF_FILE" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ ! "$line" =~ ^[[:space:]]*([A-Z0-9_]+)[[:space:]]*=(.*)$ ]]; then
      CONFIG_ERRORS+="Dong $n: sai cu phap (dung dang KHOA=\"gia tri\")\n"; continue
    fi
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    if [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
    if [[ -z "${DEF[$key]+x}" ]]; then
      CONFIG_ERRORS+="Dong $n: khong co tuy chon ten '$key'\n"; continue
    fi
    if [[ ! "$val" =~ ${VAL[$key]} ]]; then
      CONFIG_ERRORS+="Dong $n: gia tri khong hop le cho $key: \"$val\"\n"; continue
    fi
    if [[ "$key" == "WEB_ROOT" && ( "/$val/" == *"/../"* || "/$val/" == *"/./"* || "$val" == *"//"* ) ]]; then
      CONFIG_ERRORS+="Dong $n: WEB_ROOT khong duoc chua '.', '..' hoac '//'\n"; continue
    fi
    C[$key]="$val"
  done < "$CONF_FILE"
  [[ -z "$CONFIG_ERRORS" ]]
}

write_config() {
  local tmp k
  mkdir -p "$CONF_DIR" && chmod 700 "$CONF_DIR" || return 1
  tmp=$(mktemp "$CONF_DIR/.vhost.conf.XXXXXX") || return 1
  {
    echo "# ================================================================="
    echo "#  Cau hinh he thong vhost. Sua xong chay:  vhost apply"
    echo "#  (hoac: vhost config  /  menu -> Cau hinh he thong)"
    echo "#  Gia tri sai bi tu choi; cau hinh lam hong dich vu se tu hoan tac."
    echo "# ================================================================="
    for k in "${ORDER[@]}"; do
      if [[ "$k" == \#* ]]; then printf '\n# ---------------- %s ----------------\n' "${k#\#}"; continue; fi
      [[ -n "${CMT[$k]}" ]] && printf '# %s\n' "${CMT[$k]}"
      printf '%s="%s"\n' "$k" "${C[$k]}"
    done
  } > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$CONF_FILE"
}

on() { [[ "${C[$1]}" == "yes" ]]; }

# "a b c" -> "a|b|c" (khong qua word-splitting/glob)
alt() {
  local -a w
  read -r -a w <<< "${C[$1]}"
  local IFS='|'
  printf '%s' "${w[*]}"
}

ipv6_enabled() {
  case "${C[LISTEN_IPV6]}" in
    yes) return 0 ;; no) return 1 ;;
    *) [[ -f /proc/net/if_inet6 ]] ;;
  esac
}

# ===================================================================
#  Tien ich chung
# ===================================================================
say() { printf '%b\n' "$1"; }

APPLY_LOG=""
log() { APPLY_LOG+="$1\n"; printf '  %b\n' "$1"; }

ASSUME_YES=0
confirm() {
  (( ASSUME_YES )) && return 0
  local a
  if [[ ! -t 0 ]]; then
    printf '%b\n-> Can xac nhan: chay trong terminal hoac them --yes. Da huy.\n' "$1" >&2
    return 1
  fi
  printf '%b\n' "$1"
  read -r -p "Dong y? [y/N]: " a
  [[ "$a" =~ ^[yY]$ ]]
}

# Khoi dong lai / nap lai dich vu va XAC NHAN no dang chay
svc_reload() {
  local u="$1"
  if systemctl is-active --quiet "$u"; then
    systemctl reload "$u" || return 1
  else
    systemctl restart "$u" || return 1
  fi
  sleep 1
  systemctl is-active --quiet "$u"
}

normalize_domain() {
  local d="$1"
  d="${d//[[:space:]]/}"
  d="${d#http://}"; d="${d#https://}"; d="${d#HTTP://}"; d="${d#HTTPS://}"
  d="${d%%/*}"
  if [[ "$d" == *[![:ascii:]]* ]]; then                # co ky tu ngoai ASCII -> ten mien tieng Viet
    command -v idn2 >/dev/null || { printf '%s' "$d"; return 1; }
    d=$(idn2 --quiet -- "$d" 2>/dev/null) || { printf '%s' "$1"; return 1; }
  fi
  d="${d,,}"
  d="${d#www.}"; d="${d%.}"
  printf '%s' "$d"
}

valid_domain() {
  [[ ${#1} -le 253 && "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+([a-z]{2,63}|xn--[a-z0-9-]{1,59})$ ]]
}

site_exists()  { valid_domain "$1" && [[ -f "$STATE_DIR/$1" ]]; }
list_domains() { local f; for f in "$STATE_DIR"/*; do [[ -f "$f" ]] && basename "$f"; done; }
site_count()   { local n=0 d; while IFS= read -r d; do [[ -n "$d" ]] && n=$((n + 1)); done < <(list_domains); echo "$n"; }
state_get()    { grep -m1 "^$2=" "$STATE_DIR/$1" 2>/dev/null | cut -d= -f2-; }

site_root() {
  local d="$1" r
  r=$(state_get "$d" ROOT)
  [[ "$r" =~ ^/[A-Za-z0-9._/-]+$ && "$r" == */"$d" && "/$r/" != *"/../"* ]] || return 1
  printf '%s' "$r"
}

gen_username() {
  local base hash
  base=$(printf '%s' "$1" | tr -c 'a-z0-9' '_' | cut -c1-20)
  hash=$(printf '%s' "$1" | sha256sum | cut -c1-6)
  printf '%s%s_%s' "$USER_PREFIX" "$base" "$hash"
}

gen_password() {
  local p=""
  while (( ${#p} < 20 )); do
    p+=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')
  done
  printf '%s' "${p:0:20}"
}

primary_ip() { curl -fsS -4 --max-time 4 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}'; }

server_ips() {
  { hostname -I 2>/dev/null | tr ' ' '\n'
    curl -fsS -4 --max-time 4 https://api.ipify.org 2>/dev/null; echo
    curl -fsS -6 --max-time 4 https://api64.ipify.org 2>/dev/null; echo
  } | grep -v '^$' | sort -u
}

resolve_ips() { getent ahosts "$1" 2>/dev/null | awk '{print $1}' | sort -u; }

# Moi cong SSH thuc su dang dung: tu sshd_config, tu ssh.socket (Ubuntu 22.10+), va tu socket dang lang nghe
ssh_ports() {
  {
    sshd -T 2>/dev/null | awk '/^port /{print $2}'
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
      systemctl show -p Listen --value ssh.socket 2>/dev/null | grep -oE '[0-9]+ \(Stream\)' | awk '{print $1}'
    fi
    ss -ltnpH 2>/dev/null | awk '/"sshd"/{n=split($4,a,":"); print a[n]}'
  } | grep -E '^[0-9]+$' | sort -un
}

# Cac file authorized_keys cua root theo dung cau hinh sshd
root_key_files() {
  local f
  sshd -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null | awk '/^authorizedkeysfile /{for(i=2;i<=NF;i++)print $i}' |
  while IFS= read -r f; do
    f="${f//%h//root}"; f="${f//%u/root}"; f="${f//%%/%}"
    [[ "$f" == /* ]] || f="/root/$f"
    printf '%s\n' "$f"
  done
}

root_has_valid_key() {
  local f
  while IFS= read -r f; do
    [[ -s "$f" ]] && ssh-keygen -l -f "$f" >/dev/null 2>&1 && return 0
  done < <(root_key_files)
  return 1
}

# Bang chung root da THUC SU dang nhap thanh cong bang key (khong chi la co key do nha cung cap cai san)
root_key_login_seen() {
  # grep -c doc HET du lieu (grep -q thoat som -> SIGPIPE -> sai ket qua duoi pipefail)
  local n
  n=$({
    journalctl -q --no-pager -o cat -u ssh.service -u sshd.service 2>/dev/null
    zcat -f /var/log/auth.log* 2>/dev/null
  } | grep -cE 'Accepted publickey for root from')
  (( ${n:-0} > 0 ))
}

# sshd co ap dung chroot cho user nay khong (lay het output roi moi so khop)
user_is_chrooted() {
  local out
  out=$(sshd -T -C "user=$1,host=localhost,addr=127.0.0.1" 2>/dev/null) || return 1
  [[ $'\n'"$out"$'\n' == *$'\n'"chrootdirectory %h"$'\n'* ]]
}

nginx_test_and_reload() {
  local out
  out=$(nginx -t 2>&1) || { printf '%s\n' "$out" >&2; return 1; }
  svc_reload nginx || { echo "nginx khong nap lai duoc (xem: journalctl -u nginx)" >&2; return 1; }
}

# sshd yeu cau moi thu muc tren duong dan chroot thuoc root va khong ai khac ghi duoc
chroot_path_ok() {
  local -a parts
  local cur="" part mode
  IFS='/' read -r -a parts <<< "$1"
  for part in "${parts[@]}"; do
    [[ -z "$part" ]] && continue
    cur+="/$part"
    [[ -d "$cur" ]] || continue
    [[ "$(stat -c %u "$cur")" == 0 ]] || return 1
    mode=$(stat -c %a "$cur")
    (( (8#$mode & 8#022) == 0 )) || return 1
  done
  [[ "$(stat -c %u /)" == 0 ]] && (( (8#$(stat -c %a /) & 8#022) == 0 ))
}

# ===================================================================
#  Sinh cau hinh Nginx
# ===================================================================
render_nginx_conf() {
  local wc="${C[NGINX_WORKER_CONNECTIONS]}"
  cat <<EOF
# FILE DO 'vhost apply' TAO - chinh sua truc tiep se bi ghi de.
# Thong so: /etc/vhost/vhost.conf
# Them cau hinh rieng: /etc/nginx/conf.d/*.conf (toan bo) hoac /etc/nginx/vhost.d/<domain>/*.conf (tung site)
user www-data;
worker_processes ${C[NGINX_WORKER_PROCESSES]};
worker_rlimit_nofile $((wc * 2));
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections $wc;
    multi_accept on;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    types_hash_max_size 2048;
    server_tokens off;

    client_max_body_size ${C[CLIENT_MAX_BODY_SIZE]};
    client_body_buffer_size 16k;
    client_header_buffer_size 1k;
    large_client_header_buffers 4 8k;
    client_body_timeout ${C[CLIENT_TIMEOUT]};
    client_header_timeout ${C[CLIENT_TIMEOUT]};
    send_timeout ${C[CLIENT_TIMEOUT]};
    keepalive_timeout ${C[KEEPALIVE_TIMEOUT]};
    reset_timedout_connection on;

    ssl_protocols ${C[TLS_PROTOCOLS]};

    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /var/log/nginx/access.log;
    error_log  $NGX_MAIN_ERRLOG warn;
EOF
  if [[ "${C[RATE_LIMIT]}" != "off" ]]; then
    printf '\n    limit_req_zone $binary_remote_addr zone=vhost_req:10m rate=%s;\n    limit_req_status 429;\n' "${C[RATE_LIMIT]}"
  fi
  if (( ${C[CONN_LIMIT]} > 0 )); then
    printf '    limit_conn_zone $binary_remote_addr zone=vhost_conn:10m;\n    limit_conn_status 429;\n'
  fi
  if on GZIP; then
    cat <<EOF

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level ${C[GZIP_LEVEL]};
    gzip_min_length 256;
    gzip_types text/plain text/css application/json application/javascript text/xml
               application/xml application/xml+rss text/javascript image/svg+xml;
EOF
  fi
  cat <<'EOF'

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF
}

render_site_common() {
  echo "# FILE DO 'vhost apply' TAO - dung chung cho moi website. Thong so: /etc/vhost/vhost.conf"
  echo "index ${C[INDEX_FILES]};"
  echo "charset utf-8;"
  echo 'add_header X-Content-Type-Options "nosniff" always;'
  [[ -n "${C[FRAME_OPTIONS]}" ]]      && echo "add_header X-Frame-Options \"${C[FRAME_OPTIONS]}\" always;"
  [[ -n "${C[REFERRER_POLICY]}" ]]    && echo "add_header Referrer-Policy \"${C[REFERRER_POLICY]}\" always;"
  [[ -n "${C[PERMISSIONS_POLICY]}" ]] && echo "add_header Permissions-Policy \"${C[PERMISSIONS_POLICY]}\" always;"
  (( ${C[HSTS_MAX_AGE]} > 0 ))        && echo "add_header Strict-Transport-Security \"max-age=${C[HSTS_MAX_AGE]}\" always;"
  on DISABLE_SYMLINKS && echo 'disable_symlinks if_not_owner from=$document_root;'
  [[ "${C[RATE_LIMIT]}" != "off" ]] && echo "limit_req zone=vhost_req burst=${C[RATE_BURST]} nodelay;"
  (( ${C[CONN_LIMIT]} > 0 )) && echo "limit_conn vhost_conn ${C[CONN_LIMIT]};"
  echo "if (\$request_method !~ ^($(alt ALLOWED_METHODS))\$) { return 405; }"
  cat <<'EOF'

location / {
    try_files $uri $uri/ =404;
}

location ^~ /.well-known/acme-challenge/ {
    default_type text/plain;
    try_files $uri =404;
}
EOF
  on BLOCK_HIDDEN_FILES && printf '\nlocation ~ /\\.(?!well-known/) { return 404; }\n'
  if [[ -n "${C[BLOCKED_EXTENSIONS]}" ]]; then
    printf '\nlocation ~* \\.(?:%s)$ { return 404; }\n' "$(alt BLOCKED_EXTENSIONS)"
  fi
  if [[ -n "${C[STATIC_EXTENSIONS]}" ]]; then
    printf '\nlocation ~* \\.(?:%s)$ {\n' "$(alt STATIC_EXTENSIONS)"
    [[ "${C[STATIC_CACHE]}" != "off" ]] && printf '    expires %s;\n' "${C[STATIC_CACHE]}"
    printf '    access_log off;\n    try_files $uri =404;\n}\n'
  fi
}

render_default_deny() {
  echo "# Ngat ket noi moi truy cap khong dung domain (bang IP, domain la)"
  echo "server {"
  echo "    listen 80 default_server;"
  echo "    listen 443 ssl default_server;"
  if ipv6_enabled; then
    # ipv6only=on khai bao o day -> Certbot se khong them lan nua (tranh loi duplicate listen)
    echo "    listen [::]:80 default_server ipv6only=on;"
    echo "    listen [::]:443 ssl default_server ipv6only=on;"
  fi
  cat <<'EOF'
    server_name _;
    ssl_certificate     /etc/ssl/certs/ssl-cert-snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;
    access_log off;
    return 444;
}
EOF
}

render_site_conf() {
  local domain="$1" root="$2" names="$3"
  echo "server {"
  echo "    listen 80;"
  ipv6_enabled && echo "    listen [::]:80;"
  cat <<EOF
    server_name $names;
    root $root;

    access_log /var/log/nginx/$domain.access.log;
    error_log  /var/log/nginx/$domain.error.log warn;
    error_log  $NGX_MAIN_ERRLOG warn;

    # Cau hinh chung (sinh tu /etc/vhost/vhost.conf)
    include $NGX_VHOST/site-common.conf;
    # Cau hinh rieng cho site nay (tuy chon)
    include $NGX_SITE_EXTRA/$domain/*.conf;
}
EOF
}

# Tai danh sach IP Cloudflare vao file tam; chi thanh cong khi du lieu hop le
cf_fetch() {
  local out="$1" t4 t6 n4 n6 rc=1
  t4=$(mktemp); t6=$(mktemp)
  if curl -fsS --max-time 15 https://www.cloudflare.com/ips-v4 -o "$t4" 2>/dev/null &&
     curl -fsS --max-time 15 https://www.cloudflare.com/ips-v6 -o "$t6" 2>/dev/null; then
    n4=$(grep -cE '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' "$t4")
    n6=$(grep -cE '^[0-9a-fA-F:]+/[0-9]{1,3}$' "$t6")
    if (( n4 >= 5 && n6 >= 3 )) && ! grep -qvE '^([0-9./]+|[0-9a-fA-F:/]+)?$' "$t4" "$t6"; then
      { echo "# IP Cloudflare - cap nhat $(date -Iseconds) boi vhost"
        grep -hE '^[0-9a-fA-F:.]+/[0-9]+$' "$t4" "$t6" | sed 's/^/set_real_ip_from /; s/$/;/'
        echo "real_ip_header CF-Connecting-IP;"; } > "$out"
      rc=0
    fi
  fi
  rm -f "$t4" "$t6"
  return $rc
}

# ===================================================================
#  Ap dung cau hinh (moi phan: sao luu -> ghi -> kiem tra -> nap lai; loi thi hoan tac)
# ===================================================================
# Sao luu/khoi phuc TUNG FILE (khong bao gio sao chep de len thu muc cha)
backup_files() {
  local bk="$1"; shift
  local f
  for f in "$@"; do
    if [[ -e "$f" || -L "$f" ]]; then
      mkdir -p "$bk$(dirname "$f")" && cp -a "$f" "$bk$f" || return 1
    fi
  done
}
restore_files() {
  local bk="$1"; shift
  local f
  for f in "$@"; do
    rm -f "$f"
    if [[ -e "$bk$f" || -L "$bk$f" ]]; then cp -a "$bk$f" "$f"; fi
  done
}

apply_nginx() {
  local bk err
  local files=("$NGX/nginx.conf" "$NGX_VHOST/site-common.conf" "$NGX_AVAIL/000-default-deny.conf"
               "$NGX_ENABLED/000-default-deny.conf" "$NGX_CF" "$CRON_CF")
  bk=$(mktemp -d)
  backup_files "$bk" "${files[@]}" || { rm -rf "$bk"; log "Nginx: LOI khong sao luu duoc, khong thay doi gi"; return 1; }

  mkdir -p "$NGX_VHOST" "$NGX_SITE_EXTRA"
  render_nginx_conf  > "$NGX/nginx.conf"
  render_site_common > "$NGX_VHOST/site-common.conf"
  rm -f "$NGX_ENABLED/default"

  if on BLOCK_UNKNOWN_HOST; then
    if [[ ! -f /etc/ssl/certs/ssl-cert-snakeoil.pem ]]; then
      make-ssl-cert generate-default-snakeoil --force-overwrite >/dev/null 2>&1
    fi
    render_default_deny > "$NGX_AVAIL/000-default-deny.conf"
    ln -sf "$NGX_AVAIL/000-default-deny.conf" "$NGX_ENABLED/000-default-deny.conf"
  else
    rm -f "$NGX_ENABLED/000-default-deny.conf" "$NGX_AVAIL/000-default-deny.conf"
  fi

  if on CLOUDFLARE_REAL_IP; then
    local t; t=$(mktemp)
    if cf_fetch "$t"; then
      cat "$t" > "$NGX_CF"; log "Cloudflare: da cap nhat danh sach IP"
    elif [[ -f "$NGX_CF" ]]; then
      log "Cloudflare: khong tai duoc danh sach moi, giu danh sach cu"
    else
      log "Cloudflare: khong tai duoc danh sach IP (se thu lai hang tuan)"
    fi
    rm -f "$t"
    printf '# Cap nhat IP Cloudflare hang tuan\nSHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n%d 4 * * 1 root /usr/local/bin/vhost cf-refresh >/dev/null 2>&1\n' $(( RANDOM % 60 )) > "$CRON_CF"
  else
    rm -f "$NGX_CF" "$CRON_CF"
  fi

  if err=$(nginx_test_and_reload 2>&1); then
    rm -rf "$bk"
    log "Nginx: OK"
    return 0
  fi
  restore_files "$bk" "${files[@]}"
  rm -rf "$bk"
  if nginx -t >/dev/null 2>&1; then svc_reload nginx >/dev/null 2>&1; fi
  log "Nginx: LOI -> da khoi phuc cau hinh cu.\n$err"
  return 1
}

apply_sysctl() {
  cat > /etc/sysctl.d/99-vhost.conf <<EOF
# Tao boi vhost apply
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
vm.swappiness = ${C[SWAPPINESS]}
EOF
  # -e: bo qua khoa khong ton tai (vd IPv6 bi tat o kernel) - khong phai loi
  sysctl -e -q -p /etc/sysctl.d/99-vhost.conf >/dev/null 2>&1
  log "Kernel (sysctl): OK"
}

apply_journald() {
  local want=""
  [[ -n "${C[JOURNAL_MAX_USE]}" ]] && want=$(printf '[Journal]\nSystemMaxUse=%s\n' "${C[JOURNAL_MAX_USE]}")
  local have=""; [[ -f "$JOURNAL_DROPIN" ]] && have=$(cat "$JOURNAL_DROPIN")
  if [[ "$want" == "$have" ]]; then log "Log he thong (journald): OK"; return 0; fi
  if [[ -n "$want" ]]; then
    mkdir -p "$(dirname "$JOURNAL_DROPIN")"; printf '%s\n' "$want" > "$JOURNAL_DROPIN"
  else
    rm -f "$JOURNAL_DROPIN"
  fi
  if systemctl restart systemd-journald; then
    log "Log he thong (journald): OK (${C[JOURNAL_MAX_USE]:-mac dinh})"
  else
    log "Log he thong (journald): LOI khi khoi dong lai"; return 1
  fi
}

sftp_groups() {
  local groups="${C[SFTP_GROUP]}" g d
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    g=$(state_get "$d" SFTP_GROUP)
    [[ -n "$g" && ",$groups," != *",$g,"* ]] && groups+=",$g"
  done < <(list_domains)
  printf '%s' "$groups"
}

apply_ssh() {
  local bk err disable_pw=0 note="" groups g
  groups=$(sftp_groups)
  local -a garr
  IFS=',' read -r -a garr <<< "$groups"
  for g in "${garr[@]}"; do
    getent group "$g" >/dev/null || groupadd "$g" || { log "SSH: LOI khong tao duoc nhom $g"; return 1; }
  done
  mkdir -p /run/sshd /etc/ssh/sshd_config.d
  bk=$(mktemp -d)
  backup_files "$bk" "$SSHD_CFG" "$SSHD_DROPIN" || { rm -rf "$bk"; log "SSH: LOI khong sao luu duoc"; return 1; }

  grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSHD_CFG" || \
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$SSHD_CFG"

  case "${C[SSH_DISABLE_ROOT_PASSWORD]}" in
    yes)
      if root_has_valid_key; then disable_pw=1
      else note="root CHUA co SSH key hop le -> KHONG chan mat khau (tranh bi khoa ngoai VPS)"; fi ;;
    auto)
      if root_has_valid_key && root_key_login_seen; then disable_pw=1
      elif root_has_valid_key; then note="root co key nhung CHUA tung dang nhap bang key -> chua chan mat khau. Dang nhap thu bang key 1 lan roi chay: vhost apply"
      fi ;;
  esac

  {
    echo "# Tao boi vhost apply - thong so tai /etc/vhost/vhost.conf"
    echo "PermitEmptyPasswords no"
    echo "MaxAuthTries ${C[SSH_MAX_AUTH_TRIES]}"
    echo "LoginGraceTime ${C[SSH_LOGIN_GRACE_TIME]}"
    echo "MaxStartups 10:30:60"
    echo "X11Forwarding no"
    echo "ClientAliveInterval 300"
    echo "ClientAliveCountMax 2"
    (( disable_pw )) && echo "PermitRootLogin prohibit-password"
  } > "$SSHD_DROPIN"

  sed -i '/^# >>> vhost-sftp >>>$/,/^# <<< vhost-sftp <<<$/d' "$SSHD_CFG"
  cat >> "$SSHD_CFG" <<EOF
# >>> vhost-sftp >>>
Match Group $groups
    ChrootDirectory %h
    ForceCommand internal-sftp -u ${C[SFTP_UMASK]}
    PasswordAuthentication yes
    AllowTcpForwarding no
    AllowAgentForwarding no
    AllowStreamLocalForwarding no
    PermitTunnel no
    PermitTTY no
    X11Forwarding no
# <<< vhost-sftp <<<
EOF

  if err=$(sshd -t 2>&1) && svc_reload ssh; then
    rm -rf "$bk"
    [[ -n "$note" ]] && log "SSH: $note"
    if (( disable_pw )); then log "SSH: OK (root chi dang nhap bang SSH key)"
    else log "SSH: OK (root dang nhap bang mat khau hoac key)"; fi
    return 0
  fi
  restore_files "$bk" "$SSHD_CFG" "$SSHD_DROPIN"
  rm -rf "$bk"
  sshd -t >/dev/null 2>&1 && svc_reload ssh >/dev/null 2>&1
  log "SSH: LOI -> da khoi phuc cau hinh cu.\n${err:-khong nap lai duoc dich vu ssh}"
  return 1
}

in_list() { local x="$1" y; shift; for y in "$@"; do [[ "$y" == "$x" ]] && return 0; done; return 1; }

apply_firewall() {
  command -v ufw >/dev/null || { log "Firewall: chua cai ufw"; return 1; }
  if ! on FIREWALL; then
    ufw --force disable >/dev/null || { log "Firewall: LOI khi tat"; return 1; }
    log "Firewall: DA TAT (theo cau hinh)"
    return 0
  fi
  local want=() old=() ports=() p r fail=0
  mapfile -t ports < <(ssh_ports)
  if (( ${#ports[@]} == 0 )); then
    log "Firewall: LOI khong xac dinh duoc cong SSH -> khong bat tuong lua (tranh bi khoa ngoai)"
    return 1
  fi
  for p in "${ports[@]}"; do want+=("limit $p/tcp"); done
  want+=("allow 80/tcp" "allow 443/tcp")
  for p in ${C[EXTRA_TCP_PORTS]}; do want+=("allow $p/tcp"); done

  # Them rule moi TRUOC, xoa rule cu SAU -> cong SSH khong bao gio bi dong
  for r in "${want[@]}"; do
    # shellcheck disable=SC2086
    ufw $r comment vhost >/dev/null || { fail=1; log "Firewall: LOI khi them rule: $r"; }
  done
  (( fail )) && return 1
  [[ -f "$UFW_STATE" ]] && mapfile -t old < "$UFW_STATE"
  for r in "${old[@]}"; do
    [[ -z "$r" ]] && continue
    in_list "$r" "${want[@]}" && continue
    # shellcheck disable=SC2086
    ufw --force delete $r >/dev/null 2>&1   # rule khong con ton tai cung la trang thai dung
  done
  printf '%s\n' "${want[@]}" > "$UFW_STATE"

  ufw default deny incoming  >/dev/null && ufw default allow outgoing >/dev/null && ufw --force enable >/dev/null || {
    log "Firewall: LOI khi bat tuong lua"; return 1; }
  log "Firewall: OK (mo: ${want[*]//allow /})"
}

apply_fail2ban() {
  command -v fail2ban-client >/dev/null || { log "Fail2ban: chua cai"; return 1; }
  if ! on F2B_ENABLED; then
    systemctl disable --now fail2ban >/dev/null 2>&1
    log "Fail2ban: DA TAT (theo cau hinh)"
    return 0
  fi
  local jail=/etc/fail2ban/jail.local bk ports banaction
  ports=$(ssh_ports | paste -sd, -)
  [[ -n "$ports" ]] || { log "Fail2ban: LOI khong xac dinh duoc cong SSH"; return 1; }
  if on FIREWALL; then banaction="ufw"
  elif command -v nft >/dev/null; then banaction="nftables-multiport"
  else banaction="iptables-multiport"; fi

  bk=$(mktemp -d); backup_files "$bk" "$jail"
  cat > "$jail" <<EOF
# Tao boi vhost apply - thong so tai /etc/vhost/vhost.conf
[DEFAULT]
bantime  = ${C[F2B_BANTIME]}
findtime = ${C[F2B_FINDTIME]}
maxretry = ${C[F2B_MAXRETRY]}
banaction = $banaction
ignoreip = 127.0.0.1/8 ::1 ${C[F2B_IGNORE_IP]}

[sshd]
enabled = true
port    = $ports
backend = systemd
mode    = aggressive

[nginx-limit-req]
enabled  = $(on F2B_WEB_ENABLED && [[ "${C[RATE_LIMIT]}" != "off" ]] && echo true || echo false)
backend  = auto
port     = http,https
logpath  = $NGX_MAIN_ERRLOG
maxretry = ${C[F2B_WEB_MAXRETRY]}

[recidive]
enabled  = true
backend  = auto
logpath  = /var/log/fail2ban.log
bantime  = ${C[F2B_RECIDIVE_BANTIME]}
findtime = 1d
maxretry = 3
EOF
  touch /var/log/fail2ban.log "$NGX_MAIN_ERRLOG"
  if fail2ban-client -t >/dev/null 2>&1; then
    systemctl enable fail2ban >/dev/null 2>&1
    if systemctl restart fail2ban; then
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        fail2ban-client ping >/dev/null 2>&1 && { rm -rf "$bk"; log "Fail2ban: OK"; return 0; }
        sleep 1
      done
    fi
  fi
  restore_files "$bk" "$jail"; rm -rf "$bk"
  systemctl restart fail2ban >/dev/null 2>&1
  log "Fail2ban: LOI (cau hinh hoac dich vu khong khoi dong) -> da khoi phuc. Xem: journalctl -u fail2ban"
  return 1
}

apply_updates() {
  local v=0; on AUTO_SECURITY_UPDATES && v=1
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "$v";
APT::Periodic::Unattended-Upgrade "$v";
APT::Periodic::AutocleanInterval "7";
EOF
  log "Tu dong cap nhat bao mat: $( ((v)) && echo BAT || echo TAT )"
}

cmd_apply() {
  if ! load_config; then
    say "Cau hinh co loi, KHONG ap dung gi ca:\n\n$CONFIG_ERRORS\nSua tai: $CONF_FILE" 18
    return 1
  fi
  write_config || { say "Khong ghi duoc $CONF_FILE" 7; return 1; }
  APPLY_LOG=""
  local fail=0
  echo "Dang ap dung $CONF_FILE ..."
  apply_sysctl
  apply_updates
  apply_journald || fail=1
  apply_nginx    || fail=1
  apply_ssh      || fail=1
  apply_firewall || fail=1
  apply_fail2ban || fail=1
  if ((fail)); then echo "CO LOI - phan loi da duoc hoan tac (xem o tren)."; else echo "Hoan tat."; fi
  return $fail
}

cmd_cf_refresh() {
  on CLOUDFLARE_REAL_IP || return 0
  local t bk err
  t=$(mktemp)
  cf_fetch "$t" || { rm -f "$t"; echo "Khong tai duoc danh sach IP Cloudflare" >&2; return 1; }
  if [[ -f "$NGX_CF" ]] && diff -q <(grep -v '^#' "$t") <(grep -v '^#' "$NGX_CF") >/dev/null; then
    rm -f "$t"; return 0      # khong thay doi
  fi
  bk=$(mktemp -d); backup_files "$bk" "$NGX_CF"
  cat "$t" > "$NGX_CF"; rm -f "$t"
  if err=$(nginx_test_and_reload 2>&1); then rm -rf "$bk"; return 0; fi
  restore_files "$bk" "$NGX_CF"; rm -rf "$bk"
  echo "Cap nhat IP Cloudflare that bai, da khoi phuc: $err" >&2
  return 1
}

cmd_config() {
  local editor="${EDITOR:-nano}"
  command -v "$editor" >/dev/null || editor="vi"
  load_config; write_config
  while true; do
    "$editor" "$CONF_FILE"
    load_config && break
    printf 'Cau hinh co loi:\n%b' "$CONFIG_ERRORS"
    confirm "Mo lai de sua?" || { echo "Chua ap dung gi. File van con loi: $CONF_FILE"; return 1; }
  done
  confirm "Ap dung cau hinh moi ngay bay gio?" 8 && cmd_apply
}

# ===================================================================
#  Quan ly website
# ===================================================================
show_credentials() {
  say "Thong tin dang nhap SFTP cho: $1\n\n  Giao thuc : SFTP (KHONG phai FTP)\n  Host      : $(primary_ip)\n  Port      : $(ssh_ports | awk 'NR==1')\n  User      : $2\n  Pass      : $3\n\nUpload file vao thu muc: public_html\n\nMAT KHAU CHI HIEN 1 LAN - hay luu vao trinh quan ly mat khau.\nQuen thi dung 'Doi mat khau SFTP' de tao mat khau moi." 20
}

# Trang thai giao dich tao website (de hoan tac chinh xac nhung gi da tao)
ADD_USER="" ADD_ROOT="" ADD_CONF="" ADD_EXTRA="" ADD_STATE=""
add_rollback() {
  [[ -n "$ADD_CONF" ]]  && rm -f "$NGX_ENABLED/$ADD_CONF" "$NGX_AVAIL/$ADD_CONF" && { nginx -t >/dev/null 2>&1 && svc_reload nginx >/dev/null 2>&1; }
  [[ -n "$ADD_EXTRA" ]] && rm -rf "${ADD_EXTRA:?}"
  [[ -n "$ADD_USER" ]]  && userdel "$ADD_USER" >/dev/null 2>&1
  [[ -n "$ADD_ROOT" ]]  && rm -rf "${ADD_ROOT:?}"
  [[ -n "$ADD_STATE" ]] && rm -f "$ADD_STATE"
  ADD_USER="" ADD_ROOT="" ADD_CONF="" ADD_EXTRA="" ADD_STATE=""
}
add_fail() { add_rollback; say "Tao website that bai, da hoan tac toan bo:\n\n$1" 16; return 1; }

cmd_add() {
  local domain
  if ! domain=$(normalize_domain "${1:-}"); then
    say "Khong chuyen doi duoc ten mien: '${1:-}'" 8; return 1
  fi
  valid_domain "$domain" || { say "Domain khong hop le: '$domain'\nVi du dung: example.com" 9; return 1; }
  site_exists "$domain" && { say "Website $domain da ton tai." 8; return 1; }
  [[ -e "$NGX_AVAIL/$domain.conf" ]] && { say "Da co file nginx cho $domain (tao ngoai vhost). Huy." 8; return 1; }
  if (( ${C[MAX_SITES]} > 0 )) && (( $(site_count) >= ${C[MAX_SITES]} )); then
    say "Da dat so website toi da (${C[MAX_SITES]}) theo cau hinh MAX_SITES." 8; return 1
  fi

  local base="${C[WEB_ROOT]}" group="${C[SFTP_GROUP]}" um="${C[SFTP_UMASK]}"
  local user root doc names a pass err dmode fmode
  user=$(gen_username "$domain")
  root="$base/$domain"
  doc="$root/public_html"
  dmode=$(printf '2%03o' $(( 8#777 & ~8#$um )))
  fmode=$(printf '%03o'  $(( 8#666 & ~8#$um )))

  mkdir -p "$base" || { say "Khong tao duoc $base" 7; return 1; }
  chroot_path_ok "$base" || { say "Thu muc $base (hoac thu muc cha) khong thuoc root hoac cho phep nguoi khac ghi.\nSFTP chroot se khong an toan. Hay sua quyen hoac doi WEB_ROOT." 10; return 1; }
  id "$user" &>/dev/null && { say "User $user da ton tai bat thuong. Huy." 8; return 1; }
  [[ -e "$root" ]] && { say "Thu muc $root da ton tai. Huy de tranh ghi de du lieu." 8; return 1; }
  names="$domain"
  for a in ${C[SERVER_ALIASES]}; do names+=" $a.$domain"; done

  # ---- Bat dau giao dich: moi buoc loi -> hoan tac toan bo ----
  ADD_USER="" ADD_ROOT="" ADD_CONF="" ADD_EXTRA="" ADD_STATE=""

  getent group "$group" >/dev/null || groupadd "$group" || add_fail "Khong tao duoc nhom $group" || return 1

  ADD_ROOT="$root"
  { mkdir -p "$doc" && chown root:root "$root" && chmod 755 "$root"; } || { add_fail "Khong tao duoc thu muc $root"; return 1; }

  useradd -M -d "$root" -g "$group" -s /usr/sbin/nologin -c "SFTP $domain" "$user" || { add_fail "Khong tao duoc user $user"; return 1; }
  ADD_USER="$user"

  {
    chown "$user":www-data "$doc" && chmod "$dmode" "$doc" &&
    printf '<!DOCTYPE html>\n<html lang="vi"><head><meta charset="utf-8"><title>%s</title></head>\n<body><h1>%s</h1><p>Website dang duoc thiet lap.</p></body></html>\n' "$domain" "$domain" > "$doc/index.html" &&
    chown "$user":www-data "$doc/index.html" && chmod "$fmode" "$doc/index.html"
  } || { add_fail "Khong dat duoc quyen thu muc website"; return 1; }

  ADD_EXTRA="$NGX_SITE_EXTRA/$domain"
  mkdir -p "$ADD_EXTRA" || { add_fail "Khong tao duoc $ADD_EXTRA"; return 1; }

  ADD_STATE="$STATE_DIR/$domain"
  { printf 'DOMAIN=%s\nSFTP_USER=%s\nSFTP_GROUP=%s\nROOT=%s\nNAMES=%s\nCREATED=%s\n' \
      "$domain" "$user" "$group" "$root" "$names" "$(date -Iseconds)" > "$ADD_STATE" && chmod 600 "$ADD_STATE"; } ||
    { add_fail "Khong ghi duoc file trang thai"; return 1; }

  # Nhom SFTP moi (vd vua doi SFTP_GROUP) -> cap nhat sshd de chroot nhom nay TRUOC khi cap mat khau
  if ! user_is_chrooted "$user"; then
    APPLY_LOG=""
    apply_ssh >/dev/null || { add_fail "Khong cap nhat duoc SSH cho nhom $group:\n$APPLY_LOG"; return 1; }
    user_is_chrooted "$user" || { add_fail "SSH chua chroot duoc user moi - huy de an toan"; return 1; }
  fi

  ADD_CONF="$domain.conf"
  render_site_conf "$domain" "$doc" "$names" > "$NGX_AVAIL/$ADD_CONF" &&
    ln -sf "$NGX_AVAIL/$ADD_CONF" "$NGX_ENABLED/$ADD_CONF" || { add_fail "Khong ghi duoc cau hinh nginx"; return 1; }
  err=$(nginx_test_and_reload 2>&1) || { add_fail "Loi nginx:\n$err"; return 1; }

  pass=$(gen_password)
  printf '%s:%s\n' "$user" "$pass" | chpasswd || { add_fail "Khong dat duoc mat khau SFTP"; return 1; }

  # ---- Giao dich thanh cong ----
  ADD_USER="" ADD_ROOT="" ADD_CONF="" ADD_EXTRA="" ADD_STATE=""
  say "DA TAO WEBSITE: $domain\n\nTiep theo:\n 1) Tro DNS ($names) ve IP $(primary_ip)\n 2) Upload source bang SFTP (thong tin o man hinh sau)\n 3) Cai SSL: menu 'Cai SSL' hoac lenh: vhost ssl $domain" 13
  show_credentials "$domain" "$user" "$pass"
}

cmd_ssl() {
  local domain; domain=$(normalize_domain "${1:-}") || true
  site_exists "$domain" || { say "Khong tim thay website: ${1:-}" 8; return 1; }
  command -v certbot >/dev/null || { say "Chua cai certbot." 8; return 1; }

  local my_ips dom_ips ip n match=0 args=() log names
  my_ips=$(server_ips)
  dom_ips=$(resolve_ips "$domain")
  [[ -z "$dom_ips" ]] && { say "Domain $domain chua co ban ghi DNS.\nTro ban ghi A ve IP $(primary_ip), doi vai phut roi thu lai." 9; return 1; }
  for ip in $dom_ips; do grep -qxF -- "$ip" <<<"$my_ips" && match=1; done
  if (( ! match )); then
    confirm "Canh bao: $domain dang tro ve:\n$dom_ips\nkhong phai IP cua VPS nay.\n(Dung Cloudflare proxy thi dieu nay la binh thuong.)\n\nVan tiep tuc?" 14 || return 1
  fi

  names=$(state_get "$domain" NAMES); [[ -z "$names" ]] && names="$domain"
  for n in $names; do
    if [[ "$n" == "$domain" || -n "$(resolve_ips "$n")" ]]; then args+=(-d "$n")
    else log "Bo qua $n (chua co ban ghi DNS)"; fi
  done
  if [[ -n "${C[SSL_EMAIL]}" ]]; then args+=(-m "${C[SSL_EMAIL]}"); else args+=(--register-unsafely-without-email); fi
  if on SSL_REDIRECT; then args+=(--redirect); else args+=(--no-redirect); fi

  log=$(mktemp)
  if certbot --nginx --non-interactive --agree-tos --keep-until-expiring --cert-name "$domain" "${args[@]}" >"$log" 2>&1; then
    rm -f "$log"
    if nginx -t >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
      say "Cai SSL thanh cong cho $domain. Chung chi se tu dong gia han." 8; return 0
    fi
    say "Certbot bao thanh cong nhung nginx khong o trang thai tot. Kiem tra: nginx -t" 8; return 1
  fi
  say "Cai SSL that bai (thuong do DNS chua tro dung/chua cap nhat).\n\n$(tail -n 12 "$log")" 20
  rm -f "$log"; return 1
}

cmd_passwd() {
  local domain user pass; domain=$(normalize_domain "${1:-}") || true
  site_exists "$domain" || { say "Khong tim thay website: ${1:-}" 8; return 1; }
  user=$(state_get "$domain" SFTP_USER)
  if [[ "$user" != "$USER_PREFIX"* ]] || ! id "$user" &>/dev/null; then
    say "Khong tim thay user SFTP cua $domain." 8; return 1
  fi
  pass=$(gen_password)
  printf '%s:%s\n' "$user" "$pass" | chpasswd || { say "Khong dat duoc mat khau." 7; return 1; }
  show_credentials "$domain" "$user" "$pass"
}

cmd_del() {
  local domain user root warn=""; domain=$(normalize_domain "${1:-}") || true
  site_exists "$domain" || { say "Khong tim thay website: ${1:-}" 8; return 1; }
  user=$(state_get "$domain" SFTP_USER)
  root=$(site_root "$domain") || { say "Duong dan website trong file trang thai khong an toan. Huy." 8; return 1; }

  confirm "XOA website $domain ?\n\nSe xoa: cau hinh nginx, SSL, TOAN BO source ($root), tai khoan SFTP.\nKHONG THE HOAN TAC." 12 || return 1

  # 1) Go khoi nginx truoc (de khong con tham chieu toi chung chi/thu muc sap xoa)
  rm -f "$NGX_ENABLED/$domain.conf" "$NGX_AVAIL/$domain.conf"
  rm -rf "${NGX_SITE_EXTRA:?}/${domain:?}"
  nginx_test_and_reload >/dev/null 2>&1 || warn+="\n- Nginx chua nap lai duoc (co cau hinh khac dang loi). Kiem tra: nginx -t"
  # 2) Chung chi
  if [[ -f "/etc/letsencrypt/renewal/$domain.conf" ]]; then
    certbot delete --non-interactive --cert-name "$domain" >/dev/null 2>&1 || warn+="\n- Khong xoa duoc chung chi SSL (certbot delete --cert-name $domain)"
  fi
  # 3) Tai khoan
  if [[ "$user" == "$USER_PREFIX"* ]] && id "$user" &>/dev/null; then
    pkill -KILL -u "$user" 2>/dev/null; sleep 1
    userdel "$user" || warn+="\n- Khong xoa duoc user $user"
  fi
  # 4) Du lieu
  rm -rf "${root:?}"
  rm -f "/var/log/nginx/$domain.access.log"* "/var/log/nginx/$domain.error.log"*
  rm -f "${STATE_DIR:?}/${domain:?}"
  say "Da xoa website $domain.${warn:+\n\nCan kiem tra:$warn}" 12
}

cmd_list() {
  local d out="" ssl size max
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    ssl="HTTP "; [[ -d "/etc/letsencrypt/live/$d" ]] && ssl="HTTPS"
    size=$(du -sh "$(site_root "$d")" 2>/dev/null | cut -f1)
    out+="$(printf '%-30s %s %6s  %s' "$d" "$ssl" "${size:-?}" "$(state_get "$d" SFTP_USER)")\n"
  done < <(list_domains)
  [[ -z "$out" ]] && out="Chua co website nao.\n"
  max="${C[MAX_SITES]}"; (( max > 0 )) || max="khong gioi han"
  say "Website: $(site_count) (toi da: $max)\n\n$out" 20 82
}

cmd_status() {
  local svc s out="" banned rootpw
  for svc in nginx ssh fail2ban; do
    s=$(systemctl is-active "$svc" 2>/dev/null); out+="$(printf '  %-18s %s' "$svc" "${s:-?}")\n"
  done
  out+="$(printf '  %-18s %s' ufw "$(ufw status 2>/dev/null | awk 'NR==1{print $2}')")\n"
  banned=$(fail2ban-client status sshd 2>/dev/null | awk -F: '/Currently banned/{gsub(/[ \t]/,"",$2);print $2}')
  case "$(sshd -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null | awk '/^permitrootlogin /{print $2}')" in
    without-password|prohibit-password) rootpw="chi SSH key" ;;
    no) rootpw="bi cam" ;;
    *) rootpw="mat khau hoac key" ;;
  esac
  say "$(free -h | awk '/^Mem:/{print "RAM  : "$3" / "$2}')\n$(free -h | awk '/^Swap:/{print "Swap : "$3" / "$2}')\n$(df -h / | awk 'NR==2{print "Disk : "$3" / "$2" ("$5")"}')\nLoad :$(uptime | awk -F'load average:' '{print $2}')\n\nDich vu:\n$out\nRoot dang nhap SSH: $rootpw\nIP dang bi chan (SSH): ${banned:-0}\nFile cau hinh: $CONF_FILE" 22
}

# ===================================================================
#  Menu
# ===================================================================
# In danh sach website danh so ra stderr, doc so tu ban phim, tra ve domain o stdout
pick_domain() {
  local -a ds=()
  local d n
  while IFS= read -r d; do [[ -n "$d" ]] && ds+=("$d"); done < <(list_domains)
  (( ${#ds[@]} )) || { echo "Chua co website nao." >&2; return 1; }
  echo >&2
  for n in "${!ds[@]}"; do printf '  %2d) %s\n' $((n + 1)) "${ds[$n]}" >&2; done
  printf '   0) Quay lai\n' >&2
  read -r -p "Chon website [0-${#ds[@]}]: " n
  [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#ds[@]} )) || return 1
  printf '%s' "${ds[$((n - 1))]}"
}

pause() { echo; read -r -p "Nhan Enter de quay lai menu..." _; }

menu() {
  [[ -t 0 ]] || { echo "Menu can chay trong terminal. Dung: vhost help" >&2; return 1; }
  local choice d nd
  while true; do
    echo
    echo "=============================================="
    echo "   VHOST - Quan ly website        ($(site_count) website)"
    echo "=============================================="
    echo "   1) Tao website moi"
    echo "   2) Danh sach website"
    echo "   3) Cai SSL (HTTPS)"
    echo "   4) Doi mat khau SFTP"
    echo "   5) Xoa website"
    echo "   6) Trang thai he thong"
    echo "   7) Cau hinh he thong"
    echo "   0) Thoat"
    echo "----------------------------------------------"
    read -r -p "Nhap lua chon [0-7]: " choice || break
    echo
    case "$choice" in
      1) read -r -p "Nhap domain (vd: example.com), de trong de quay lai: " d
         if [[ -n "$d" ]] && cmd_add "$d"; then
           nd=$(normalize_domain "$d")
           echo
           confirm "Cai SSL cho $nd ngay bay gio? (chi thanh cong khi DNS da tro ve VPS)" && cmd_ssl "$nd"
         fi
         pause ;;
      2) cmd_list; pause ;;
      3) d=$(pick_domain) && cmd_ssl "$d"; pause ;;
      4) d=$(pick_domain) && cmd_passwd "$d"; pause ;;
      5) d=$(pick_domain) && cmd_del "$d"; pause ;;
      6) cmd_status; pause ;;
      7) cmd_config; pause ;;
      0|q|Q) break ;;
      *) echo "Lua chon khong hop le: '$choice'" ;;
    esac
  done
}

usage() {
  cat <<EOF
Cach dung:
  vhost                    Mo menu
  vhost add <domain>       Tao website
  vhost ssl <domain>       Cai SSL Let's Encrypt
  vhost passwd <domain>    Tao lai mat khau SFTP
  vhost del <domain>       Xoa website (them --yes de bo qua xac nhan)
  vhost list               Liet ke website
  vhost status             Trang thai he thong
  vhost config             Sua cau hinh he thong ($CONF_FILE)
  vhost apply              Ap dung lai cau hinh
  vhost get <KHOA>         In gia tri mot tuy chon
EOF
}

# ===================================================================
#  Diem vao
# ===================================================================
[[ $EUID -eq 0 ]] || { echo "Can quyen root." >&2; exit 1; }

case "${1:-}" in
  get)
    load_config >/dev/null 2>&1
    [[ -n "${2:-}" && -n "${DEF[${2}]+x}" ]] || { echo "Khong co tuy chon: ${2:-}" >&2; exit 1; }
    printf '%s\n' "${C[$2]}"; exit 0 ;;
  help|-h|--help) usage; exit 0 ;;
esac

# Khoa chong chay dong thoi. flock -o: tien trinh con (nginx, sshd...) KHONG ke thua khoa.
if [[ "${VHOST_LOCKED:-}" != "1" ]]; then
  VHOST_LOCKED=1 flock -n -E "$EXIT_LOCKED" -o "$LOCK_FILE" "$(readlink -f "${BASH_SOURCE[0]}")" "$@"
  rc=$?
  (( rc == EXIT_LOCKED )) && echo "Dang co phien 'vhost' khac chay. Thu lai sau." >&2
  exit $rc
fi

mkdir -p "$STATE_DIR" && chmod 700 "$CONF_DIR" "$STATE_DIR"

# --yes / -y: tu dong dong y moi cau hoi xac nhan (dung cho script tu dong)
ARGS=()
for a in "$@"; do
  case "$a" in -y|--yes) ASSUME_YES=1 ;; *) ARGS+=("$a") ;; esac
done
set -- "${ARGS[@]}"

case "${1:-}" in
  init)
    if load_config; then write_config; exit $?; fi
    printf 'Cau hinh hien tai co loi:\n%b' "$CONFIG_ERRORS" >&2; exit 1 ;;
  apply|config) ;;
  *)
    if ! load_config; then
      printf 'Canh bao - cau hinh co loi, dang dung gia tri mac dinh cho cac dong loi:\n%b\nSua bang: vhost config\n\n' "$CONFIG_ERRORS" >&2
    fi ;;
esac

case "${1:-}" in
  "")         menu ;;
  add)        cmd_add "${2:-}" ;;
  ssl)        cmd_ssl "${2:-}" ;;
  passwd)     cmd_passwd "${2:-}" ;;
  del)        cmd_del "${2:-}" ;;
  list)       cmd_list ;;
  status)     cmd_status ;;
  config)     cmd_config ;;
  apply)      cmd_apply ;;
  cf-refresh) load_config >/dev/null 2>&1; cmd_cf_refresh ;;
  *)          usage; exit 1 ;;
esac
VHOSTEOF
chmod 700 "$TMP_BIN"
bash -n "$TMP_BIN" || die "Ban vhost di kem bi hong"
cfg() { "$TMP_BIN" get "$1"; }

is_installed_pkg() { [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null)" == ii* ]]; }
distro_maintainer() { [[ "$1" =~ (Ubuntu|Debian) ]]; }

# ==================================================================
step "1/6 Kiem tra VPS (chua thay doi gi)"
# ==================================================================
PROBLEMS=()

# File nginx do CHINH vhost tao ra (khi chay lai sau lan cai truoc) - khong tinh la cau hinh la
vhost_owned() {
  local f="$1" b
  b=$(basename "$f")
  case "$f" in
    /etc/nginx/sites-enabled/000-default-deny.conf) return 0 ;;
    /etc/nginx/conf.d/vhost-*.conf) return 0 ;;
    /etc/nginx/sites-enabled/*.conf) [[ -f "/etc/vhost/sites/${b%.conf}" ]] ;;
    *) return 1 ;;
  esac
}

# Control panel / script quan ly khac
for p in /usr/local/cpanel /usr/local/directadmin /www/server /usr/local/lsws /usr/local/vesta \
         /usr/local/hestia /usr/local/CyberCP /opt/plesk /usr/local/psa /etc/hocvps /usr/local/cwpsrv; do
  [[ -e "$p" ]] && PROBLEMS+=("Phat hien control panel / cong cu quan ly khac: $p")
done

# Web server / PHP / CSDL khac
mapfile -t OTHER_PKGS < <(dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\n' 2>/dev/null |
  awk -F'\t' '$1 ~ /^ii/ {print $2}' |
  grep -E '^(apache2|lighttpd|caddy|openlitespeed|lsws|mysql-server.*|mariadb-server.*|percona-server-server.*|php[0-9.]*-fpm|libapache2-mod-php.*)$' || true)
for p in "${OTHER_PKGS[@]}"; do PROBLEMS+=("Da cai san goi: $p"); done

# Nginx da co san
if is_installed_pkg nginx; then
  NGX_MAINT=$(dpkg-query -W -f='${Maintainer}' nginx 2>/dev/null || true)
  distro_maintainer "$NGX_MAINT" || PROBLEMS+=("Nginx dang cai tu nguon ngoai (khong phai cua $ID): $NGX_MAINT")
  [[ -d /etc/nginx/sites-enabled ]] || PROBLEMS+=("Nginx co cau truc thu muc khac chuan $ID (khong co /etc/nginx/sites-enabled)")
  for f in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
    [[ -e "$f" || -L "$f" ]] || continue
    [[ "$f" == /etc/nginx/sites-enabled/default ]] && continue
    vhost_owned "$f" && continue
    PROBLEMS+=("Nginx dang co cau hinh website khong do vhost tao: $f")
  done
fi

# Cong 80/443: chi chap nhan nginx (da duoc kiem tra o tren)
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  [[ "$line" == *'"nginx"'* ]] && continue
  PROBLEMS+=("Cong web dang bi chuong trinh khac dung: $line")
done < <(ss -ltnpH 2>/dev/null | awk '$4 ~ /:(80|443)$/' || true)

# Dung luong dia
MIN_FREE=$(cfg MIN_FREE_DISK_MB)
FREE_MB=$(df -m --output=avail / | tail -1 | tr -d ' ')
(( FREE_MB >= MIN_FREE )) || PROBLEMS+=("O dia chi con ${FREE_MB}MB trong, can it nhat ${MIN_FREE}MB (MIN_FREE_DISK_MB)")

MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
echo "   RAM: ${MEM_MB}MB | O dia trong: ${FREE_MB}MB"

if (( ${#PROBLEMS[@]} )); then
  echo
  echo "!!! VPS KHONG DAT DIEU KIEN - KHONG THAY DOI GI TREN MAY:"
  for p in "${PROBLEMS[@]}"; do echo "    - $p"; done
  echo
  echo "    Script nay chi chay tren VPS MOI CAI he dieu hanh (Ubuntu 20.04/22.04/24.04, Debian 11/12)."
  echo "    Hay cai lai he dieu hanh tu bang dieu khien cua nha cung cap roi chay lai."
  exit 1
fi
echo "   Dat."

# ==================================================================
step "2/6 Cap nhat danh sach goi & kiem tra nguon Nginx (chua cai gi)"
# ==================================================================
if command -v cloud-init >/dev/null 2>&1; then
  echo "   Doi cloud-init hoan tat..."
  # Ma thoat khac 0 chi phan anh loi rieng cua cloud-init, khong anh huong cai dat
  timeout 900 cloud-init status --wait >/dev/null 2>&1 || warn "cloud-init bao trang thai khong binh thuong (bo qua)"
fi
updated=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  if apt-get update -q -o DPkg::Lock::Timeout=900; then updated=1; break; fi
  echo "   apt-get update chua thanh cong (lan $i) - thu lai sau 30 giay..."; sleep 30
done
(( updated )) || die "Khong cap nhat duoc danh sach goi (kiem tra mang/DNS cua VPS)"

# Neu co repo ngoai cung cap nginx (vd nginx.org) voi phien ban cao hon, apt se cai ban do -> tu choi
NGX_CAND=$(apt-cache policy nginx 2>/dev/null | awk '/Candidate:/{print $2}')
[[ -n "$NGX_CAND" && "$NGX_CAND" != "(none)" ]] || die "Khong tim thay goi nginx trong kho cua $ID"
# awk doc HET du lieu (khong 'exit' som) -> apt-cache khong bi SIGPIPE duoi pipefail
NGX_CAND_MAINT=$(apt-cache show "nginx=$NGX_CAND" 2>/dev/null | awk -F': ' '/^Maintainer:/ && !f {print $2; f=1}')
if ! distro_maintainer "$NGX_CAND_MAINT"; then
  die "apt se cai Nginx $NGX_CAND tu nguon ngoai ($NGX_CAND_MAINT) thay vi ban cua $ID.
    May dang co repo Nginx cua ben thu ba. Hay cai lai he dieu hanh ban sach. Khong co gi bi thay doi."
fi
echo "   Nginx se cai: $NGX_CAND ($NGX_CAND_MAINT)"

# ==================================================================
step "3/6 Swap"
# ==================================================================
make_swap() {
  local mb="$1"
  if fallocate -l "${mb}M" /swapfile 2>/dev/null && chmod 600 /swapfile && mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile 2>/dev/null; then
    return 0
  fi
  # Mot so he thong file (btrfs, xfs cu) khong dung duoc file tao bang fallocate -> ghi day du bang dd
  swapoff /swapfile 2>/dev/null || true
  rm -f /swapfile
  dd if=/dev/zero of=/swapfile bs=1M count="$mb" status=none && chmod 600 /swapfile && mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile 2>/dev/null
}
SWAP_CFG=$(cfg SWAP_SIZE)
if [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then
  echo "   Da co swap - giu nguyen."
elif [[ -e /swapfile ]]; then
  warn "Da co file /swapfile nhung khong duoc bat - khong dong vao file nay, bo qua tao swap."
else
  case "$SWAP_CFG" in
    0)    SWAP_MB=0 ;;
    auto) if (( MEM_MB <= 2048 )); then SWAP_MB=$MEM_MB; else SWAP_MB=0; fi ;;
    *G)   SWAP_MB=$(( ${SWAP_CFG%G} * 1024 )) ;;
    *M)   SWAP_MB=${SWAP_CFG%M} ;;
  esac
  FREE_MB=$(df -m --output=avail / | tail -1 | tr -d ' ')
  ALLOWED=$(( FREE_MB - MIN_FREE ))
  if (( SWAP_MB > ALLOWED )); then
    if (( ALLOWED > 0 )); then
      warn "Swap ${SWAP_MB}MB se lam o dia con duoi ${MIN_FREE}MB -> giam con ${ALLOWED}MB"; SWAP_MB=$ALLOWED
    else
      warn "Khong du dung luong de tao swap ma van giu ${MIN_FREE}MB trong -> bo qua swap"; SWAP_MB=0
    fi
  fi
  if (( SWAP_MB > 0 )); then
    if make_swap "$SWAP_MB"; then
      grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
      echo "   Da tao swap ${SWAP_MB}MB."
    else
      rm -f /swapfile
      warn "Khong tao duoc swap (thuong do VPS dang container OpenVZ/LXC). Tiep tuc khong co swap."
    fi
  else
    echo "   Khong tao swap."
  fi
fi

# ==================================================================
step "4/6 Cai cac goi can thiet (khong nang cap toan he thong)"
# ==================================================================
# Chi cai dung goi can dung; ban va bao mat do unattended-upgrades xu ly hang ngay.
apt-get "${APT_OPTS[@]}" install --no-install-recommends \
  nginx certbot python3-certbot-nginx ufw fail2ban python3-systemd \
  unattended-upgrades nano curl openssl ssl-cert ca-certificates cron idn2 iproute2
[[ -f /etc/nginx/nginx.conf.orig ]] || cp -a /etc/nginx/nginx.conf /etc/nginx/nginx.conf.orig
[[ -f /etc/ssh/sshd_config.vhost-orig ]] || cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.vhost-orig
systemctl enable --now nginx >/dev/null
systemctl enable --now unattended-upgrades >/dev/null

# ==================================================================
step "5/6 Cai lenh 'vhost' & ap dung cau hinh"
# ==================================================================
install -o root -g root -m 700 "$TMP_BIN" "$VHOST_BIN"
"$VHOST_BIN" init || die "File /etc/vhost/vhost.conf co loi (xem o tren). Sua roi chay lai."
"$VHOST_BIN" apply || die "Mot so phan ap dung loi (phan loi da duoc hoan tac, he thong van an toan). Xem thong bao o tren."

# ==================================================================
step "6/6 Gia han SSL tu dong"
# ==================================================================
if systemctl list-unit-files certbot.timer >/dev/null 2>&1 && systemctl is-enabled --quiet certbot.timer 2>/dev/null; then
  echo "   certbot.timer: dang bat"
else
  printf 'SHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n17 3,15 * * * root certbot renew --quiet\n' > /etc/cron.d/certbot-vhost
  echo "   Da them cron gia han SSL"
fi

trap - ERR
echo
echo "=================================================================="
echo " CAI DAT HOAN TAT"
echo "   Quan ly website : vhost"
echo "   Trang thai      : vhost status"
echo "   Sua cau hinh    : vhost config   (file /etc/vhost/vhost.conf)"
echo "   Log cai dat     : $LOG"
echo "=================================================================="
exec >&- 2>&-
wait "$TEE_PID" 2>/dev/null || true
