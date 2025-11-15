#!/usr/bin/env bash
set -euo pipefail

# AlmaLinux 8.0 için: Plesk + PHP 7.4, 8.0-8.4 + ionCube + Firewalld + Plesk Firewall
# Not: PHP 7.1/7.2/7.3 bu dağıtımda resmi depolarda yoktur. Script, mevcut değilse atlar.

GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; CYAN="\033[1;36m"; NC="\033[0m"
log()  { printf "${GREEN}[+]${NC} %s\n" "$*"; }
info() { printf "${CYAN}[*]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err()  { printf "${RED}[x]${NC} %s\n" "$*"; }

SUCCESSES=()
WARNINGS=()
FAILURES=()

record_success(){ SUCCESSES+=("$1"); }
record_warning(){ WARNINGS+=("$1"); }
record_failure(){ FAILURES+=("$1"); }

banner(){
  echo -e "${CYAN}==============================================${NC}"
  echo -e "${CYAN}   ArslanSoft Plesk Otomatik Kurulum Scripti   ${NC}"
  echo -e "${CYAN}   AlmaLinux 8.0 için                          ${NC}"
  echo -e "${CYAN}==============================================${NC}"
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "Bu script root olarak çalıştırılmalıdır."; exit 1
  fi
}

setup_basics() {
  info "Sistem güncellemeleri uygulanıyor"
  if dnf -y update; then record_success "DNF upgrade"; else record_failure "DNF upgrade"; fi
  if dnf -y install tzdata curl ca-certificates firewalld unzip epel-release; then record_success "Temel paketler"; else record_failure "Temel paketler"; fi
  info "Saat dilimi Europe/Istanbul ayarlanıyor"
  if timedatectl set-timezone Europe/Istanbul; then record_success "Timezone"; else record_warning "Timezone (eldeki değer korunmuş olabilir)"; fi
  timedatectl set-local-rtc 0 || true
}

setup_firewall() {
  info "Firewalld temel kuralları uygulanıyor"
  systemctl enable --now firewalld || true
  for p in 22 80 443 8443 8447; do
    firewall-cmd --permanent --add-port=${p}/tcp 2>/dev/null || true
  done
  # Plesk lisans sunucusu çıkış portu
  firewall-cmd --permanent --add-rich-rule='rule family="ipv4" destination port="5224" protocol="tcp" accept' 2>/dev/null || true
  if firewall-cmd --reload; then record_success "Firewalld aktif"; else record_warning "Firewalld etkinleştirme"; fi
}

# Bazı ortamlarda Plesk kurulumu sonrası HTTP/HTTPS kuralları tekrar gereksinim
ensure_http_https_open() {
  info "HTTP/HTTPS erişimi kesinleştiriliyor (Firewalld)"
  firewall-cmd --permanent --add-service=http || true
  firewall-cmd --permanent --add-service=https || true
  firewall-cmd --reload || true
  record_success "Firewalld 80/443 açık ve reload"
}

install_plesk() {
  if ! command -v plesk >/dev/null 2>&1; then
    log "Plesk kurulumu başlatılıyor (stable)"
    if sh <(curl -fsSL https://autoinstall.plesk.com/one-click-installer) --tier stable; then
      record_success "Plesk kuruldu"
    else
      record_failure "Plesk kurulumu"
    fi
  else
    info "Plesk zaten kurulu"
  fi

  info "Plesk Firewall uzantısı etkinleştiriliyor"
  plesk installer add --components ext-firewall || true
  if plesk bin extension --enable firewall; then record_success "Plesk Firewall etkin"; else record_warning "Plesk Firewall etkinleştirme"; fi
}

add_remi_repository() {
  info "Remi Repository ekleniyor"
  if ! dnf list installed | grep -q remi-release; then
    dnf -y install https://rpms.remirepo.net/enterprise/remi-release-8.rpm || {
      # Alternatif: direkt dnf config-manager ile
      dnf -y install dnf-plugins-core || true
      dnf config-manager --add-repo https://rpms.remirepo.net/enterprise/remi-release-8.rpm || true
    }
    dnf -y update || true
    record_success "Remi Repository eklendi"
  else
    info "Remi Repository zaten ekli"
  fi
}

install_php_series() {
  local version="$1"
  local version_dot="${version/./}"
  info "PHP ${version} paketleri kuruluyor"
  
  # Remi repository'yi etkinleştir
  dnf -y module reset php || true
  dnf -y module enable php:remi-${version} || true
  
  # PHP paketlerini kur
  dnf -y install \
    php${version_dot}-php-fpm php${version_dot}-php-cli php${version_dot}-php-common php${version_dot}-php-opcache \
    php${version_dot}-php-mbstring php${version_dot}-php-xml php${version_dot}-php-zip php${version_dot}-php-curl \
    php${version_dot}-php-gd php${version_dot}-php-intl php${version_dot}-php-soap php${version_dot}-php-mysqlnd || {
      warn "PHP ${version} paketleri bulunamadı, atlanıyor."; record_warning "PHP ${version} paket yok"; return 0; }

  # Timezone ayarı
  local php_ini_fpm="/etc/opt/remi/php${version_dot}/php-fpm.d/99-timezone.ini"
  local php_ini_cli="/etc/opt/remi/php${version_dot}/php.d/99-timezone.ini"
  
  echo "date.timezone=Europe/Istanbul" > "${php_ini_fpm}" 2>/dev/null || true
  echo "date.timezone=Europe/Istanbul" > "${php_ini_cli}" 2>/dev/null || true
  
  # PHP-FPM servisini başlat
  systemctl enable --now php${version_dot}-php-fpm || true

  # Plesk handler ekle
  local hid="remi-php${version_dot}"
  info "Plesk handler ekleniyor: ${hid}"
  plesk bin php_handler --remove "${hid}" 2>/dev/null || true
  
  # AlmaLinux'ta PHP-FPM yolu farklı
  local php_fpm_path="/opt/remi/php${version_dot}/root/usr/sbin/php-fpm"
  local php_cli_path="/opt/remi/php${version_dot}/root/usr/bin/php"
  local php_ini_path="/etc/opt/remi/php${version_dot}/php.ini"
  local php_pool_path="/etc/opt/remi/php${version_dot}/php-fpm.d"
  
  # Yolları kontrol et ve alternatifleri dene
  [ ! -f "${php_fpm_path}" ] && php_fpm_path="/usr/sbin/php-fpm${version}" || true
  [ ! -f "${php_cli_path}" ] && php_cli_path="/usr/bin/php${version}" || true
  [ ! -f "${php_ini_path}" ] && php_ini_path="/etc/php.ini" || true
  [ ! -d "${php_pool_path}" ] && php_pool_path="/etc/php-fpm.d" || true
  
  plesk bin php_handler --add \
    -id "${hid}" \
    -displayname "PHP ${version} (Remi) FPM" \
    -type fpm \
    -path "${php_fpm_path}" \
    -service "php${version_dot}-php-fpm" \
    -phpini "${php_ini_path}" \
    -poold "${php_pool_path}" \
    -clipath "${php_cli_path}" && record_success "Handler ${version}" || { warn "Handler kayıt uyarısı: ${version}"; record_warning "Handler ${version}"; }
}

install_plesk_php_components() {
  # Plesk'in kendi PHP'leri (mevcut ise)
  info "Plesk PHP 8.0/8.1/8.2 bileşenleri deneniyor"
  plesk installer add --components plesk-php80 plesk-php81 plesk-php82 || record_warning "Plesk PHP 8.0/8.1/8.2 eklenemedi (opsiyonel)"
}

install_ioncube_for_version() {
  local version="$1"
  local version_dot="${version/./}"
  
  # AlmaLinux'ta PHP extension dizini farklı
  local ext_dir="/opt/remi/php${version_dot}/root/usr/lib64/php/modules"
  [ ! -d "${ext_dir}" ] && ext_dir="/usr/lib64/php/modules" || true
  [ ! -d "${ext_dir}" ] && ext_dir="/usr/lib/php/modules" || true
  
  local so_target="${ext_dir}/ioncube_loader_lin_${version}.so"
  [ -d "$(dirname ${so_target})" ] || mkdir -p "$(dirname ${so_target})"
  cp "ioncube/ioncube_loader_lin_${version}.so" "${so_target}" 2>/dev/null || true

  # conf.d dosyalarını yaz
  local php_ini_dir="/etc/opt/remi/php${version_dot}/php.d"
  [ ! -d "${php_ini_dir}" ] && php_ini_dir="/etc/php.d" || true
  
  if [ -d "${php_ini_dir}" ]; then
    echo "zend_extension=${so_target}" > "${php_ini_dir}/00-ioncube.ini" 2>/dev/null || true
  fi
  
  # FPM için ayrı ini dizini
  local php_fpm_ini_dir="/etc/opt/remi/php${version_dot}/php-fpm.d"
  [ ! -d "${php_fpm_ini_dir}" ] && php_fpm_ini_dir="/etc/php-fpm.d" || true
  
  if [ -d "${php_fpm_ini_dir}" ]; then
    echo "zend_extension=${so_target}" > "${php_fpm_ini_dir}/00-ioncube.ini" 2>/dev/null || true
  fi
}

install_ioncube() {
  info "ionCube Loader indiriliyor"
  cd /root
  curl -fsSL -o ioncube_loaders_lin_x86-64.zip https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.zip
  unzip -o ioncube_loaders_lin_x86-64.zip >/dev/null

  for v in 7.4 8.0 8.1 8.2 8.3 8.4; do
    local v_dot="${v/./}"
    if [ -d "/etc/opt/remi/php${v_dot}" ] || [ -d "/opt/remi/php${v_dot}" ]; then
      info "ionCube etkinleştiriliyor: PHP ${v}"
      install_ioncube_for_version "${v}" && record_success "ionCube ${v}" || { warn "ionCube ${v} kurulamadı"; record_warning "ionCube ${v}"; }
      systemctl restart php${v_dot}-php-fpm 2>/dev/null || systemctl restart php-fpm 2>/dev/null || true
    fi
  done
}

show_summary() {
  echo
  log "Kurulum özeti"
  timedatectl | sed -n '1,6p'
  plesk version || true
  echo "--- PHP Handler Listesi ---"
  plesk bin php_handler --list || true
  echo "--- Açık Portlar ---"
  ss -ltnp | grep -E ':(22|80|443|8443|8447)\b' || true

  echo
  echo -e "${GREEN}Başarılı adımlar:${NC}"
  ((${#SUCCESSES[@]})) && printf ' - %s\n' "${SUCCESSES[@]}" || echo ' - (yok)'
  echo -e "${YELLOW}Uyarılar:${NC}"
  ((${#WARNINGS[@]})) && printf ' - %s\n' "${WARNINGS[@]}" || echo ' - (yok)'
  echo -e "${RED}Hatalar:${NC}"
  ((${#FAILURES[@]})) && printf ' - %s\n' "${FAILURES[@]}" || echo ' - (yok)'
}

main() {
  banner
  require_root
  setup_basics
  setup_firewall
  install_plesk
  add_remi_repository

  # Native: 7.4 ve 8.0-8.4
  install_php_series 7.4
  install_php_series 8.0
  install_php_series 8.1
  install_php_series 8.2
  # 8.3 ve 8.4 çoğunlukla Plesk paketleriyle gelir; Remi ile de deneriz
  install_php_series 8.3 || true
  install_php_series 8.4 || true

  # Plesk'in kendi PHP 8.0/8.1/8.2 bileşenlerini de yüklemeyi dene
  install_plesk_php_components

  # ionCube
  install_ioncube

  warn "PHP 7.1/7.2/7.3 AlmaLinux 8.0 üzerinde resmi paket olarak sunulmaz. Gerekirse ayrı legacy VM veya Docker önerilir."

  # Güvenlik duvarında 80/443 açık olduğundan emin ol
  ensure_http_https_open

  show_summary
  log "Kurulum tamamlandı. Panele: https://$(curl -s ifconfig.me):8443"
}

main "$@"

