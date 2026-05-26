#!/usr/bin/bash
PATH=$PATH:/sbin:/bin:/usr/sbin:/usr/bin

## Requirement Packages ##
REQPACK="git-core tar rsync jq openssl nfs-utils unzip curl"
WHEELGRP="wheel"
NFSPATH="/data"
## Global Variables ##
DOMAIN="nubitel.io"
NUBITEL_USER="nubitel"
NUBITEL_GROUP="nubitel"
NUBITEL_UID="2000"   # Tetap definisikan secara statis di variabel
NUBITEL_GID="2000"   # Tetap definisikan secara statis di variabel
AWSCLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"

NetworkConfig() {
    # 1. OTOMATISASI DETEKSI DEFAULT NIC (Prioritas: Connected Ethernet -> Connected Lainnya)
    DEFAULT_NIC=$(nmcli device status | grep -E "ethernet" | grep "connected" | awk '{print $1}' | head -n 1)
    if [ -z "$DEFAULT_NIC" ]; then
        # Jika tidak ada ethernet yang connected, cari wifi atau interface connected apa saja
        DEFAULT_NIC=$(nmcli device status | grep "connected" | awk '{print $1}' | head -n 1)
    fi

    while true; do
        echo "============================================="
        echo "Detected Network Interfaces (NIC):"
        nmcli device status | grep -E "ethernet|wifi" | awk '{print " - " $1 " (" $3 ")"}'
        echo "============================================="
        echo ""
        
        # Tampilkan default NIC yang terdeteksi cerdas di dalam prompt
        if [ ! -z "$DEFAULT_NIC" ]; then
            read -p "Enter Interface Name [Default: $DEFAULT_NIC]: " NIC
            NIC=${NIC:-$DEFAULT_NIC}
        else
            read -p "Enter Interface Name (e.g., eth0, ens33): " NIC
        fi
        
        if [ -z "$NIC" ]; then
            echo "Error: Interface name cannot be empty. Please try again."
            sleep 1; clear
            continue
        fi

        if nmcli device show "$NIC" > /dev/null 2>&1; then
            echo "Success: Interface '$NIC' validated."
            break
        else
            echo "Error: Interface '$NIC' not found! Please enter a valid interface."
            sleep 1; clear
        fi
    done
    clear
    echo ""
    echo "Detecting current network settings for $NIC..."

    CURRENT_IP_CIDR=$(nmcli -g IP4.ADDRESS device show "$NIC" | head -n 1)
    CURRENT_GW=$(nmcli -g IP4.GATEWAY device show "$NIC" | head -n 1)
    
    # 2. PERBAIKAN TOTAL CURRENT_DNS (Spesifik hanya membaca $NIC yang dipilih dan membersihkan karakter '|')
    # Kita ambil output DNS, ganti karakter '|' menjadi koma, hapus spasi, dan hilangkan koma liar di ujung.
    RAW_DNS=$(nmcli -g IP4.DNS device show "$NIC" | paste -sd "," - | tr '|' ',')
    CURRENT_DNS=$(echo "$RAW_DNS" | sed 's/,\+/,/g' | sed 's/^,//;s/,$//' | tr -d ' ')

    echo "----------------------------------------"
    echo "Current IP/CIDR : $CURRENT_IP_CIDR"
    echo "Current Gateway : $CURRENT_GW"
    echo "Current DNS     : $CURRENT_DNS"
    echo "----------------------------------------"
    echo ""

    read -p "Enter Static IP/CIDR [Default: $CURRENT_IP_CIDR]: " NEW_IP
    NEW_IP=${NEW_IP:-$CURRENT_IP_CIDR}

    read -p "Enter Gateway [Default: $CURRENT_GW]: " NEW_GW
    NEW_GW=${NEW_GW:-$CURRENT_GW}

    read -p "Enter DNS (comma separated, e.g., 8.8.8.8,1.1.1.1) [Default: $CURRENT_DNS]: " NEW_DNS
    NEW_DNS=${NEW_DNS:-$CURRENT_DNS}

    read -p "Enter Hostname Prefix (e.g., cxnfs, cxdb, cxgw, cxcall, cxapp): " HOST_PREFIX
    if [ -z "$HOST_PREFIX" ]; then
        HOST_PREFIX="cxnode"
    fi

    echo ""
    echo "Applying network configuration..."
    nmcli connection modify "$NIC" \
        ipv4.addresses "$NEW_IP" \
        ipv4.gateway "$NEW_GW" \
        ipv4.dns "$NEW_DNS" \
        ipv4.method "manual"

    nmcli connection up "$NIC"
    hostnamectl set-hostname "${HOST_PREFIX}.${DOMAIN}"

    echo "Network and Hostname updated successfully!"
}

