#!/bin/bash

mcserver_dir="/opt/minecraft"

if [ -t 1 ]; then
    # Define colors
    RED="\033[0;31m"
    GREEN="\033[0;32m"
    YELLOW="\033[0;33m"
    BLUE="\033[0;34m"
    CYAN="\033[0;36m"
    white="\033[1;37m"
    NC="\033[0m" # No Color
else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    CYAN=""
    white=""
    NC=""
fi

# Function to display error message and exit
function display_error {
    echo -e "${RED}Error: $1${NC}" >&2
}

# Function to prompt user for input
function prompt_user {
    local prompt_message=$1
    local variable_name=$2
    read -rp "$prompt_message: " "$variable_name"
}

# Credit: The spinner adapted from the bash-spinner project by Tasos Latsas (https://github.com/tlatsas/bash-spinner).
function _spinner() {
    # $1 start/stop
    # $2 display message
    # on stop : $3 process exit status
    #           $4 spinner function pid (supplied from stop_spinner)
    #           $5 err message

    local on_success="✓"
    local on_fail="✗"

    case $1 in
    start)
        i=1
        sp='⠏⠇⠧⠦⠴⠼⠸⠹⠙⠋'

        while :; do
            printf "\r${sp:i++%${#sp}:1} ${2}"
            sleep 0.15
        done
        ;;
    stop)
        if [[ -z ${4} ]]; then
            echo "spinner is not running.."
            exit 1
        fi

        kill $4 >/dev/null 2>&1

        echo -en "\r"
        if [[ $3 -eq 0 ]]; then
            echo -en "${GREEN}${on_success}${NC}"
        else
            echo -en "${RED}${on_fail}${NC}"
        fi
        echo -e " ${2}"

        if [[ -n "${5}" ]]; then
            echo -en "${RED}└─►"
            echo -e " ${5}${NC}"
        fi
        ;;
    *)
        echo "invalid argument, try {start/stop}"
        exit 1
        ;;
    esac
}

function start_spinner {
    # $1 : msg to display
    _message=$1
    _spinner "start" "${_message}" &
    # set global spinner pid
    _sp_pid=$!
    disown
}

function stop_spinner {
    # $1 : command exit status
    _spinner "stop" "${_message}" $1 $_sp_pid "${2}"
    unset _message
    unset _sp_pid
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
        start_spinner "Installing $package_name"
        apt-get install -y "$package_name" >/dev/null 2>&1
        stop_spinner $?
    fi
}

