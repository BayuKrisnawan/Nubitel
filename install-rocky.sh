#!/usr/bin/bash
PATH=$PATH:/sbin:/bin:/usr/sbin:/usr/bin

## Requirement Packages ##
REQPACK="git-core tar rsync jq openssl"
WHEELGRP="wheel"
NFSPATH="/data"

NetworkConfig() {
    # 1. Ask for Interface Name (NIC) with validation loop
    while true; do
        echo "============================================="
        # Display currently available network interfaces to guide the user
        echo "Detected Network Interfaces (NIC):"
        nmcli device status | grep -E "ethernet|wifi" | awk '{print " - " $1 " (" $3 ") "}'
        echo "============================================="
        echo ""
        read -p "Enter Interface Name (e.g., eth0, ens33): " NIC
        
        # Check if the interface is empty
        if [ -z "$NIC" ]; then
            echo "Error: Interface name cannot be empty. Please try again."
            echo ""
            sleep 1; clear
            continue
        fi

        # Validate if the specified interface actually exists in the system
        if nmcli device show "$NIC" > /dev/null 2>&1; then
            echo "Success: Interface '$NIC' validated."
            break
        else
            echo "Error: Interface '$NIC' not found! Please enter a valid interface."
            echo ""
            sleep 1; clear
        fi
        
    done
    clear
    echo ""
    echo "Detecting current network settings for $NIC..."

    # Auto-detect current active IP and Netmask/CIDR
    CURRENT_IP_CIDR=$(nmcli -g IP4.ADDRESS device show "$NIC" | head -n 1)
    if [ ! -z "$CURRENT_IP_CIDR" ]; then
        DEFAULT_IP=$(echo "$CURRENT_IP_CIDR" | cut -d'/' -f1)
        DEFAULT_CIDR=$(echo "$CURRENT_IP_CIDR" | cut -d'/' -f2)
    else
        DEFAULT_IP=""
        DEFAULT_CIDR="24"
    fi

    # Auto-detect current active Gateway
    DEFAULT_GATEWAY=$(ip route show dev "$NIC" | grep default | awk '{print $3}' | head -n 1)
    # Fallback if specific gateway for NIC not found, get global default gateway
    if [ -z "$DEFAULT_GATEWAY" ]; then
        DEFAULT_GATEWAY=$(ip route show | grep default | awk '{print $3}' | head -n 1)
    fi

    # Auto-detect current DNS
    DEFAULT_DNS=$(nmcli -g IP4.DNS device show "$NIC" | head -n 1 | awk '{print $1}')

    # 2. Ask for IP Address (with default option)
    if [ ! -z "$DEFAULT_IP" ]; then
        read -p "Enter IP Address [Default: $DEFAULT_IP]: " IP
        IP=${IP:-$DEFAULT_IP}
    else
        read -p "Enter IP Address (e.g., 192.168.10.10): " IP
    fi

    # 3. Ask for Subnet Mask (with default option)
    read -p "Enter Subnet Mask [Default: $DEFAULT_CIDR]: " NETMASK
    NETMASK=${NETMASK:-$DEFAULT_CIDR}

    # Convert traditional subnet mask format (255.255.255.0) to CIDR notation
    if [[ "$NETMASK" == *"."* ]]; then
        case $NETMASK in
            255.255.255.0)   CIDR="24" ;;
            255.255.0.0)     CIDR="16" ;;
            255.0.0.0)       CIDR="8"  ;;
            255.255.255.128) CIDR="25" ;;
            255.255.255.192) CIDR="26" ;;
            255.255.255.240) CIDR="28" ;;
            *) 
                echo "Uncommon Netmask format. Defaulting to /24..."
                CIDR="24"
                ;;
        esac
    else
        CIDR=$NETMASK
    fi

    # 4. Ask for Gateway (with default option)
    if [ ! -z "$DEFAULT_GATEWAY" ]; then
        read -p "Enter Gateway [Default: $DEFAULT_GATEWAY]: " GATEWAY
        GATEWAY=${GATEWAY:-$DEFAULT_GATEWAY}
    else
        read -p "Enter Gateway (e.g., 192.168.10.1): " GATEWAY
    fi

    # 5. Ask for Hostname & Domain
    CURRENT_HOSTNAME=$(hostnamectl --static)
    read -p "Enter Hostname & Domain [Default: $CURRENT_HOSTNAME]: " FULL_HOSTNAME
    FULL_HOSTNAME=${FULL_HOSTNAME:-$CURRENT_HOSTNAME}

    # 6. Ask for DNS Server (with default option)
    if [ ! -z "$DEFAULT_DNS" ]; then
        read -p "Enter DNS Server (CXGatewayIP 192.168.10.x) [Default: 192.168.10.x $DEFAULT_DNS]: " DNS_SERVER
        DNS_SERVER=${DNS_SERVER:-$DEFAULT_DNS}
    else
        read -p "Enter DNS Server (e.g.,(CXGatewayIP 192.168.10.x) press Enter to skip): " DNS_SERVER
    fi

    echo ""
    echo "============================================="
    echo "CONFIRM NEW NETWORK CONFIGURATION:"
    echo "============================================="
    echo "Interface   : $NIC"
    echo "IP Address  : $IP/$CIDR"
    echo "Gateway     : $GATEWAY"
    echo "Hostname    : $FULL_HOSTNAME"
    echo "DNS Server  : ${DNS_SERVER:-"Not configured"}"
    echo "============================================="
    read -p "Is the above information correct? (y/n): " CONFIRM

    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo "Configuration cancelled by user."
        exit 0
    fi

    echo "Applying network configuration..."
    # Get the active NetworkManager connection name for the specified interface
    CONN_NAME=$(nmcli -g GENERAL.CONNECTION device show "$NIC" | head -n 1)

    # If no active connection exists, create a new profile using the interface name
    if [ -z "$CONN_NAME" ]; then
        CONN_NAME="$NIC"
        nmcli connection add type ethernet con-name "$CONN_NAME" ifname "$NIC"
    fi

    # Execute Network Configuration via nmcli
    echo "1. Configuring IP Address, Subnet, and Gateway..."
    nmcli connection modify "$CONN_NAME" ipv4.addresses "$IP/$CIDR" ipv4.gateway "$GATEWAY" ipv4.method manual

    # Apply DNS configuration if provided
    if [ ! -z "$DNS_SERVER" ]; then
        nmcli connection modify "$CONN_NAME" ipv4.dns "$DNS_SERVER"
    fi

    # Execute Hostname Configuration
    echo "2. Setting system hostname - FQDN(eq rocky.nubitel.io)..."
    hostnamectl set-hostname "$FULL_HOSTNAME"

    # Restart the Interface to apply changes immediately
    echo "3. Restarting network interface '$NIC'..."
    nmcli connection down "$CONN_NAME" && nmcli connection up "$CONN_NAME"

    echo "============================================="
    echo "Network configuration completed successfully!"
    echo "============================================="
}

