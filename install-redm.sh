#!/bin/bash

# Colors and logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
LOG_FILE="redm_install.log"
BACKUP_DIR="backups"
MAX_BACKUPS=5
MIN_DISK_SPACE=5

log() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$message" >> "$LOG_FILE"
    echo -e "$message"
}

check_disk_space() {
    local free_space=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    if [ "$free_space" -lt "$MIN_DISK_SPACE" ]; then
        log "${RED}Error: Insufficient disk space. Need at least ${MIN_DISK_SPACE}GB free.${NC}"
        return 1
    fi
    return 0
}

configure_firewall() {
    log "${GREEN}Configuring firewall...${NC}"
    apt-get install -y ufw
    ufw --force enable
    ufw allow 22/tcp
    ufw allow 30120/tcp
    ufw allow 30120/udp
    ufw allow 40120/tcp
    
    read -p "Do you want to restrict MariaDB and phpMyAdmin access to specific IPs? (y/n): " restrict_access
    if [ "$restrict_access" = "y" ]; then
        read -p "Enter allowed IP address: " allowed_ip
        ufw allow from "$allowed_ip" to any port 3306
        ufw allow from "$allowed_ip" to any port 8080
    else
        ufw allow 3306/tcp
        ufw allow 8080/tcp
    fi
    
    ufw status >> "$LOG_FILE"
}

monitor_resources() {
    docker stats --no-stream "$1" | tee -a "$LOG_FILE"
}

