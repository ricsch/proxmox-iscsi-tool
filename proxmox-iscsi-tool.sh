#!/bin/bash
# Skript: configure-multipath_whiptail.sh
# Dieses Skript nutzt Whiptail, um interaktiv die Konfiguration für mehrere
# iSCSI-Verbindungen und die zugehörigen WWID/Alias-Paare zu erfassen.
#
# Anschließend werden:
# - Die iSCSI-Verbindungen via pvesm eingebunden.
# - multipath-tools installiert (falls nicht vorhanden).
# - Eine neue /etc/multipath.conf mit den WWID/Alias-Konfigurationen erstellt.
#
# Hinweis: Das Skript muss als root ausgeführt werden.

#############################################
# Funktionen
#############################################

# Prüft, ob das Skript als root ausgeführt wird.
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Bitte führen Sie dieses Skript als root aus."
        exit 1
    fi
}

# Prüft, ob Whiptail installiert ist.
check_whiptail() {
    if ! command -v whiptail >/dev/null 2>&1; then
        echo "whiptail ist nicht installiert. Bitte installieren Sie es und führen Sie das Skript erneut aus."
        exit 1
    fi
}

# Zeigt eine Fehlermeldung und beendet das Skript.
error_exit() {
    echo "$1" >&2
    exit 1
}

# Hauptmenü
main_menu(){
    MAINMENU=$(whiptail --title "Proxmox iSCSI Multipath Tool" --menu "Was möchtest du erledigen?" 25 78 16 \
    "Install" "Install Multipath and add iSCSI LUNs" \
    "Add" "Add iSCSI LUN" \
    "Remove" "Remove iSCSI LUN" 3>&1 1>&2 2>&3)
    exitstatus=$?
    if [ $exitstatus = 0 ]; then
    	echo "Your chosen option:" $MAINMENU
    else
        echo "You chose Cancel."
    fi
    case $MAINMENU in
	Install)
	collect_inputs
	install_iscsi_tools
	bind_iscsi_luns
	install_multipath_tools
	backup_multipath_conf
	create_multipath_conf
	restart_multipath_service
	;;

	Add)
	collect_inputs
    bind_iscsi_luns
    backup_multipath_conf
    add_multipath_entry
	;;

	Remove)
    backup_multipath_conf
    remove_multipath_entry
	;;
esac
}

# Sammelt interaktiv die iSCSI-Parameter und WWID/Alias-Paare.
collect_inputs() {
    # Gemeinsame iSCSI-Parameter
    PORTAL=$(whiptail --title "Eingabefenster" --inputbox "iSCSI-Portal eingeben (nur eines, auch wenn redundante Pfade genutzt werden sollen)" 10 50 3>&1 1>&2 2>&3)
    [ -z "$PORTAL" ] && error_exit "Kein iSCSI-Portal angegeben."

    NUM_ENTRIES=$(whiptail --inputbox "Wie viele iSCSI-Einträge möchten Sie konfigurieren?" 8 60 "1" --title "Anzahl der Einträge" 3>&1 1>&2 2>&3)
    if [ -z "$NUM_ENTRIES" ] || ! [[ "$NUM_ENTRIES" =~ ^[0-9]+$ ]]; then
        error_exit "Ungültige Anzahl an Einträgen."
    fi

    # Initialisiere Arrays (global)
    iscsi_params=()       # Format: BASE_STORAGE_ID|TARGET|LUN
    wwid_alias_pairs=()   # Format: WWID:Alias

    for (( i=1; i<=NUM_ENTRIES; i++ )); do
        iscsi_params=$(whiptail --inputbox "Eintrag $i:\nGeben Sie die BASE_STORAGE_ID ein (z.B. iscsi-storage1), dann das iSCSI-Target ein (z.B. iqn.2001-04.com.example:storage.target und zuletzt die LUN (z.B. 1). Bitte | als Trenner nutzen. Keine Leerzeichen. Danke. Also BASE_STORAGE_ID|TARGET|LUN:" 20 60 "" --title "BASE_STORAGE_ID" 3>&1 1>&2 2>&3)
        WWID=$(whiptail --inputbox "Eintrag $i:\nGeben Sie die WWID ein (z.B. 36001405abcd1234):" 10 60 "" --title "WWID" 3>&1 1>&2 2>&3)
        ALIAS=$(whiptail --inputbox "Eintrag $i:\nGeben Sie den Alias ein (z.B. mydisk1):" 10 60 "" --title "Alias" 3>&1 1>&2 2>&3)

        # Minimalvalidierung der Eingaben
        if [ -z "$iscsi_params" ] || [ -z "$WWID" ] || [ -z "$ALIAS" ]; then
            error_exit "Alle Felder müssen ausgefüllt werden. Abbruch."
        fi
        wwid_alias_pairs+=("${WWID}:${ALIAS}")
    done
}