InstallPackages() {
    echo "Updating DNF Cache and Installing Base Packages..."
    dnf install -y $REQPACK
}

NFSConfig() {
    echo ""
    echo "============================================="
    echo "NFS ROLE CONFIGURATION"
    echo "============================================="
    read -p "Do you want to configure this node as an NFS SERVER? (y/n): " IS_SERVER

    if [[ "$IS_SERVER" == "y" || "$IS_SERVER" == "Y" ]]; then
        echo "--> Configuring Node as NFS SERVER..."
        ACTIVE_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' | head -n 1)
        if [ -z "$ACTIVE_IP" ]; then
            ACTIVE_IP=$(hostname -I | awk '{print $1}')
        fi

        if [ ! -z "$ACTIVE_IP" ]; then
            DEFAULT_NET=$(echo "$ACTIVE_IP" | cut -d'.' -f1-3)".0/24"
            read -p "Enter allowed client network/IP [Default: $DEFAULT_NET]: " ALLOWED_NET
            ALLOWED_NET=${ALLOWED_NET:-$DEFAULT_NET}
        else
            read -p "Enter allowed client network/IP (e.g., 192.168.1.0/24): " ALLOWED_NET
        fi

        read -p "Enter local directory path to export [Default: /data]: " EXPORT_PATH
        EXPORT_PATH=${EXPORT_PATH:-"/data"}
        
        if [ ! -d "$EXPORT_PATH" ]; then
            mkdir -p "$EXPORT_PATH"
            chmod 777 "$EXPORT_PATH"
        fi

        if ! grep -q "$EXPORT_PATH" /etc/exports; then
            echo "$EXPORT_PATH $ALLOWED_NET(rw,sync,no_subtree_check,no_root_squash)" | tee -a /etc/exports > /dev/null
        else
            echo "Configuration for $EXPORT_PATH already exists in /etc/exports."
        fi

        systemctl enable --now rpcbind nfs-server
        exportfs -arv
        
        if systemctl is-active --quiet firewalld; then
            firewall-cmd --permanent --add-service=nfs
            firewall-cmd --permanent --add-service=rpc-bind
            firewall-cmd --permanent --add-service=mountd
            firewall-cmd --reload > /dev/null
        fi
        echo "NFS Server configuration completed!"

    else
        echo "--> Configuring Node as NFS CLIENT..."
        read -p "Enter Remote NFS Server IP/Hostname (e.g., 192.168.1.5): " NFS_SERVER_IP
        
        if [ -z "$NFS_SERVER_IP" ]; then
            echo "Error: Server IP cannot be empty."
            return
        fi

        read -p "Enter Remote Exported Path [Default: /data]: " REMOTE_PATH
        REMOTE_PATH=${REMOTE_PATH:-"/data"}

        # read -p "Enter Local Mount Point [Default: $NFSPATH]: " LOCAL_MOUNT
        echo "Local Mount Point [Default: $NFSPATH]"
        LOCAL_MOUNT=${LOCAL_MOUNT:-"$NFSPATH"} 
        
        if mount | grep -q -E "type nfs.* $LOCAL_MOUNT "; then
            echo "--> INFO: Target directory '$LOCAL_MOUNT' is ALREADY mounted via NFS."
            return
        elif mount | grep -q -E "type nfs.* $(dirname $LOCAL_MOUNT) "; then
            echo "--> WARNING: Parent directory of '$LOCAL_MOUNT' is already an active NFS Mount!"
            return
        fi

        if [ ! -d "$LOCAL_MOUNT" ]; then
            mkdir -p "$LOCAL_MOUNT"
        fi

        FSTAB_ENTRY="$NFS_SERVER_IP:$REMOTE_PATH $LOCAL_MOUNT nfs defaults,_netdev 0 0"
        if ! grep -q "$LOCAL_MOUNT" /etc/fstab; then
            echo "$FSTAB_ENTRY" | tee -a /etc/fstab > /dev/null
        fi

        systemctl enable --now rpcbind
        mount "$LOCAL_MOUNT" 2>/dev/null || mount -a
        echo "NFS Client successfully mounted to $LOCAL_MOUNT"
    fi
}