## Generate SSH Key Pair
GenerateSSHKeys() {
    local user=$1
    local path=$2
    if [ "$user" == "root" ]; then
        local user_home="/root"
    else
        local user_home="/home/$user"
    fi

    echo "Setting up SSH Key for user: $user..."
    mkdir -p "$user_home/.ssh"

    if [ ! -f "$user_home/.ssh/id_ed25519" ]; then
        ssh-keygen -t ed25519 -N "" -f "$user_home/.ssh/id_ed25519"
    else
        echo "SSH Key already exists for $user, skipping creation."
    fi

    chmod 700 "$user_home/.ssh"
    chmod 600 "$user_home/.ssh/id_ed25519"
    chmod 644 "$user_home/.ssh/id_ed25519.pub"

    if [ "$user" != "root" ]; then
        chown -R "$user:$user" "$user_home/.ssh"
    else
        cat $HOME/.ssh/id_ed25519.pub |tee $path/.authorized_keys
        chmod 600 $path/.authorized_keys
    fi
}
## Check and Create/Update User for Podman
UserConfig() {
    while true; do
        read -p "Enter username to run Podman (e.g., nubitel,podmanuser): " UPODMAN
        if [ ! -z "$UPODMAN" ]; then
            break
        else
            echo "Error: Username cannot be empty!"
        fi
    done

    if id "$UPODMAN" >/dev/null 2>&1; then
        echo "User '$UPODMAN' already exists."
    else
        echo "User '$UPODMAN' does not exist. Creating user..."
        useradd -m -s /bin/bash "$UPODMAN"
    fi
    
    if ! groups "$UPODMAN" | grep -q "\b$WHEELGRP\b"; then
        echo "Adding user '$user' to group '$WHEELGRP'..."
        usermod -aG "$WHEELGRP" "$UPODMAN"
    fi

    echo "Enabling linger for user '$UPODMAN'..."
    loginctl enable-linger "$UPODMAN"
    GenerateSSHKeys "$UPODMAN" "$CONFIG_PATH"
}