# Prüft und installiert open-iscsi, falls iscsiadm nicht vorhanden ist.
install_iscsi_tools() {
    if ! command -v iscsiadm >/dev/null 2>&1; then
        echo "iscsiadm wurde nicht gefunden. Installation von open-iscsi wird gestartet..."
        apt-get update && apt-get install -y open-iscsi || error_exit "Installation von open-iscsi fehlgeschlagen."
    else
        echo "iscsiadm ist bereits installiert."
    fi
}

# Bindet die iSCSI-LUNs mit pvesm ein.
bind_iscsi_luns() {
    for idx in "${!iscsi_params[@]}"; do
        IFS="|" read -r BASE_STORAGE_ID TARGET LUN <<< "${iscsi_params[$idx]}"
        STORAGE_ID="${BASE_STORAGE_ID}"  # Direkt aus dem Array
        echo "Binde iSCSI-Target '$TARGET' mit LUN '$LUN' ein (Storage-ID: $STORAGE_ID)..."
        pvesm add iscsi "${STORAGE_ID}" --portal "${PORTAL}" --target "${TARGET}" --lun "${LUN}"
    done
}

# Prüft und installiert multipath-tools, falls nicht vorhanden.
install_multipath_tools() {
    if ! dpkg -s multipath-tools >/dev/null 2>&1; then
        echo "multipath-tools werden nicht gefunden. Installation wird gestartet..."
        apt-get update && apt-get install -y multipath-tools || error_exit "Installation von multipath-tools fehlgeschlagen."
    else
        echo "multipath-tools sind bereits installiert."
    fi
}

# Sichert die vorhandene multipath.conf, falls vorhanden.
backup_multipath_conf() {
    if [ -f /etc/multipath.conf ]; then
        BACKUP="/etc/multipath.conf.backup.$(date +%Y%m%d%H%M%S)"
        echo "Sichere vorhandene /etc/multipath.conf unter: $BACKUP"
        cp /etc/multipath.conf "$BACKUP" || error_exit "Backup fehlgeschlagen."
    fi
}

# Erstellt die neue multipath.conf unter Einbindung der WWID/Alias-Konfigurationen.
create_multipath_conf() {
    echo "Erstelle neue /etc/multipath.conf..."
    cat > /etc/multipath.conf <<EOF
defaults {
    user_friendly_names yes
    find_multipaths yes
}

blacklist {
    devnode "^(ram|raw|loop|fd|md|dm-|sr|scd|st)[0-9]*"
    devnode "^sda"
}

blacklist_exceptions {
    device {
        vendor  "Nimble"
        product "Server"
    }
}

devices {
    device {
        vendor               "Nimble"
        product              "Server"
        path_grouping_policy group_by_prio
        prio                 "alua"
        hardware_handler     "1 alua"
        path_selector        "service-time 0"
        path_checker         tur
        no_path_retry        "queue"
        failback             immediate
        fast_io_fail_tmo     5
        dev_loss_tmo         infinity
        rr_min_io_rq         1
        rr_weight            uniform
    }
}

multipaths {
EOF

    for pair in "${wwid_alias_pairs[@]}"; do
        IFS=":" read -r WWID ALIAS <<< "$pair"
        cat >> /etc/multipath.conf <<EOF
    multipath {
        wwid "$WWID"
        alias "$ALIAS"
    }
EOF
    done

    cat >> /etc/multipath.conf <<'EOF'
}
EOF
    echo "Neue Konfiguration in /etc/multipath.conf geschrieben."
    echo "=== Multipath Konfiguration abgeschlossen ==="
}

