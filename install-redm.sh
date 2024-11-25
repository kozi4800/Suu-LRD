#!/bin/bash

# Fonctions de base
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

check_os() {
    if ! [[ -f /etc/debian_version ]]; then
        log "This script requires Debian/Ubuntu"
        exit 1
    fi
}

# Menu simple
show_menu() {
    while true; do
        echo -e "\nRedM Server Management"
        echo "1) Install"
        echo "2) Exit"
        read -p "Choose: " choice
        
        case $choice in
            1) check_os ;;
            2) exit 0 ;;
        esac
    done
}

# Main
if [[ $EUID -ne 0 ]]; then
   log "This script must be run as root"
   exit 1
fi

show_menu
