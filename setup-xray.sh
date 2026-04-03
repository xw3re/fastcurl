#!/bin/bash
# setup-xray.sh — instala e configura Xray (VLESS/xhttp/TLS) + badvpn-udpgw
# uso: sudo bash setup-xray.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }

[ "$EUID" -ne 0 ] && err "roda como root: sudo bash $0"

# ─── variáveis ────────────────────────────────────────────────────────────────
XRAY_PORT=443
UDPGW_PORT=7300
SSL_DIR=/etc/xray/ssl
XRAY_CONF=/usr/local/etc/xray/config.json
AZION_HOST="oracle.azion.app"
FRONTING_HOST="m.ofertas.tim.com.br"
SNI_HOST="www.tim.com.br"

# ─── dependências ─────────────────────────────────────────────────────────────
log "atualizando pacotes e instalando dependências..."
apt update -y
apt install -y curl cmake git libssl-dev iptables-persistent netfilter-persistent openssl

# ─── xray ─────────────────────────────────────────────────────────────────────
log "instalando xray..."
bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

UUID=$(xray uuid)
log "UUID gerado: ${YELLOW}$UUID${NC}"

# ─── certificado self-signed ──────────────────────────────────────────────────
log "gerando certificado self-signed..."
mkdir -p "$SSL_DIR"
openssl req -x509 -newkey rsa:2048 \
  -keyout "$SSL_DIR/key.pem" \
  -out    "$SSL_DIR/cert.pem" \
  -days 365 -nodes \
  -subj "/CN=$AZION_HOST"
chmod 644 "$SSL_DIR/key.pem" "$SSL_DIR/cert.pem"

# ─── config xray ─────────────────────────────────────────────────────────────
log "configurando xray..."
cat > "$XRAY_CONF" << EOF
{
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": $XRAY_PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$UUID", "flow": ""}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "xhttp",
      "security": "tls",
      "tlsSettings": {
        "certificates": [{
          "certificateFile": "$SSL_DIR/cert.pem",
          "keyFile": "$SSL_DIR/key.pem"
        }]
      },
      "xhttpSettings": {
        "path": "/"
      }
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF

systemctl enable xray
systemctl restart xray

# ─── badvpn-udpgw ────────────────────────────────────────────────────────────
log "compilando badvpn-udpgw..."
cd /tmp
rm -rf badvpn
git clone --depth=1 https://github.com/ambrop72/badvpn.git
cd badvpn
mkdir build && cd build
cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1
make
cp udpgw/badvpn-udpgw /usr/local/bin/
cd / && rm -rf /tmp/badvpn

log "configurando serviço udpgw..."
cat > /etc/systemd/system/udpgw.service << EOF
[Unit]
Description=BadVPN UDP Gateway
After=network.target

[Service]
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:$UDPGW_PORT --max-clients 500 --max-connections-for-client 10
Restart=always
User=nobody

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable udpgw
systemctl start udpgw

# ─── firewall ────────────────────────────────────────────────────────────────
log "abrindo portas no iptables..."
iptables -I INPUT -p tcp --dport $XRAY_PORT -j ACCEPT
iptables -I INPUT -p tcp --dport $UDPGW_PORT -j ACCEPT
netfilter-persistent save

# ─── gera URL VLESS ──────────────────────────────────────────────────────────
VLESS_URL="vless://${UUID}@${FRONTING_HOST}:${XRAY_PORT}?mode=auto&path=%2F&security=tls&encryption=none&host=${AZION_HOST}&type=xhttp&sni=${SNI_HOST}#Tim-Oracle"

# ─── resultado final ──────────────────────────────────────────────────────────
sleep 1

XRAY_STATUS=$(systemctl is-active xray  2>/dev/null || echo "falhou")
UDPGW_STATUS=$(systemctl is-active udpgw 2>/dev/null || echo "falhou")

[ "$XRAY_STATUS"  = "active" ] && XRAY_COLOR=$GREEN  || XRAY_COLOR=$RED
[ "$UDPGW_STATUS" = "active" ] && UDPGW_COLOR=$GREEN || UDPGW_COLOR=$RED

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════${NC}"
echo -e "  Xray:   ${XRAY_COLOR}${XRAY_STATUS}${NC}"
echo -e "  udpgw:  ${UDPGW_COLOR}${UDPGW_STATUS}${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${YELLOW}UUID:${NC}     $UUID"
echo -e "  ${YELLOW}udpgw:${NC}    127.0.0.1:$UDPGW_PORT"
echo ""
echo -e "  ${YELLOW}VLESS URL:${NC}"
echo -e "  ${CYAN}$VLESS_URL${NC}"
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════${NC}"
echo ""
warn "lembra de configurar a origem na Azion: HTTPS, porta 443, sem verificar cert"