# Startet den Multipath-Dienst neu und zeigt den Status an.
restart_multipath_service() {
    echo "Multipath-Dienst wird neu gestartet..."
    systemctl restart multipath-tools || error_exit "Neustart von multipath-tools fehlgeschlagen."
    echo "Aktueller Multipath-Status:"
    multipath -ll
}

# Fügt einen neuen Multipath-Eintrag in die multipaths-Sektion der /etc/multipath.conf ein.
add_multipath_entry() {
    # Füge den neuen Eintrag vor der letzten Zeile der multipath.conf ein.
    # Wir gehen davon aus, dass die letzte Zeile die schließende Klammer "}" des multipaths-Blocks ist.
    for pair in "${wwid_alias_pairs[@]}"; do
        IFS=":" read -r WWID ALIAS <<< "$pair"
    sed -i "\$i\\
    multipath {\\
        wwid \"$NWWID\"\\
        alias \"$ALIAS\"\\
    }" /etc/multipath.conf
    done

    whiptail --msgbox "Neuer Multipath-Eintrag wurde hinzugefügt." 10 50 --title "Erfolg"
}

remove_multipath_entry() {
    # Abfrage des WWID mittels Whiptail
    local target_wwid
    target_wwid=$(whiptail --inputbox "Geben Sie die WWID des Multipath-Eintrags ein, der entfernt werden soll:" 10 60 "" --title "Multipath entfernen" 3>&1 1>&2 2>&3)
    
    if [ -z "$target_wwid" ]; then
        error_exit "Keine WWID eingegeben. Abbruch."
    fi

    # Erstelle eine neue Version der multipath.conf, in der der Multipath-Block
    # mit der übergebenen WWID nicht enthalten ist.
    awk -v wwid="$target_wwid" '
    BEGIN { in_block = 0; block = "" }
    {
      # Erkenne den Beginn eines multipath-Blocks
      if ($0 ~ /^[[:space:]]*multipath[[:space:]]*{/) {
         in_block = 1;
         block = $0 "\n";
         next;
      }
      # Falls wir uns in einem multipath-Block befinden, sammle die Zeilen
      if (in_block) {
         block = block $0 "\n";
         # Erkenne das Ende des Blocks
         if ($0 ~ /^[[:space:]]*}/) {
            in_block = 0;
            # Enthält der Block die Ziel-WWID, so wird er verworfen (also nicht ausgegeben)
            if (block ~ wwid) {
               block = "";
               next;
            } else {
               # Andernfalls gib den gesamten Block aus
               printf "%s", block;
               block = "";
               next;
            }
         }
         next;
      }
      # Alle anderen Zeilen werden unverändert ausgegeben
      print $0;
    }
    ' /etc/multipath.conf > /tmp/multipath.conf.new || return 1

    # Überschreibe die Originaldatei mit der neuen Version
    mv /tmp/multipath.conf.new /etc/multipath.conf || return 1

    whiptail --msgbox "Multipath-Eintrag mit WWID '$target_wwid' wurde entfernt (falls vorhanden)." 10 60 --title "Erfolg"
}


#############################################
# Hauptprogramm
#############################################

check_root
check_whiptail

echo "=== Interaktive Konfiguration mit Whiptail wird gestartet ==="

main_menu