## Configure Sudoers Configuration
UpdateSudo() {
    echo "Configuring passwordless sudo for %wheel group..."
    echo "%wheel ALL=(ALL) NOPASSWD:ALL" | tee /etc/sudoers.d/90-cloud-init-users > /dev/null
    chmod 0440 /etc/sudoers.d/90-cloud-init-users
}

## Package Installation Function
InstallPackages() {
    reqpack=$REQPACK
    [ ! -z $1 ] && reqpack=$1
    echo "Updating dnf repositories and installing $reqpack packages..."
    dnf install -y $reqpack
}

## NFS Configuration Role Selector (Server / Client)
NFSConfig() {
    echo ""
    echo "============================================="
    echo "NFS ROLE CONFIGURATION"
    echo "============================================="
    read -p "Do you want to configure this node as an NFS SERVER? (y/n): " IS_SERVER

    # -----------------------------------------------------------------
    # AUTOMATION OF SUBNET /24 FROM ACTIVE IP
    # -----------------------------------------------------------------
    # Get the active IP used for the default outbound route (main internet/lan)
    ACTIVE_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' | head -n 1)
    
    # If there is no external connection, take the first IP from the non-loopback interface.
    if [ -z "$ACTIVE_IP" ]; then
        ACTIVE_IP=$(hostname -I | awk '{print $1}')
    fi

    if [[ "$IS_SERVER" == "y" || "$IS_SERVER" == "Y" ]]; then
        echo "--> Configuring Node as NFS SERVER..."
        
        # Modify IP to subnet /24 (Example: 192.168.1.50 -> 192.168.1.0/24)
        if [ ! -z "$ACTIVE_IP" ]; then
            DEFAULT_NET=$(echo "$ACTIVE_IP" | cut -d'.' -f1-3)".0/24"
            read -p "Enter allowed client network/IP [Default: $DEFAULT_NET]: " ALLOWED_NET
            ALLOWED_NET=${ALLOWED_NET:-$DEFAULT_NET}
        else
            read -p "Enter allowed client network/IP (e.g., 192.168.1.0/24 or *): " ALLOWED_NET
        fi
        # -----------------------------------------------------------------

        read -p "Enter local directory path to export [Default: $NFSPATH]: " EXPORT_PATH
        EXPORT_PATH=${EXPORT_PATH:-"$NFSPATH"}
        
        if [ ! -d "$EXPORT_PATH" ]; then
            mkdir -p "$EXPORT_PATH"
            chmod 777 "$EXPORT_PATH"
        fi

        # Check if the export configuration already exists to avoid duplication.
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
        echo "NFS Server configuration completed successfully!"

    else
        echo "--> Configuring Node as NFS CLIENT..."
        [ ! -z "$ACTIVE_IP" ] && eNFS_SERVER=$(echo "$ACTIVE_IP" | cut -d'.' -f1-3)".x"
        read -p "Enter Remote NFS Server IP/Hostname (e.g., $eNFS_SERVER: " NFS_SERVER_IP
        
        if [ -z "$NFS_SERVER_IP" ]; then
            echo "Error: Server IP cannot be empty."
            return
        fi

        read -p "Enter Remote Exported Path [Default: $NFSPATH]: " REMOTE_PATH
        REMOTE_PATH=${REMOTE_PATH:-"$NFSPATH"}

        read -p "Enter Local Mount Point [Default: $NFSPATH: " LOCAL_MOUNT
        LOCAL_MOUNT=${LOCAL_MOUNT:-"$NFSPATH"}
        
        if [ ! -d "$LOCAL_MOUNT" ]; then
            mkdir -p "$LOCAL_MOUNT"
        fi

        # -----------------------------------------------------------------
        # CHECK IF IT HAS BEEN MOUNTED (ANTI-REMOUNT)
        # -----------------------------------------------------------------
        if mountpoint -q "$LOCAL_MOUNT"; then
            echo "--> INFO: Target directory '$LOCAL_MOUNT' is ALREADY mounted."
        else
            echo "Directory not mounted. Processing mount..."
            
            FSTAB_ENTRY="$NFS_SERVER_IP:$REMOTE_PATH $LOCAL_MOUNT nfs defaults,_netdev 0 0"
            
            # Check fstab to avoid writing the same line repeatedly.
            if ! grep -q "$LOCAL_MOUNT" /etc/fstab; then
                echo "$FSTAB_ENTRY" | tee -a /etc/fstab > /dev/null
            fi

            systemctl enable --now rpcbind
            mount "$LOCAL_MOUNT" 2>/dev/null || mount -a
            
            if mountpoint -q "$LOCAL_MOUNT"; then
                echo "NFS Share mounted successfully at $LOCAL_MOUNT!"
            else
                echo "Error: Failed to mount NFS share. Please check Server IP and Export Path."
            fi
        fi
        # -----------------------------------------------------------------
    fi
}

