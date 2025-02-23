#!/usr/bin/env perl
use strict;
use warnings;
use Curses::UI;
use POSIX qw(getuid);
use File::Copy;

# Prüfe, ob das Skript als root ausgeführt wird.
if (getuid() != 0) {
    die "Bitte führe dieses Skript als root aus.\n";
}

# Hilfsfunktion: Beendet das Skript mit einer Fehlermeldung.
sub error_exit {
    my ($msg) = @_;
    print STDERR "$msg\n";
    exit 1;
}

# Führt einen Shell-Befehl aus und prüft den Exit-Code.
sub run_command {
    my ($cmd) = @_;
    print "Executing: $cmd\n";
    system($cmd) == 0 or error_exit("Command failed: $cmd");
}

# Installiert open-iscsi, falls iscsiadm nicht vorhanden ist.
sub install_iscsi_tools {
    my $iscsiadm = `which iscsiadm`;
    if (!$iscsiadm) {
        run_command("apt-get update && apt-get install -y open-iscsi");
    }
    else {
        print "iscsiadm ist bereits installiert.\n";
    }
}

# Bindet iSCSI-LUNs mittels pvesm ein.
# Parameter: Arrayref von Hashrefs mit den Schlüsseln: base_storage_id, target, lun
#             sowie der gemeinsame Portal-Parameter.
sub bind_iscsi_luns {
    my ($entries, $portal) = @_;
    foreach my $entry (@$entries) {
        my $storage_id = $entry->{base_storage_id};
        my $target     = $entry->{target};
        my $lun        = $entry->{lun};
        print "Binde iSCSI-Target '$target' mit LUN '$lun' ein (Storage-ID: $storage_id)...\n";
        run_command("pvesm add iscsi \"$storage_id\" --portal \"$portal\" --target \"$target\" --lun \"$lun\"");
    }
}

# Installiert multipath-tools, falls nicht vorhanden.
sub install_multipath_tools {
    my $output = `dpkg -s multipath-tools 2>/dev/null`;
    if (!$output) {
        run_command("apt-get update && apt-get install -y multipath-tools");
    }
    else {
        print "multipath-tools sind bereits installiert.\n";
    }
}

# Sichert die vorhandene /etc/multipath.conf.
sub backup_multipath_conf {
    my $conf = "/etc/multipath.conf";
    if (-e $conf) {
        my $backup = $conf . ".backup." . time();
        print "Sichere $conf nach $backup\n";
        copy($conf, $backup) or error_exit("Backup fehlgeschlagen: $!");
    }
}

# Erstellt eine neue multipath.conf anhand gegebener Multipath-Einträge.
# Parameter: Arrayref von Hashrefs mit den Schlüsseln: wwid, alias
sub create_multipath_conf {
    my ($multipath_entries) = @_;
    my $conf = "/etc/multipath.conf";
    my $content = <<"EOF";
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

    foreach my $entry (@$multipath_entries) {
        $content .= "\n    multipath {\n";
        $content .= '        wwid "' . $entry->{wwid} . "\"\n";
        $content .= '        alias "' . $entry->{alias} . "\"\n";
        $content .= "    }\n";
    }
    $content .= "}\n";

    open(my $fh, ">", $conf) or error_exit("Fehler beim Öffnen von $conf: $!");
    print $fh $content;
    close($fh);
    print "Neue Konfiguration in $conf geschrieben.\n";
}

# Startet den Multipath-Dienst neu und zeigt den Status an.
sub restart_multipath_service {
    run_command("systemctl restart multipath-tools");
    print `multipath -ll`;
}

# Fügt einen neuen Multipath-Eintrag zum multipaths-Block in /etc/multipath.conf hinzu.
# Parameter: Neuer WWID und neuer Alias.
sub add_multipath_entry {
    my ($new_wwid, $new_alias) = @_;
    my $conf = "/etc/multipath.conf";
    open(my $fh, "<", $conf) or error_exit("Kann $conf nicht lesen: $!");
    my @lines = <$fh>;
    close($fh);
    # Neuen Eintrag als Block (wir nehmen an, dass die Datei mit "}\n" endet)
    my $new_entry = <<"EOP";
    multipath {
        wwid "$new_wwid"
        alias "$new_alias"
    }
EOP
    # Entferne die letzte Zeile (Schließende Klammer)
    my $last = pop @lines;
    push @lines, $new_entry, $last;
    open($fh, ">", $conf) or error_exit("Kann $conf nicht schreiben: $!");
    print $fh @lines;
    close($fh);
    print "Neuer Multipath-Eintrag (WWID: $new_wwid, Alias: $new_alias) wurde hinzugefügt.\n";
}