rotate_backups() {
    local backup_count
    backup_count=$(ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l)
    if [ "$backup_count" -gt "$MAX_BACKUPS" ]; then
        ls -t "$BACKUP_DIR"/*.tar.gz | tail -n +"$((MAX_BACKUPS+1))" | xargs rm
        log "Removed old backups, keeping latest $MAX_BACKUPS"
    fi
}

backup_data() {
    mkdir -p "$BACKUP_DIR"
    timestamp=$(date +%Y%m%d_%H%M%S)
    tar -czf "$BACKUP_DIR/redm_backup_$timestamp.tar.gz" config txData mysql 2>/dev/null
    rotate_backups
    log "Backup created: $BACKUP_DIR/redm_backup_$timestamp.tar.gz"
}

restore_backup() {
    log "Restoring from backup: $1"
    docker-compose down
    tar -xzf "$1"
    docker-compose up -d
}

validate_input() {
    local var_name="$1"
    local var_value="$2"
    
    case $var_name in
        "MYSQL_ROOT_PASSWORD"|"MYSQL_PASSWORD")
            if [ ${#var_value} -lt 8 ]; then
                log "${RED}Password must be at least 8 characters long${NC}"
                return 1
            fi
            ;;
        "TIMEZONE")
            if ! timedatectl list-timezones | grep -q "^$var_value$"; then
                log "${RED}Invalid timezone${NC}"
                return 1
            fi
            ;;
        "FIVEM_VERSION")
            if [ "$var_value" != "latest" ] && ! [[ $var_value =~ ^[0-9]+$ ]]; then
                log "${RED}Version must be 'latest' or a number${NC}"
                return 1
            fi
            ;;
    esac
    return 0
}

start_server() {
    docker-compose up -d
    sleep 5
    docker attach redm
}

install_server() {
    if ! [[ -f /etc/debian_version ]]; then
        log "${RED}This script requires Debian/Ubuntu${NC}"
        exit 1
    fi

    check_disk_space || exit 1

    if [ -f .env ]; then
        source .env
    else
        cat > .env << EOL
MYSQL_ROOT_PASSWORD=
MYSQL_DATABASE=redm
MYSQL_USER=redmuser
MYSQL_PASSWORD=
TIMEZONE=Europe/Paris
FIVEM_VERSION=latest
EOL
        log "${GREEN}.env file created with default values${NC}"
    fi

    log "Installing Docker..."
    apt-get update
    apt-get install -y docker.io

    log "Installing Docker Compose..."
    apt-get install -y docker-compose

    if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
        while true; do
            read -s -p "Enter root password for MariaDB: " MYSQL_ROOT_PASSWORD
            echo
            if validate_input "MYSQL_ROOT_PASSWORD" "$MYSQL_ROOT_PASSWORD"; then
                break
            fi
        done
    fi

    if [ -z "$MYSQL_PASSWORD" ]; then
        while true; do
            read -s -p "Enter database user password: " MYSQL_PASSWORD
            echo
            if validate_input "MYSQL_PASSWORD" "$MYSQL_PASSWORD"; then
                break
            fi
        done
    fi

    echo "Common Timezones:"
    echo "Europe:"
    echo "1) Europe/Paris"
    echo "2) Europe/London"
    echo "3) Europe/Berlin"
    echo ""
    echo "United States:"
    echo "4) America/New_York     (EST/EDT - Eastern)"
    echo "5) America/Chicago      (CST/CDT - Central)"
    echo "6) America/Denver       (MST/MDT - Mountain)"
    echo "7) America/Los_Angeles  (PST/PDT - Pacific)"
    echo "8) America/Phoenix      (MST - Arizona)"
    echo ""
    echo "Asia/Pacific:"
    echo "9) Asia/Tokyo"
    echo "10) Australia/Sydney"
    echo "11) Pacific/Auckland"

    read -p "Enter timezone (e.g., Europe/Paris): " TIMEZONE

    echo "Select FiveM version:"
    echo "1) Latest version (recommended)"
    echo "2) Specific version"
    read -p "Choose (1/2): " version_choice

    if [ "$version_choice" = "2" ]; then
        while true; do
            read -p "Enter FiveM version number: " FIVEM_VERSION
            if validate_input "FIVEM_VERSION" "$FIVEM_VERSION"; then
                break
            fi
        done
    else
        FIVEM_VERSION="latest"
    fi

    cat > .env << "EOL"
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
MYSQL_DATABASE=${MYSQL_DATABASE}
MYSQL_USER=${MYSQL_USER}
MYSQL_PASSWORD=${MYSQL_PASSWORD}
TIMEZONE=${TIMEZONE}
FIVEM_VERSION=${FIVEM_VERSION}
EOL

    cat > docker-compose.yml << "EOL"
version: "3.9"

services:
    redm:
        image: spritsail/fivem:${FIVEM_VERSION}
        container_name: redm
        environment:
            - NO_LICENSE_KEY=1
            - NO_DEFAULT_CONFIG=1
            - PUID=0
            - PGID=0
        volumes:
            - ./config:/config
            - ./txData:/txData
            - ./config/server.cfg:/config/server.cfg
        ports:
            - '40120:40120'
            - '30120:30120'
            - '30120:30120/udp'
        restart: always
        depends_on:
            - redm_db
        command: +exec /config/server.cfg

    redm_db:
        image: mariadb:10.4.32
        container_name: redm_db
        environment:
            - PUID=0
            - PGID=0
            - MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
            - TZ=${TIMEZONE}
            - MYSQL_DATABASE=${MYSQL_DATABASE}
            - MYSQL_USER=${MYSQL_USER}
            - MYSQL_PASSWORD=${MYSQL_PASSWORD}
        command: --sql_mode=NO_ZERO_IN_DATE,NO_ZERO_DATE,NO_ENGINE_SUBSTITUTION
        ports:
            - 3306:3306
        volumes:
            - ./mysql:/var/lib/mysql
        restart: always

    phpmyadmin:
        image: phpmyadmin
        restart: always
        ports:
            - 8080:80
        environment:
            - PMA_ARBITRARY=1
            - UPLOAD_LIMIT=100M
        depends_on:
            - redm_db
EOL

    mkdir -p config
    cat > config/server.cfg << "EOL"
endpoint_add_tcp "0.0.0.0:30120"
endpoint_add_udp "0.0.0.0:30120"
set mysql_connection_string "mysql://${MYSQL_USER}:${MYSQL_PASSWORD}@redm_db/${MYSQL_DATABASE}?charset=utf8mb4"
EOL

    configure_firewall

    log "Starting installation..."
    if ! docker-compose up -d; then
        log "${RED}Installation failed${NC}"
        read -p "Do you want to restore from the last backup? (y/n): " restore_choice
        if [ "$restore_choice" = "y" ]; then
            latest_backup=$(ls -t backups/*.tar.gz 2>/dev/null | head -1)
            if [ -n "$latest_backup" ]; then
                restore_backup "$latest_backup"
            else
                log "${RED}No backup found${NC}"
            fi
        fi
        exit 1
    fi

    log "${GREEN}Installation complete!${NC}"
}

show_menu() {
    while true; do
        echo -e "\n${GREEN}RedM Server Management${NC}"
        echo "1) Setup New Server"
        echo "2) Start Server"
        echo "3) Stop Server"
        echo "4) Restart Server"
        echo "5) Create Backup"
        echo "6) Restore Backup"
        echo "7) View Logs"
        echo "8) Monitor Resources"
        echo "9) Update Server"
        echo "10) Exit"
        
        read -p "Choose an option: " choice
        
        case $choice in
            1) install_server ;;
            2) start_server ;;
            3) docker-compose down ;;
            4) docker-compose restart ;;
            5) backup_data ;;
            6)
                ls -1 "$BACKUP_DIR"
                read -p "Enter backup filename: " backup_file
                restore_backup "$BACKUP_DIR/$backup_file"
                ;;
            7) tail -f "$LOG_FILE" ;;
            8) monitor_resources "redm" ;;
            9)
                backup_data
                docker-compose pull
                docker-compose up -d
                ;;
            10) exit 0 ;;
            *) log "${RED}Invalid option${NC}" ;;
        esac
    done
}

if [[ $EUID -ne 0 ]]; then
   log "${RED}This script must be run as root${NC}"
   exit 1
fi

if [ -f "docker-compose.yml" ]; then
    show_menu
else
    install_server
    show_menu
fi
