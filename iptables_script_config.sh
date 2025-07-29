#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/firewall.conf"
BACKUP_FILE="/tmp/iptables_backup_$(date +%Y%m%d_%H%M%S).rules"
LOG_FILE="/var/log/firewall_config.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${2:-$NC}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERREUR: $1" "$RED"
    restore_backup
    exit 1
}

backup_current_rules() {
    log "Sauvegarde des règles actuelles..." "$YELLOW"
    iptables-save > "$BACKUP_FILE"
    log "Sauvegarde créée : $BACKUP_FILE" "$GREEN"
}

restore_backup() {
    if [[ -f "$BACKUP_FILE" ]]; then
        log "Restauration des règles précédentes..." "$YELLOW"
        iptables-restore < "$BACKUP_FILE"
        log "Règles restaurées avec succès" "$GREEN"
    fi
}

setup_safety_timer() {
    local duration=${1:-180}
    log "Mise en place du minuteur de sécurité ($duration secondes)..." "$YELLOW"
    CURRENT_SSH_PORT=$(ss -tuln | grep ':22 ' >/dev/null && echo "22" || ss -tuln | grep -o ':[0-9]*' | grep -v ':80\|:443\|:53' | head -1 | cut -d: -f2)    
    cat > /tmp/firewall_restore.sh << EOF
#!/bin/bash
sleep $duration
if [[ -f "$BACKUP_FILE" ]]; then
    iptables -I INPUT 1 -p tcp --dport ${CURRENT_SSH_PORT:-22} -j ACCEPT 2>/dev/null || true
    iptables -I INPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    iptables-restore < "$BACKUP_FILE"
    echo "[$(date)] Restauration automatique effectuée (SSH protégé sur port ${CURRENT_SSH_PORT:-22})" >> "$LOG_FILE"
    wall "FIREWALL: Restauration automatique effectuée - connexions restaurées" 2>/dev/null || true
fi
rm -f /tmp/firewall_restore.sh
EOF
    
    chmod +x /tmp/firewall_restore.sh
    nohup /tmp/firewall_restore.sh >/dev/null 2>&1 &
    SAFETY_PID=$!
    
    log "Minuteur de sécurité activé (PID: $SAFETY_PID)" "$GREEN"
    log "SÉCURITÉ: Les règles seront automatiquement restaurées dans $duration secondes" "$YELLOW"
    log "Votre connexion SSH actuelle sur le port ${CURRENT_SSH_PORT:-22} est protégée" "$YELLOW"
}

cancel_safety_timer() {
    if [[ -n "$SAFETY_PID" ]]; then
        kill $SAFETY_PID 2>/dev/null || true
        rm -f /tmp/firewall_restore.sh
        log "Minuteur de sécurité annulé" "$GREEN"
    fi
}

