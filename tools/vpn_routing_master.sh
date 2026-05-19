#!/bin/bash
# Master script for OpenWRT VPN routing management
# Provides menu-driven interface for all VPN routing operations

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

show_menu() {
    clear
    echo "╔════════════════════════════════════════════════════════╗"
    echo "║     OpenWRT VPN Routing Management                     ║"
    echo "║     VPS: 89.125.92.10 | Router: 192.168.1.1           ║"
    echo "╚════════════════════════════════════════════════════════╝"
    echo ""
    echo "1) Quick Fix - Repair existing VPN routing"
    echo "2) Full Setup - Install WireGuard tunnel (recommended)"
    echo "3) Diagnostics - Check current configuration"
    echo "4) Generic VPN Fix - For OpenVPN or other VPN types"
    echo "5) View README - Full documentation"
    echo "6) Backup OpenWRT configuration"
    echo "7) Exit"
    echo ""
    read -p "Select option [1-7]: " choice
}

backup_config() {
    echo "Creating backup..."
    BACKUP_FILE="openwrt_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    ssh root@192.168.1.1 "sysupgrade -b /tmp/backup.tar.gz"
    scp root@192.168.1.1:/tmp/backup.tar.gz "./$BACKUP_FILE"
    echo "✓ Backup saved: $BACKUP_FILE"
    read -p "Press Enter to continue..."
}

run_diagnostics() {
    echo "Running diagnostics..."
    bash "$SCRIPT_DIR/diagnose_openwrt_routing.sh" | tee "diagnostic_$(date +%Y%m%d_%H%M%S).log"
    echo ""
    echo "✓ Diagnostic log saved"
    read -p "Press Enter to continue..."
}

quick_fix() {
    echo "Running quick fix..."
    bash "$SCRIPT_DIR/quick_fix_routing.sh"
    echo ""
    read -p "Press Enter to continue..."
}

full_setup() {
    echo "Starting full WireGuard setup..."
    echo "⚠️  This will:"
    echo "   - Install WireGuard on OpenWRT and VPS"
    echo "   - Generate encryption keys"
    echo "   - Configure routing for all clients"
    echo ""
    read -p "Continue? (yes/no): " confirm
    if [ "$confirm" = "yes" ]; then
        bash "$SCRIPT_DIR/setup_wireguard_tunnel.sh"
    else
        echo "Cancelled"
    fi
    read -p "Press Enter to continue..."
}

generic_fix() {
    echo "Running generic VPN fix..."
    bash "$SCRIPT_DIR/fix_openwrt_vpn_routing.sh"
    echo ""
    read -p "Press Enter to continue..."
}

view_readme() {
    if command -v less &> /dev/null; then
        less "$SCRIPT_DIR/README_VPN_ROUTING.md"
    else
        cat "$SCRIPT_DIR/README_VPN_ROUTING.md"
        read -p "Press Enter to continue..."
    fi
}

# Make all scripts executable
chmod +x "$SCRIPT_DIR"/*.sh 2>/dev/null || true

# Main loop
while true; do
    show_menu
    case $choice in
        1)
            quick_fix
            ;;
        2)
            full_setup
            ;;
        3)
            run_diagnostics
            ;;
        4)
            generic_fix
            ;;
        5)
            view_readme
            ;;
        6)
            backup_config
            ;;
        7)
            echo "Goodbye!"
            exit 0
            ;;
        *)
            echo "Invalid option"
            sleep 2
            ;;
    esac
done