## PostgreSQL Server and DB Creation Function
PostgresConfig() {
    echo ""
    echo "============================================="
    echo "POSTGRESQL SERVER & DATABASE CONFIGURATION"
    echo "============================================="
    echo "============================================="
    if [ ! -z "$EXPORT_PATH" ]; then
        CONFIG_PATH=$EXPORT_PATH
    else
        CONFIG_PATH=$LOCAL_MOUNT
    fi
    if [[ -z "$CONFIG_PATH" && $(mountpoint -q "$NFSPATH"; echo $?) -eq 0 ]]; then
        CONFIG_PATH=$NFSPATH
    fi
    [ -z $CONFIG_PATH  ] && echo "Install & Configure NFS (Server OR Client)..." && return
    read -p "Do you want to install and configure PostgreSQL Server? (y/n): " IS_PG

    if [[ "$IS_PG" == "y" || "$IS_PG" == "Y" ]]; then
        echo "Installing PostgreSQL Server Packages..."
        dnf install -y postgresql-server postgresql-contrib

        PG_DATA_DIR="/var/lib/pgsql/data"

        # Initialize PostgreSQL database cluster jika belum ada
        if [ ! -f "$PG_DATA_DIR/PG_VERSION" ]; then
            echo "Initializing PostgreSQL database..."
            postgresql-setup --initdb
        fi

        echo "Configuring PostgreSQL to allow remote/container connections..."
        if [ -f "$PG_DATA_DIR/postgresql.conf" ]; then
            sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/g" "$PG_DATA_DIR/postgresql.conf"
            sed -i "s/listen_addresses = 'localhost'/listen_addresses = '*'/g" "$PG_DATA_DIR/postgresql.conf"
        fi

        if [ -f "$PG_DATA_DIR/pg_hba.conf" ]; then
            if ! grep -q "0.0.0.0/0" "$PG_DATA_DIR/pg_hba.conf"; then
                echo "" >> "$PG_DATA_DIR/pg_hba.conf"
                echo "# Allow connection from all hosts / containers" >> "$PG_DATA_DIR/pg_hba.conf"
                echo "host    all             all             0.0.0.0/0               scram-sha-256" >> "$PG_DATA_DIR/pg_hba.conf"
                echo "host    all             all             ::/0                    scram-sha-256" >> "$PG_DATA_DIR/pg_hba.conf"
            fi
        fi

        echo "Starting/Restarting PostgreSQL service..."
        systemctl enable postgresql
        systemctl restart postgresql

        # Menyiapkan file Environment baru (selalu ditimpa yang baru agar password-nya update)
        ENV_FILE="$CONFIG_PATH/.envpgdb"
        DATABASES=("nubitel" "reports" "identity" "fscoredb")
        
        echo "# PostgreSQL Generated Credentials - Updated on $(date)" > "$ENV_FILE"
        chmod 600 "$ENV_FILE"

        echo "Processing users and databases..."
        for DB_NAME in "${DATABASES[@]}"; do
            # Generate password acak baru
            RAND_PASS=$(openssl rand -base64 12)
            
            echo "----------------------------------------"
            echo "Database/User Target: $DB_NAME"

            # 1. Cek apakah USER sudah ada
            USER_EXISTS=$(su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='$DB_NAME'\"")
            
            if [ "$USER_EXISTS" == "1" ]; then
                echo "-> User '$DB_NAME' already exists. Updating password..."
                # JIKA ADA: Update password saja
                su - postgres -c "psql -c \"ALTER USER $DB_NAME WITH PASSWORD '$RAND_PASS';\"" > /dev/null
            else
                echo "-> User '$DB_NAME' does not exist. Creating user..."
                # JIKA TIDAK ADA: Buat baru
                su - postgres -c "psql -c \"CREATE USER $DB_NAME WITH PASSWORD '$RAND_PASS';\"" > /dev/null
            fi

            # 2. Cek apakah DATABASE sudah ada
            DB_EXISTS=$(su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='$DB_NAME'\"")
            
            if [ "$DB_EXISTS" == "1" ]; then
                echo "-> Database '$DB_NAME' already exists. Skipping database creation."
                # Pastikan owner-nya tetap benar
                su - postgres -c "psql -c \"ALTER DATABASE $DB_NAME OWNER TO $DB_NAME;\"" > /dev/null
            else
                echo "-> Database '$DB_NAME' does not exist. Creating database..."
                su - postgres -c "psql -c \"CREATE DATABASE $DB_NAME OWNER $DB_NAME;\"" > /dev/null
            fi
            
            # 3. Simpan kredensial terbaru ke file .envpgdb
            echo "${DB_NAME^^}_DB_USER=$DB_NAME" >> "$ENV_FILE"
            echo "${DB_NAME^^}_DB_PASS=$RAND_PASS" >> "$ENV_FILE"
            echo "${DB_NAME^^}_DB_NAME=$DB_NAME" >> "$ENV_FILE"
            echo "----------------------------------------" >> "$ENV_FILE"
        done

        echo ""
        echo "PostgreSQL setup/update completed!"
        echo "New credentials successfully saved to: $ENV_FILE"
        
        if systemctl is-active --quiet firewalld; then
            firewall-cmd --permanent --add-service=postgresql
            firewall-cmd --reload > /dev/null
        fi
    else
        echo "Skipping PostgreSQL installation."
    fi
}
PodmanConfig() {
    echo "============================================="
    echo "USER & PODMAN CONFIGURATION"
    echo "============================================="
    UserConfig
}
## Ansible Host Installation Function
AnsibleConfig() {
    echo ""
    echo "============================================="
    echo "ANSIBLE CONTROL NODE CONFIGURATION"
    echo "============================================="
    if [ ! -z "$EXPORT_PATH" ]; then
        CONFIG_PATH=$EXPORT_PATH
    else
        CONFIG_PATH=$LOCAL_MOUNT
    fi
    [ -z $CONFIG_PATH  ] && echo "Install & Configure NFS (Server / Client)..." && return
    read -p "Do you want to configure this node as an Ansible Control Host (Only One Host Allowed)? (y/n): " IS_ANSIBLE


    echo "CONFIG_PATH: $CONFIG_PATH"
    if [[ "$IS_ANSIBLE" == "y" || "$IS_ANSIBLE" == "Y" ]]; then
        echo "Installing Ansible..."
        # Ansible standard package requires EPEL repository on Rocky Linux
        if ! rpm -q epel-release > /dev/null 2>&1; then
            echo "Enabling EPEL repository..."
            InstallPackages epel-release
        fi
        InstallPackages ansible-core
        
        echo ""
        echo "Ansible installed successfully!"
        echo "--------------------------------------------------------"
        echo "TIP to share SSH Key to your 6 hosts:"
        echo "Run this command on your terminal later to push public key:"
        echo "  ssh-copy-id root@<TARGET_IP>"
        echo "--------------------------------------------------------"
        # Setup SSH Keys
        echo ""
        echo "============================================="
        echo "GENERATING SSH KEYS -> $CONFIG_PATH"
        echo "============================================="
        GenerateSSHKeys "root" "$CONFIG_PATH"
    fi
}