UserConfig() {
    echo ""
    echo "============================================="
    echo "       USER & PERMISSION CONFIGURATION       "
    echo "============================================="

    # 1. VALIDASI DAN CREATE GROUP
    if getent group "$NUBITEL_GROUP" > /dev/null 2>&1; then
        CURRENT_GID=$(getent group "$NUBITEL_GROUP" | cut -d: -f3)
        if [ "$CURRENT_GID" -eq "$NUBITEL_GID" ]; then
            echo "--> [SKIP]: Group '$NUBITEL_GROUP' sudah ada dengan GID $NUBITEL_GID yang benar."
        else
            echo "--> [WARNING]: Group '$NUBITEL_GROUP' sudah ada tapi GID-nya salah ($CURRENT_GID)."
            echo "    Mencoba memperbaiki GID menjadi $NUBITEL_GID..."
            groupmod -g "$NUBITEL_GID" "$NUBITEL_GROUP"
        fi
    else
        groupadd -g "$NUBITEL_GID" "$NUBITEL_GROUP"
        echo "--> [SUCCESS]: Group '$NUBITEL_GROUP' berhasil dibuat dengan GID $NUBITEL_GID."
    fi

    # 2. VALIDASI DAN CREATE USER
    if getent passwd "$NUBITEL_USER" > /dev/null 2>&1; then
        CURRENT_UID=$(getent passwd "$NUBITEL_USER" | cut -d: -f3)
        CURRENT_USER_GID=$(getent passwd "$NUBITEL_USER" | cut -d: -f4)

        if [ "$CURRENT_UID" -eq "$NUBITEL_UID" ] && [ "$CURRENT_USER_GID" -eq "$NUBITEL_GID" ]; then
            echo "--> [SKIP]: User '$NUBITEL_USER' sudah ada dengan UID/GID $NUBITEL_UID yang benar."
        else
            echo "--> [WARNING]: User '$NUBITEL_USER' sudah ada tapi UID/GID tidak sesuai."
            echo "    Memperbaiki konfigurasi user..."
            usermod -u "$NUBITEL_UID" -g "$NUBITEL_GID" "$NUBITEL_USER"
        fi
    else
        useradd -u "$NUBITEL_UID" -g "$NUBITEL_GID" -m -s /bin/bash "$NUBITEL_USER"
        echo "--> [SUCCESS]: User '$NUBITEL_USER' berhasil dibuat dengan UID $NUBITEL_UID."
    fi
    echo "Enabling linger for user '$NUBITEL_USER'..."
    loginctl enable-linger "$NUBITEL_USER"
}

UpdateSudo() {
    SUDOERS_FILE="/etc/sudoers.d/$NUBITEL_USER"
    # Menggunakan variabel user untuk hak akses sudo
    echo "$NUBITEL_USER ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
    chmod 0440 "$SUDOERS_FILE"
    echo "Sudoers rule updated: '$NUBITEL_USER' has NOPASSWD access."
}

AnsibleConfig() {
    echo "Installing Ansible Core Engine on Master Host..."
    dnf install -y epel-release
    dnf install -y ansible-core
    echo "Ansible installed successfully!"
}