detect_network() {
    INTERFACE=$(ip route | grep default | head -1 | awk '{print $5}')
    IP_LOCAL=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    IP_PUBLIQUE=$(timeout 10 curl -s https://ipinfo.io/ip 2>/dev/null || echo "Indisponible")    
    log "=== Informations Réseau ===" "$BLUE"
    log "Interface réseau : $INTERFACE"
    log "IP locale        : $IP_LOCAL"
    log "IP publique      : $IP_PUBLIQUE"
    log "===========================" "$BLUE"
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        log "Chargement de la configuration depuis $CONFIG_FILE" "$BLUE"
        source "$CONFIG_FILE"
        return 0
    fi
    return 1
}

save_config() {
    log "Sauvegarde de la configuration dans $CONFIG_FILE" "$BLUE"
    cat > "$CONFIG_FILE" << EOF
# Configuration du pare-feu - $(date)
INTERFACE="$INTERFACE"
IP_LOCAL="$IP_LOCAL"
ENABLE_SSH="$ENABLE_SSH"
SSH_PORT="$SSH_PORT"
ENABLE_HTTP="$ENABLE_HTTP"
ENABLE_HTTPS="$ENABLE_HTTPS"
ENABLE_PING="$ENABLE_PING"
CUSTOM_TCP_PORTS=("${CUSTOM_TCP_PORTS[@]}")
CUSTOM_UDP_PORTS=("${CUSTOM_UDP_PORTS[@]}")
ALLOWED_IPS=("${ALLOWED_IPS[@]}")
BLOCKED_IPS=("${BLOCKED_IPS[@]}")
ENABLE_RATE_LIMITING="$ENABLE_RATE_LIMITING"
ENABLE_LOG_DENIED="$ENABLE_LOG_DENIED"
EOF
}

interactive_config() {
    log "=== Configuration Interactive ===" "$BLUE"
    read -p "Autoriser SSH ? [O/n] " -n 1 -r
    echo
    ENABLE_SSH=${REPLY:-o}    
    if [[ "$ENABLE_SSH" =~ ^[Oo]$ ]]; then
        read -p "Port SSH [22] : " SSH_PORT
        SSH_PORT=${SSH_PORT:-22}
    fi
    read -p "Autoriser HTTP (port 80) ? [o/N] " -n 1 -r
    echo
    ENABLE_HTTP=${REPLY:-n}
    read -p "Autoriser HTTPS (port 443) ? [o/N] " -n 1 -r
    echo
    ENABLE_HTTPS=${REPLY:-n}
    CUSTOM_TCP_PORTS=()
    while true; do
        read -p "Ajouter un port TCP personnalisé ? (numéro ou 'q' pour quitter) : " port
        [[ "$port" == "q" ]] && break
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            CUSTOM_TCP_PORTS+=("$port")
            log "Port TCP $port ajouté" "$GREEN"
        elif [[ -n "$port" ]]; then
            log "Port invalide : $port" "$RED"
        fi
    done

    CUSTOM_UDP_PORTS=()
    read -p "Ajouter des ports UDP ? [o/N] " -n 1 -r
    echo
    if [[ "$REPLY" =~ ^[Oo]$ ]]; then
        while true; do
            read -p "Port UDP (numéro ou 'q' pour quitter) : " port
            [[ "$port" == "q" ]] && break
            if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
                CUSTOM_UDP_PORTS+=("$port")
                log "Port UDP $port ajouté" "$GREEN"
            elif [[ -n "$port" ]]; then
                log "Port invalide : $port" "$RED"
            fi
        done
    fi
    
    ALLOWED_IPS=()
    read -p "Ajouter des IPs spécifiquement autorisées ? [o/N] " -n 1 -r
    echo
    if [[ "$REPLY" =~ ^[Oo]$ ]]; then
        while true; do
            read -p "IP autorisée (IP/CIDR ou 'q' pour quitter) : " ip
            [[ "$ip" == "q" ]] && break
            if [[ -n "$ip" ]]; then
                ALLOWED_IPS+=("$ip")
                log "IP $ip ajoutée aux autorisées" "$GREEN"
            fi
        done
    fi
    
    BLOCKED_IPS=()
    read -p "Ajouter des IPs à bloquer ? [o/N] " -n 1 -r
    echo
    if [[ "$REPLY" =~ ^[Oo]$ ]]; then
        while true; do
            read -p "IP à bloquer (IP/CIDR ou 'q' pour quitter) : " ip
            [[ "$ip" == "q" ]] && break
            if [[ -n "$ip" ]]; then
                BLOCKED_IPS+=("$ip")
                log "IP $ip ajoutée aux bloquées" "$RED"
            fi
        done
    fi
    
    read -p "Autoriser ICMP/ping ? [O/n] " -n 1 -r
    echo
    ENABLE_PING=${REPLY:-o}
    read -p "Activer la limitation de taux (protection DDoS) ? [O/n] " -n 1 -r
    echo
    ENABLE_RATE_LIMITING=${REPLY:-o}    
    read -p "Logger les connexions refusées ? [o/N] " -n 1 -r
    echo
    ENABLE_LOG_DENIED=${REPLY:-n}
}

apply_rules() {
    log "Application des règles de pare-feu..." "$YELLOW"
    CURRENT_SSH_PORT=$(netstat -tuln 2>/dev/null | grep ':22 ' >/dev/null && echo "22" || echo "${SSH_PORT:-22}")
    CURRENT_SSH_IP=$(who am i 2>/dev/null | awk '{print $5}' | tr -d '()' || echo "any")    
    log "Protection connexion SSH actuelle: port $CURRENT_SSH_PORT depuis $CURRENT_SSH_IP" "$GREEN"
    iptables -I INPUT 1 -i lo -j ACCEPT 2>/dev/null || true
    iptables -I INPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    if [[ "$CURRENT_SSH_IP" != "any" && "$CURRENT_SSH_IP" != "" ]]; then
        iptables -I INPUT 1 -p tcp -s "$CURRENT_SSH_IP" --dport "$CURRENT_SSH_PORT" -j ACCEPT 2>/dev/null || true
    else
        iptables -I INPUT 1 -p tcp --dport "$CURRENT_SSH_PORT" -j ACCEPT 2>/dev/null || true
    fi
    PROTECTION_RULES=$(iptables -L INPUT --line-numbers | grep -c "^[1-4]" || echo "0")
    if [[ "$PROTECTION_RULES" -gt 0 ]]; then
        for (( i=$(iptables -L INPUT --line-numbers | wc -l); i>$PROTECTION_RULES; i-- )); do
            iptables -D INPUT $i 2>/dev/null || true
        done
    fi
    iptables -F FORWARD 2>/dev/null || true
    iptables -F OUTPUT 2>/dev/null || true
    iptables -t nat -F 2>/dev/null || true
    iptables -t mangle -F 2>/dev/null || true
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT    
    log "Connexion SSH actuelle protégée pendant la reconfiguration" "$GREEN"
    for ip in "${ALLOWED_IPS[@]}"; do
        [[ -n "$ip" ]] && iptables -A INPUT -s "$ip" -j ACCEPT && log "IP autorisée : $ip" "$GREEN"
    done
    for ip in "${BLOCKED_IPS[@]}"; do
        [[ -n "$ip" ]] && iptables -A INPUT -s "$ip" -j DROP && log "IP bloquée : $ip" "$RED"
    done
    if [[ "$ENABLE_RATE_LIMITING" =~ ^[Oo]$ ]]; then
        iptables -A INPUT -p tcp --syn -m limit --limit 1/s --limit-burst 3 -j ACCEPT
        iptables -A INPUT -p tcp --syn -j DROP
        iptables -A INPUT -p tcp -m connlimit --connlimit-above 20 -j DROP        
        log "Protection anti-DDoS activée" "$GREEN"
    fi
    
    if [[ "$ENABLE_SSH" =~ ^[Oo]$ ]]; then
        if [[ "$ENABLE_RATE_LIMITING" =~ ^[Oo]$ ]]; then
            iptables -A INPUT -p tcp --dport "$SSH_PORT" -m conntrack --ctstate NEW -m recent --set
            iptables -A INPUT -p tcp --dport "$SSH_PORT" -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 4 -j DROP
        fi
        iptables -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
        log "SSH autorisé sur le port $SSH_PORT" "$GREEN"
    fi
    if [[ "$ENABLE_HTTP" =~ ^[Oo]$ ]]; then
        iptables -A INPUT -p tcp --dport 80 -j ACCEPT
        log "HTTP autorisé (port 80)" "$GREEN"
    fi
    if [[ "$ENABLE_HTTPS" =~ ^[Oo]$ ]]; then
        iptables -A INPUT -p tcp --dport 443 -j ACCEPT
        log "HTTPS autorisé (port 443)" "$GREEN"
    fi
    for port in "${CUSTOM_TCP_PORTS[@]}"; do
        [[ -n "$port" ]] && iptables -A INPUT -p tcp --dport "$port" -j ACCEPT && log "Port TCP personnalisé autorisé : $port" "$GREEN"
    done
    for port in "${CUSTOM_UDP_PORTS[@]}"; do
        [[ -n "$port" ]] && iptables -A INPUT -p udp --dport "$port" -j ACCEPT && log "Port UDP personnalisé autorisé : $port" "$GREEN"
    done
    if [[ "$ENABLE_PING" =~ ^[Oo]$ ]]; then
        iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
        log "ICMP/ping autorisé" "$GREEN"
    fi
    if [[ "$ENABLE_LOG_DENIED" =~ ^[Oo]$ ]]; then
        iptables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "FIREWALL-DENIED: " --log-level 4
        log "Logging des connexions refusées activé" "$GREEN"
    fi
    
    log "Règles appliquées avec succès" "$GREEN"
}

test_connectivity() {
    log "Test de connectivité..." "$YELLOW"
    
    if [[ "$ENABLE_SSH" =~ ^[Oo]$ ]]; then
        if ss -tuln | grep -q ":$SSH_PORT "; then
            log "Port SSH $SSH_PORT accessible" "$GREEN"
        else
            log "Port SSH $SSH_PORT non détecté" "$YELLOW"
        fi
    fi
    
    if timeout 5 nslookup google.com >/dev/null 2>&1; then
        log "Résolution DNS fonctionnelle" "$GREEN"
    else
        log "Problème de résolution DNS" "$YELLOW"
    fi
    
    if timeout 5 curl -s https://httpbin.org/ip >/dev/null 2>&1; then
        log "Connexion sortante HTTPS fonctionnelle" "$GREEN"
    else
        log "Problème de connexion sortante" "$YELLOW"
    fi
}

make_persistent() {
    log "Configuration de la persistance..." "$YELLOW"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update >/dev/null 2>&1
        apt-get install -y iptables-persistent >/dev/null 2>&1
        netfilter-persistent save
        log "Persistance configurée (Debian/Ubuntu)" "$GREEN"
    elif command -v yum >/dev/null 2>&1; then
        service iptables save
        log "Persistance configurée (RHEL/CentOS)" "$GREEN"
    else
        iptables-save > /etc/iptables/rules.v4
        log "Règles sauvegardées dans /etc/iptables/rules.v4" "$GREEN"
    fi
}

show_status() {
    log "=== État du Pare-feu ===" "$BLUE"
    iptables -L -v -n --line-numbers
    log "========================" "$BLUE"
}

show_menu() {
    echo
    log "=== Gestionnaire de Pare-feu Avancé ===" "$BLUE"
    echo "1) Configuration complète (recommandé)"
    echo "2) Charger configuration existante"
    echo "3) Configuration rapide (SSH + HTTP/HTTPS)"
    echo "4) Afficher le statut actuel"
    echo "5) Désactiver le pare-feu"
    echo "6) Restaurer la sauvegarde"
    echo "7) Quitter"
    log "=======================================" "$BLUE"
}

main() {
    [[ $EUID -ne 0 ]] && error_exit "Ce script doit être exécuté en tant que root"
    detect_network
    backup_current_rules
    while true; do
        show_menu
        read -p "Votre choix [1-7] : " choice
        
        case $choice in
            1)
                setup_safety_timer 300
                interactive_config
                save_config
                apply_rules
                test_connectivity
                
                echo
                log "Configuration appliquée. Testez votre connexion." "$YELLOW"
                read -p "La connexion fonctionne-t-elle correctement ? [O/n] " -n 1 -r
                echo
                
                if [[ "$REPLY" =~ ^[Oo]$|^$ ]]; then
                    cancel_safety_timer
                    read -p "Rendre les règles persistantes ? [O/n] " -n 1 -r
                    echo
                    [[ "$REPLY" =~ ^[Oo]$|^$ ]] && make_persistent
                    log "Configuration terminée avec succès !" "$GREEN"
                    break
                else
                    log "Restauration des règles précédentes..." "$YELLOW"
                    restore_backup
                    cancel_safety_timer
                fi
                ;;
                
            2)
                if load_config; then
                    setup_safety_timer 300
                    apply_rules
                    test_connectivity
                    
                    read -p "Confirmer ces règles ? [O/n] " -n 1 -r
                    echo
                    [[ "$REPLY" =~ ^[Oo]$|^$ ]] && cancel_safety_timer || restore_backup
                else
                    log "Aucune configuration trouvée" "$RED"
                fi
                ;;
                
            3)
                ENABLE_SSH="o"
                SSH_PORT="22"
                ENABLE_HTTP="o"
                ENABLE_HTTPS="o"
                ENABLE_PING="o"
                CUSTOM_TCP_PORTS=()
                CUSTOM_UDP_PORTS=()
                ALLOWED_IPS=()
                BLOCKED_IPS=()
                ENABLE_RATE_LIMITING="o"
                ENABLE_LOG_DENIED="n"
                
                setup_safety_timer 300
                save_config
                apply_rules
                
                read -p "Configuration rapide appliquée. Confirmer ? [O/n] " -n 1 -r
                echo
                [[ "$REPLY" =~ ^[Oo]$|^$ ]] && cancel_safety_timer && make_persistent || restore_backup
                ;;
                
            4)
                show_status
                ;;
                
            5)
                read -p "Êtes-vous sûr de vouloir désactiver le pare-feu ? [o/N] " -n 1 -r
                echo
                if [[ "$REPLY" =~ ^[Oo]$ ]]; then
                    iptables -F
                    iptables -X
                    iptables -P INPUT ACCEPT
                    iptables -P FORWARD ACCEPT
                    iptables -P OUTPUT ACCEPT
                    log "Pare-feu désactivé" "$YELLOW"
                fi
                ;;
                
            6)
                restore_backup
                ;;
                
            7)
                log "Au revoir !" "$GREEN"
                exit 0
                ;;
                
            *)
                log "Choix invalide" "$RED"
                ;;
        esac
        
        echo
        read -p "Appuyez sur Entrée pour continuer..."
    done
}
trap 'cancel_safety_timer; restore_backup; exit 1' INT TERM
main "$@"