# =====================================================================
# DISPLAY MENU FUNCTION
# =====================================================================
ShowMenu() {
    clear
    echo "============================================="
    echo "       NODE DEPLOYMENT & AUTOMATION          "
    echo "============================================="
    echo "Current System Hostname: $(hostname)"
    echo "Current Date           : $(date)"
    echo "============================================="
    echo "Please select an option from the menu below:"
    echo ""

    # Definisikan opsi menu dalam bentuk array
    options=(
        "Configure Network (Static IP & Hostname)"
        "Install Base Packages (REQPACK)"
        "Install & Configure NFS (Server / Client)"
        "Install & Setup PostgreSQL Server"
        "Install Podman"
        "Setup User & Permission"
        "Configure Ansible Control Host"
        "Run All Setup (Full Automation)"
        "Exit Script"
    )

    # PS3 adalah prompt teks yang muncul di bawah menu untuk meminta input
    PS3="[$USER@$(hostname) Menu Selection]# "

    select opt in "${options[@]}"; do
        case $opt in
            "Configure Network (Static IP & Hostname)")
                echo -e "\n>>> Starting Network Configuration..."
                NetworkConfig
                break ;;
            "Install Base Packages (REQPACK)")
                echo -e "\n>>> Installing Requirements..."
                InstallPackages 
                break ;;
            "Install & Configure NFS (Server / Client)")
                echo -e "\n>>> Installing & Configure NFS..."
                InstallPackages nfs-utils 
                NFSConfig
                break ;;
            "Install & Setup PostgreSQL Server")
                PostgresConfig ; break ;;
            "Install Podman")
                echo -e "\n>>> Starting Install Podman..."
                InstallPackages podman; break ;;
            "Setup User & Permission")
                echo -e "\n>>> Starting User Configuration..."
                UserConfig
                UpdateSudo
                break;;
            "Configure Ansible Control Host")
                echo -e "\n>>> Configuring Ansible Controler..."
                AnsibleConfig
                break ;;
            "Exit Script")
                echo "Exiting. Goodbye!"
                exit 0
                ;;
            *) 
                # Jika user memasukkan angka yang tidak ada di menu
                echo "Invalid option $REPLY. Please choose a number between 1 and ${#options[@]}."
                ;;
        esac
    done
}

# =====================================================================
# MAIN LOOP (Agar setelah selesai eksekusi, menu muncul lagi)
# =====================================================================
# Pastikan dijalankan sebagai root
if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run this script as root or using sudo."
  exit 1
fi

# Loop utama agar skrip tidak langsung mati setelah satu tugas selesai
while true; do
    ShowMenu
    echo ""
    read -p "Press [Enter] key to return to Main Menu..." temp
done