# Entfernt einen Multipath-Eintrag aus /etc/multipath.conf anhand der angegebenen WWID.
sub remove_multipath_entry {
    my ($target_wwid) = @_;
    my $conf = "/etc/multipath.conf";
    open(my $fh, "<", $conf) or error_exit("Kann $conf nicht lesen: $!");
    my @content = <$fh>;
    close($fh);

    # Entferne den Block, der den Ziel-WWID enthält.
    my $pattern = qr/\s*multipath\s*{\s*[^}]*\Q$target_wwid\E[^}]*}\s*/;
    my $new_content = join("", @content);
    $new_content =~ s/$pattern//g;
    
    open($fh, ">", $conf) or error_exit("Kann $conf nicht schreiben: $!");
    print $fh $new_content;
    close($fh);
    print "Multipath-Eintrag mit WWID '$target_wwid' wurde entfernt.\n";
}

# --- TUI-Anwendung mit Curses::UI ---
my $cui = Curses::UI->new( -clear_on_exit => 1 );
my $win = $cui->add(
    'window_id', 'Window',
    -border => 1,
    -y      => 2,
    -x      => 2,
    -width  => 50,
    -height => 15,
    -title  => 'Proxmox iSCSI Multipath Tool',
);

# Erstelle ein einfaches Menü.
my @menu_items = (
    "Install (komplette Konfiguration)",
    "Add Multipath Entry",
    "Remove Multipath Entry",
    "Exit"
);

my $menu = $win->add(
    'menu', 'Menu',
    -menu_items => \@menu_items,
    -title      => 'Wähle eine Option:',
);

my $selected = $menu->get;

if ($selected eq "Install (komplette Konfiguration)") {
    my $portal = $cui->dialog(-message => "Geben Sie das iSCSI-Portal ein:", -buttons => ["OK"])->inputbox();
    my $num_entries = $cui->dialog(-message => "Anzahl der iSCSI-Einträge:", -buttons => ["OK"])->inputbox();
    my @iscsi_entries;
    my @multipath_entries;
    for my $i (1 .. $num_entries) {
        my $base_storage = $cui->dialog(-message => "Eintrag $i: BASE_STORAGE_ID (z.B. iscsi-storage$i):", -buttons => ["OK"])->inputbox();
        my $target = $cui->dialog(-message => "Eintrag $i: iSCSI Target:", -buttons => ["OK"])->inputbox();
        my $lun = $cui->dialog(-message => "Eintrag $i: LUN:", -buttons => ["OK"])->inputbox();
        my $wwid = $cui->dialog(-message => "Eintrag $i: WWID:", -buttons => ["OK"])->inputbox();
        my $alias = $cui->dialog(-message => "Eintrag $i: Alias:", -buttons => ["OK"])->inputbox();
        push @iscsi_entries, { base_storage_id => $base_storage, target => $target, lun => $lun };
        push @multipath_entries, { wwid => $wwid, alias => $alias };
    }
    install_iscsi_tools();
    bind_iscsi_luns(\@iscsi_entries, $portal);
    install_multipath_tools();
    backup_multipath_conf();
    create_multipath_conf(\@multipath_entries);
    restart_multipath_service();
}
elsif ($selected eq "Add Multipath Entry") {
    my $new_wwid = $cui->dialog(-message => "Neuen WWID eingeben:", -buttons => ["OK"])->inputbox();
    my $new_alias = $cui->dialog(-message => "Neuen Alias eingeben:", -buttons => ["OK"])->inputbox();
    add_multipath_entry($new_wwid, $new_alias);
}
elsif ($selected eq "Remove Multipath Entry") {
    my $rem_wwid = $cui->dialog(-message => "WWID des zu entfernenden Eintrags eingeben:", -buttons => ["OK"])->inputbox();
    remove_multipath_entry($rem_wwid);
}
elsif ($selected eq "Exit") {
    $cui->dialog(-message => "Beende das Programm.", -buttons => ["OK"])->msgbox();
    exit 0;
}

$cui->mainloop;
exit 0;