# Function to check Java version and install/update if necessary
function install_or_update_java {
    local java_version=$(java -version 2>&1 | grep version | awk '{print $3}' | tr -d \")

    if [ -z "$java_version" ]; then
        start_spinner "Java not found. Installing JDK 22"
        wget -O /tmp/jdk-22_linux-x64_bin.deb https://download.oracle.com/java/22/latest/jdk-22_linux-x64_bin.deb >/dev/null 2>&1
        dpkg -i /tmp/jdk-22_linux-x64_bin.deb >/dev/null 2>&1
        rm /tmp/jdk-22_linux-x64_bin.deb
        stop_spinner $?
    elif [[ "$java_version" != 22* ]]; then
        start_spinner "Java version $java_version found. Updating to JDK 22"
        wget -O /tmp/jdk-22_linux-x64_bin.deb https://download.oracle.com/java/22/latest/jdk-22_linux-x64_bin.deb >/dev/null 2>&1
        dpkg -i /tmp/jdk-22_linux-x64_bin.deb >/dev/null 2>&1
        rm /tmp/jdk-22_linux-x64_bin.deb
        stop_spinner $?
    fi
}

function get_latest_version {
    local manifest_url="https://launchermeta.mojang.com/mc/game/version_manifest.json"
    local manifest_data=$(curl -sSL "$manifest_url")
    echo "$manifest_data" | jq -r '.latest.release'
}

function get_current_version {
    echo $(unzip -p "$mcserver_dir/minecraft_server.jar" version.json | grep "name" | grep -oP '(?<=name": ")[^"]+')
}

# Function to get the Minecraft server download URL for a specific version or the latest version
function get_minecraft_server_url {
    local minecraft_version=$1
    local manifest_url="https://launchermeta.mojang.com/mc/game/version_manifest.json"
    local manifest_data=$(curl -sSL "$manifest_url")

    if [ "$minecraft_version" = "latest" ]; then
        minecraft_version="$(get_latest_version)"
    fi

    local version_object=$(echo "$manifest_data" | jq --arg version "$minecraft_version" '.versions[] | select(.id == $version)')
    if [ -z "$version_object" ]; then
        return 1
    fi

    local version_url=$(echo "$version_object" | jq -r '.url')

    local version_data=$(curl -sSL "$version_url")
    local server_download_url=$(echo "$version_data" | jq -r '.downloads.server.url')

    echo "$server_download_url"
}

# Function to check for updates and update the server JAR file
function update_minecraft {
    start_spinner "Checking for updates..."
    latest_version=$(get_latest_version)
    current_version=$(get_current_version)

    if [[ "$current_version" != "$latest_version" ]]; then
        stop_spinner $?
        start_spinner "New version available: $latest_version | Updating ..."
        wget -O "$mcserver_dir/minecraft_server.jar" "$(get_minecraft_server_url "$latest_version")" >/dev/null 2>&1
        systemctl restart "minecraft@mcserver"
        stop_spinner $?
    else
        stop_spinner 1 "Server is already up to date."
    fi
}

function setup_server {
    start_spinner "check $mcserver_dir"
    if [ -f "$mcserver_dir/minecraft_server.jar" ]; then
        stop_spinner 1 "Minecraft server is already installed. Setup aborted."
        return 1
    fi
    stop_spinner $?

    # Update system packages
    start_spinner "apt-get update & apt-get upgrade"
    apt-get update >/dev/null 2>&1
    apt-get upgrade -y >/dev/null 2>&1
    stop_spinner $?

    # Install required packages
    install_package "curl"
    install_package "jq"
    install_or_update_java
    install_package "screen"
    install_package "ufw"

    # Allow TCP connections on port 25565
    start_spinner "Allow TCP connections on port 25565"
    if ! ufw status | grep -q "25565"; then
        ufw allow 25565/tcp
    fi
    stop_spinner $?

    # Interactive setup
    prompt_user "Enter Minecraft version (default: latest)" minecraft_version
    minecraft_version=${minecraft_version:-"latest"}

    prompt_user "Enter allocated memory (in MB, default: 1024)" allocated_memory
    allocated_memory=${allocated_memory:-1024}

    # Create server directory and download server files
    start_spinner "Downloading Minecraft server version $minecraft_version..."
    mkdir -p "$mcserver_dir"
    if [[ $? -eq 1 ]]; then
        stop_spinner 1 "Failed to create server directory $mcserver_dir."
        return 1
    fi
    cd "$mcserver_dir"

    server_download_url=$(get_minecraft_server_url "$minecraft_version")
    wget -O minecraft_server.jar "$server_download_url" >/dev/null 2>&1
    if [[ $? -eq 1 ]]; then
        stop_spinner 1 "Failed to download server files."
        return 1
    fi

    # Accept EULA
    echo "eula=true" >eula.txt

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
    systemctl enable --now "minecraft@mcserver" >/dev/null 2>&1

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
    stop_spinner $?
    return 0
}

# Function to uninstall a server
function uninstall_server {
    start_spinner "Uninstalling ..."
    systemctl stop "minecraft@mcserver" >/dev/null 2>&1
    systemctl disable --now "minecraft@mcserver" >/dev/null 2>&1
    rm "/etc/systemd/system/minecraft@mcserver.service" >/dev/null 2>&1
    screen -ls | grep "mc-server" | awk '{print $1}' | xargs -I{} screen -X -S {} quit
    rm -rf $mcserver_dir
    systemctl daemon-reload
    stop_spinner $?
}

# Function to start Minecraft server
function start_server {
    start_spinner "Starting ..."
    systemctl start "minecraft@mcserver"
    stop_spinner $?
}

# Function to stop Minecraft server
function stop_server {
    start_spinner "Stoping ..."
    systemctl stop "minecraft@mcserver"
    stop_spinner $?
}

# Function to restart Minecraft server
function restart_server {
    start_spinner "Restarting ..."
    systemctl restart "minecraft@mcserver"
    stop_spinner $?
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
        start_spinner "Disabling cron job ..."
        (crontab -l | grep -v "$cronjob_file") | crontab -
        stop_spinner $?
    else
        start_spinner "Enabling cron job ..."
        (crontab -l && echo "@daily /bin/bash $cronjob_file") | crontab -
        stop_spinner $?
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

    start_spinner "Updating ..."
    sed -i "s/-Xmx[0-9]*M/-Xmx${allocated_memory}M/" "/etc/systemd/system/minecraft@mcserver.service"
    sed -i "s/-Xms[0-9]*M/-Xms${allocated_memory}M/" "/etc/systemd/system/minecraft@mcserver.service"

    systemctl daemon-reload
    systemctl restart "minecraft@mcserver"

    stop_spinner $?
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
    exit 1
fi

while true; do
    main_menu
    read -rp "Press Enter to continue..."
done
