#!/bin/bash

mcserver_dir="/opt/minecraft"

if [ -t 1 ]; then
    # Define colors
    RED="\033[0;31m"
    GREEN="\033[0;32m"
    YELLOW="\033[0;33m"
    BLUE="\033[0;34m"
    CYAN="\033[0;36m"
    NC="\033[0m" # No Color
else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    CYAN=""
    NC=""
fi

# Function to display error message and exit
function display_error {
    echo -e "${RED}Error: $1${NC}" >&2
    exit 1
}

# Function to prompt user for input
function prompt_user {
    local prompt_message=$1
    local variable_name=$2
    read -rp "$prompt_message: " "$variable_name"
}

# Function to validate if a package is installed
function check_package_installed {
    local package_name=$1
    dpkg -l | grep -q "$package_name"
}

# Function to install a package if not already installed
function install_package {
    local package_name=$1
    if ! check_package_installed "$package_name"; then
        apt-get install -y "$package_name" || display_error "Failed to install $package_name."
    else
        echo "$package_name is already installed. Skipping installation."
    fi
}

# Function to check Java version and install/update if necessary
function install_or_update_java {
    local java_version=$(java -version 2>&1 | grep version | awk '{print $3}' | tr -d \")

    if [ -z "$java_version" ]; then
        echo "Java not found. Installing JDK 22..."
        wget -O /tmp/jdk-22_linux-x64_bin.deb https://download.oracle.com/java/22/latest/jdk-22_linux-x64_bin.deb
        dpkg -i /tmp/jdk-22_linux-x64_bin.deb
        rm /tmp/jdk-22_linux-x64_bin.deb
    elif [[ "$java_version" != 22* ]]; then
        echo "Java version $java_version found. Updating to JDK 22..."
        wget -O /tmp/jdk-22_linux-x64_bin.deb https://download.oracle.com/java/22/latest/jdk-22_linux-x64_bin.deb
        dpkg -i /tmp/jdk-22_linux-x64_bin.deb
        rm /tmp/jdk-22_linux-x64_bin.deb
    else
        echo "Java is already installed."
    fi
}

function get_latest_version {
    local manifest_url="https://launchermeta.mojang.com/mc/game/version_manifest.json"
    local manifest_data=$(curl -sSL "$manifest_url") || display_error "Failed to fetch version manifest JSON."
    echo "$manifest_data" | jq -r '.latest.release' || display_error "Failed to get latest release version."
}

function get_current_version {
    echo $(unzip -p "$mcserver_dir/minecraft_server.jar" version.json | grep "name" | grep -oP '(?<=name": ")[^"]+')
}

# Function to get the Minecraft server download URL for a specific version or the latest version
function get_minecraft_server_url {
    local minecraft_version=$1
    local manifest_url="https://launchermeta.mojang.com/mc/game/version_manifest.json"
    local manifest_data=$(curl -sSL "$manifest_url") || display_error "Failed to fetch version manifest JSON."

    if [ "$minecraft_version" = "latest" ]; then
        minecraft_version="$(get_latest_version)"
    fi

    local version_object=$(echo "$manifest_data" | jq --arg version "$minecraft_version" '.versions[] | select(.id == $version)') || display_error "Failed to find version object for Minecraft version $minecraft_version."
    if [ -z "$version_object" ]; then
        display_error "Minecraft version $minecraft_version not found."
    fi

    local version_url=$(echo "$version_object" | jq -r '.url') || display_error "Failed to get URL for Minecraft version $minecraft_version."

    local version_data=$(curl -sSL "$version_url") || display_error "Failed to fetch JSON data for Minecraft version $minecraft_version."
    local server_download_url=$(echo "$version_data" | jq -r '.downloads.server.url') || display_error "Failed to extract download URL for server JAR file for Minecraft version $minecraft_version."

    echo "$server_download_url"
}

# Function to check for updates and update the server JAR file
function update_minecraft {
    echo "Checking for updates..."
    latest_version=$(get_latest_version)
    current_version=$(get_current_version)
    if [[ "$current_version" != "$latest_version" ]]; then
        echo "New version available: $latest_version"
        echo "Updating ..."
        wget -O "$mcserver_dir/minecraft_server.jar" "$(get_minecraft_server_url "$latest_version")" || display_error "Failed to update server JAR file."
        systemctl restart "minecraft@mcserver"
        echo "Minecraft server file updated successfully to version $latest_version."
    else
        echo "Server JAR file is already up to date."
    fi
}

function setup_server {
    if [ -f "$mcserver_dir/minecraft_server.jar" ]; then
        display_error "Minecraft server is already installed. Setup aborted."
    fi

    # Update system packages
    apt-get update || display_error "Failed to update packages."
    apt-get upgrade -y || display_error "Failed to upgrade packages."

    # Install required packages
    install_package "curl"
    install_package "jq"
    install_or_update_java
    install_package "screen"
    install_package "ufw"

    # Allow TCP connections on port 25565
    if ! ufw status | grep -q "25565"; then
        ufw allow 25565/tcp || display_error "Failed to open port 25565."
    else
        echo "Port 25565 is already open. Skipping port configuration."
    fi

    # Interactive setup
    prompt_user "Enter Minecraft version (default: latest)" minecraft_version
    minecraft_version=${minecraft_version:-"latest"}

    prompt_user "Enter allocated memory (in MB, default: 1024)" allocated_memory
    allocated_memory=${allocated_memory:-1024}

    # Create server directory and download server files
    mkdir -p "$mcserver_dir" || display_error "Failed to create server directory $mcserver_dir."
    cd "$mcserver_dir" || display_error "Failed to change directory to $mcserver_dir."
    echo "Downloading Minecraft server version $minecraft_version..."
    server_download_url=$(get_minecraft_server_url "$minecraft_version")
    wget -O minecraft_server.jar "$server_download_url" || display_error "Failed to download server files."

    # Accept EULA
    echo "eula=true" >eula.txt || display_error "Failed to accept EULA."

    # Create systemd service unit file
    cat <<EOF >/etc/systemd/system/minecraft@mcserver.service
[Unit]
Description=Minecraft Server
After=network.target

[Service]
WorkingDirectory=$mcserver_dir

User=root
Group=root

Restart=always

ExecStart=screen -DmSL mc-server java -Xms${allocated_memory}M -Xmx${allocated_memory}M -jar minecraft_server.jar nogui

ExecStop=screen -p 0 -S mc-server -X eval 'stuff "say SERVER SHUTTING DOWN IN 5 SECONDS. SAVING ALL MAPS…"\015'
ExecStop=sleep 5
ExecStop=screen -p 0 -S mc-server -X eval 'stuff "save-all"\015'
ExecStop=screen -p 0 -S mc-server -X eval 'stuff "stop"\015'

[Install]
WantedBy=multi-user.target
EOF

    # Reload systemd daemon and start Minecraft service
    systemctl daemon-reload
    systemctl enable --now "minecraft@mcserver"

    # Automatically restart server daily
    cat <<EOF >"$mcserver_dir/dailyrestart.sh"
#!/bin/bash

screen -S "mcserver" -X stuff 'say Daily server restart in 60 seconds\r'
sleep 30
screen -S "mcserver" -X stuff 'say Daily server restart in 30 seconds\r'
sleep 20
screen -S "mcserver" -X stuff 'say Daily server restart in 10 seconds\r'
sleep 5
screen -S "mcserver" -X stuff 'say Server restarting in 5 seconds\r'
sleep 1
screen -S "mcserver" -X stuff 'say Server restarting in 4 seconds\r'
sleep 1
screen -S "mcserver" -X stuff 'say Server restarting in 3 seconds\r'
sleep 1
screen -S "mcserver" -X stuff 'say Server restarting in 2 seconds\r'
sleep 1
screen -S "mcserver" -X stuff 'say Server restarting in 1 second\r'
sleep 1
screen -S "mcserver" -X stuff 'restart\r'
systemctl restart "minecraft@mcserver"
EOF
    chmod +x "$mcserver_dir/dailyrestart.sh"
    echo "Minecraft server setup for $server_name completed successfully!"
}

# Function to uninstall a server
function uninstall_server {
    systemctl stop "minecraft@mcserver"
    systemctl disable --now "minecraft@mcserver"
    rm "/etc/systemd/system/minecraft@mcserver.service"
    screen -ls | grep "mc-server" | awk '{print $1}' | xargs -I{} screen -X -S {} quit
    rm -rf $mcserver_dir
    echo "Minecraft server removed successfully."
}

# Function to start Minecraft server
function start_server {
    echo "Starting ..."
    systemctl start "minecraft@mcserver"
}

# Function to stop Minecraft server
function stop_server {
    echo "Stoping ..."
    systemctl stop "minecraft@mcserver"
}

# Function to restart Minecraft server
function restart_server {
    echo "Restarting ..."
    systemctl restart "minecraft@mcserver"
}

# Function to check status of Minecraft server
function server_info {
    local server_properties="$mcserver_dir/server.properties"

    local minecraft_installed="${RED}● Not Installed${NC}"
    if [ -f "$mcserver_dir/minecraft_server.jar" ]; then
        minecraft_installed="${GREEN}● Installed${NC}"
    fi

    if [ ! -f "$server_properties" ]; then
        local server_port=25565
    else
        local server_port=$(grep '^server-port=' "$server_properties" | cut -d '=' -f 2)
        if [ -z "$server_port" ]; then
            server_port=25565
        fi
    fi

    local server_status=$(systemctl is-active "minecraft@mcserver")
    if [ "$server_status" = "active" ]; then
        local ip_address=$(hostname -I | cut -d ' ' -f1)
        echo -e "${BLUE}.:: Installation Status:${NC} $minecraft_installed"
        echo -e "${BLUE}.:: Server Status:${NC} ${GREEN}● Active${NC}"
        echo -e "${BLUE}.:: Server Address:${NC} ${YELLOW}${ip_address}${NC}:${RED}${server_port}${NC}"
        echo -e "${BLUE}.:: Version:${NC} ${GREEN}$(get_current_version)${NC}"
    else
        echo -e "${BLUE}.:: Installation Status:${NC} $minecraft_installed"
        echo -e "${BLUE}.:: Server Status:${NC} ${RED}● Inactive${NC}"
    fi
}

function display_note {
    local terminal_width=$(tput cols)
    local note="${YELLOW}Note: You can update server properties from the location /opt/minecraft/server.properties. After making changes, remember to restart the Minecraft server for the updates to take effect.${NC}"

    if [ "$terminal_width" -lt ${#colored_note} ]; then
        echo -e "${note:0:$terminal_width-3}..."
    else
        echo -e "$note"
    fi
}

# Function to toggle daily server restart cronjob
function toggle_cronjob {
    local cronjob_file="${mcserver_dir}/dailyrestart.sh"
    if crontab -l | grep -q "$cronjob_file"; then
        (crontab -l | grep -v "$cronjob_file") | crontab -
        echo "cron job for disabled."
    else
        (crontab -l && echo "@daily /bin/bash $cronjob_file") | crontab -
        echo "cron job for enabled."
    fi
}

# Function to get the current status of the daily server restart cronjob
function get_cronjob_status {
    local cronjob_file="${mcserver_dir}/dailyrestart.sh"
    if crontab -l | grep -q "$cronjob_file"; then
        echo "enabled"
    else
        echo "disabled"
    fi
}

# Function to update allocated memory
function update_memory {
    prompt_user "Enter allocated memory in MB" allocated_memory
    allocated_memory=${allocated_memory:-1024}

    sed -i "s/-Xmx[0-9]*M/-Xmx${allocated_memory}M/" "/etc/systemd/system/minecraft@mcserver.service"
    sed -i "s/-Xms[0-9]*M/-Xms${allocated_memory}M/" "/etc/systemd/system/minecraft@mcserver.service"

    systemctl daemon-reload
    systemctl restart "minecraft@mcserver"

    echo "Allocated memory updated to $allocated_memory MB."
}

function main_menu {
    clear
    echo -e "$GREEN"
    echo -e "  _____ _                     ___ _      _____                     "
    echo -e " |     |_|___ ___ ___ ___ ___|  _| |_   |   __|___ ___ _ _ ___ ___ "
    echo -e " | | | | |   | -_|  _|  _| .'|  _|  _|  |__   | -_|  _| | | -_| _|"
    echo -e " |_|_|_|_|_|_|___|___|_| |__,|_| |_|    |_____|___|_|  \_/|___|_|  "
    echo -e "                                                                  "
    echo -e "$NC"
    echo -e "$BLUE~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~$NC"
    server_info
    echo -e "$BLUE~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~$NC"
    echo -e "${CYAN}1.$NC Install"
    echo -e "${CYAN}2.$NC Uninstall"
    echo -e "${CYAN}3.$NC Start"
    echo -e "${CYAN}4.$NC Stop"
    echo -e "${CYAN}5.$NC Restart"
    echo -e "${CYAN}6.$NC Update Allocated Memory"
    echo -e "${CYAN}7.$NC Toggle Daily Server Restart (Currently $(get_cronjob_status))"
    echo -e "${CYAN}8.$NC Open screen (logs)"
    echo -e "${CYAN}9.$NC Update Minecraft Server"
    echo -e "${RED}0. Exit$NC"
    echo $'\n'
    display_note
    echo $'\n'
    prompt_user "Enter your choice" choice
    case $choice in
    1) setup_server ;;
    2) uninstall_server ;;
    3) start_server ;;
    4) stop_server ;;
    5) restart_server ;;
    6) update_memory ;;
    7) toggle_cronjob ;;
    8) screen -r mc-server ;;
    9) update_minecraft ;;
    0) exit ;;
    *) display_error "Invalid choice. Please enter a number from 1 to 6." ;;
    esac
}

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
    display_error "This script must be run as root."
fi

while true; do
    main_menu
    read -rp "Press Enter to continue..."
done