FixHostConfig() {
    echo ""
    echo "============================================="
    echo "       ANSIBLE SSH KEY CENTRAL DISTRIBUTION  "
    echo "============================================="
    CLUSTER_NFS="$NFSPATH"

    local nfs_key_dir="$CLUSTER_NFS/.ansible_master_key"
    local master_pub_file="$nfs_key_dir/ansible_controller.pub"

    if ! mountpoint -q "$CLUSTER_NFS" &&  [ ! -f "$master_pub_file" ] ; then
        echo -e "Error: Path '$CLUSTER_NFS' is not an active NFS mount point or master ansible not configured!"
        return
    fi

    echo "Are you running this script on the ANSIBLE CONTROL HOST (Master)? "
    read -p "(y = Master Node / n = Target Node): " IS_MASTER
    mkdir -p "/root/.ssh" && chmod 700 "/root/.ssh"
    mkdir -p /home/$NUBITEL_USER/.ssh && chmod 700 /home/$NUBITEL_USER/.ssh
    
    if [[ "$IS_MASTER" == "y" || "$IS_MASTER" == "Y" ]]; then
        ##Installing aws cli
        cd /tmp/ 
        curl -s $AWSCLI_URL -o "awscliv2.zip"
        unzip -o awscliv2.zip
        ./aws/install --update && cd 
        
        
        mkdir -p "$nfs_key_dir"
        chmod 700 "$nfs_key_dir"
    
        if [ ! -f "/root/.ssh/id_ed25519" ]; then
            echo "Generating SSH Key for Ansible Master..."
            ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519
            cat  "/root/.ssh/id_ed25519.pub" >> "$master_pub_file"
        fi

        chmod 644 "$master_pub_file"
        cat $master_pub_file > /home/$NUBITEL_USER/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
        chmod 600 /home/$NUBITEL_USER/.ssh/authorized_keys
        mkdir -p /home/$NUBITEL_USER/.ssh && chmod 700 /home/$NUBITEL_USER/.ssh
        chown -R $NUBITEL_USER:$NUBITEL_GROUP /home/$NUBITEL_USER/.ssh
        echo "Success: Ansible Master Public Key deposited to NFS."
    else
        ## Key for root
        if [ ! -f "$master_pub_file" ]; then
            echo "Error: Ansible Master Public Key not found in NFS yet!"
            return
        fi
        MASTER_KEY_CONTENT=$(cat "$master_pub_file")
        echo "$MASTER_KEY_CONTENT" > "/root/.ssh/authorized_keys"
        chmod 600 "/root/.ssh/authorized_keys"
        ## Key for $NUBITEL_USER
        echo "$MASTER_KEY_CONTENT" > "/home/$NUBITEL_USER/.ssh/authorized_keys"
        chmod 600 "/home/$NUBITEL_USER/.ssh/authorized_keys"
        chown -R $NUBITEL_USER:$NUBITEL_GROUP /home/$NUBITEL_USER/.ssh
        echo "Success: Ansible Master Public Key authorized on this node."
    fi
}

ShowMenu() {
    clear
    echo "========================================================="
    echo "       NUBITEL SYSTEM ON-PREMISE BOOTSTRAP DEPLOYER       "
    echo "                    ROCKY LINUX EDITION                  "
    echo "========================================================="
    echo "Current Hostname : $(hostname)"
    echo "========================================================="
    echo "Select Bootstrap Step:"
    echo ""

    options=(
        "Configure Network & Hostname"
        "Install Base Engine Pack"
        "Setup NFS (Server / Client)"
        "Setup User & Permission"
        "Configure Ansible Engine (Master Only)"
        "Fix Host (Sync Ansible SSH Keys)"
        "Exit Script"
    )

    PS3="[Bootstrap Selection]# "

    select opt in "${options[@]}"; do
        case $opt in
            "Configure Network & Hostname")
                NetworkConfig; break ;;
            "Install Base Engine Pack")
                InstallPackages; break ;;
            "Setup NFS (Server / Client)")
                NFSConfig; break ;;
            "Setup User & Permission")
                UserConfig; UpdateSudo; break ;;
            "Configure Ansible Engine (Master Only)")
                AnsibleConfig; break ;;
            "Fix Host (Sync Ansible SSH Keys)")
                FixHostConfig; break ;;
            "Exit Script")
                echo "Exiting. Goodbye!"; exit 0 ;;
            *) 
                echo "Invalid option $REPLY." ;;
        esac
    done
}

if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run this script as root."
  exit 1
fi

while true; do
    ShowMenu
    echo ""
    read -p "Press [Enter] key to return to Main Menu..." temp
done
