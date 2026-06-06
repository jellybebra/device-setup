#!/usr/bin/env bash
set -euo pipefail

SSH_DIR="$HOME/.ssh"
KEY_BASE="$SSH_DIR/id_ed25519"
PUB_KEY_FILE="${KEY_BASE}.pub"
CONFIG_FILE="$SSH_DIR/config"

# Global arrays for parsed config
aliases=()
hostnames=()
ports=()
users=()
identityfiles=()

# Helper to parse SSH config
parse_ssh_config() {
    aliases=()
    hostnames=()
    ports=()
    users=()
    identityfiles=()

    if [[ ! -f "$CONFIG_FILE" ]]; then
        return
    fi

    local current_alias=""
    local current_hostname=""
    local current_port="22"
    local current_user=""
    local current_identityfile=""

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        # Trim leading/trailing whitespace
        local line
        line=$(echo "$raw_line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        
        # Skip empty lines and comments
        if [[ -z "$line" || "$line" =~ ^# ]]; then
            continue
        fi

        # Get key (first word) and value (the rest of the line)
        local key
        local val
        key=$(echo "$line" | awk '{print $1}')
        val=$(echo "$line" | cut -d' ' -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

        local key_lower
        key_lower=$(echo "$key" | tr '[:upper:]' '[:lower:]')

        if [[ "$key_lower" == "host" ]]; then
            # Save previous host block if it exists
            if [[ -n "$current_alias" && "$current_alias" != "*" ]]; then
                aliases+=("$current_alias")
                hostnames+=("${current_hostname:-}")
                ports+=("${current_port:-22}")
                users+=("${current_user:-}")
                identityfiles+=("${current_identityfile:-}")
            fi
            current_alias="$val"
            current_hostname=""
            current_port="22"
            current_user=""
            current_identityfile=""
        elif [[ "$key_lower" == "hostname" ]]; then
            current_hostname="$val"
        elif [[ "$key_lower" == "port" ]]; then
            current_port="$val"
        elif [[ "$key_lower" == "user" ]]; then
            current_user="$val"
        elif [[ "$key_lower" == "identityfile" ]]; then
            current_identityfile="$val"
        fi
    done < "$CONFIG_FILE"

    # Save last host block
    if [[ -n "$current_alias" && "$current_alias" != "*" ]]; then
        aliases+=("$current_alias")
        hostnames+=("${current_hostname:-}")
        ports+=("${current_port:-22}")
        users+=("${current_user:-}")
        identityfiles+=("${current_identityfile:-}")
    fi
}

# Interactive arrow-key selection menu
# Arguments:
#   $1 - Title
#   $2... - Menu options
# Returns selected index in global variable 'selected_index'
select_menu() {
    local title="$1"
    shift
    local options=("$@")
    local num_options=${#options[@]}
    local current=0
    local key

    # Hide cursor
    tput civis

    cleanup() {
        tput cnorm
        exit 0
    }
    trap cleanup SIGINT

    draw_menu() {
        echo -e "\033[1;36m$title\033[0m"
        for ((i=0; i<num_options; i++)); do
            if [ $i -eq $current ]; then
                echo -e " \033[1;32m> ${options[i]}\033[0m"
            else
                echo -e "   ${options[i]}"
            fi
        done
    }

    clear_menu() {
        for ((i=0; i<num_options+1; i++)); do
            tput cuu1
            tput el
        done
    }

    draw_menu

    while true; do
        read -rsn1 key
        if [[ "$key" == $'\x1b' ]]; then
            read -rsn2 -t 1 key
            if [[ "$key" == "[A" ]]; then
                # Up arrow
                clear_menu
                ((current--))
                if [ $current -lt 0 ]; then
                    current=$((num_options - 1))
                fi
                if [[ "${options[current]}" == "---------------------------" ]]; then
                    ((current--))
                    if [ $current -lt 0 ]; then
                        current=$((num_options - 1))
                    fi
                fi
                draw_menu
            elif [[ "$key" == "[B" ]]; then
                # Down arrow
                clear_menu
                ((current++))
                if [ $current -ge $num_options ]; then
                    current=0
                fi
                if [[ "${options[current]}" == "---------------------------" ]]; then
                    ((current++))
                    if [ $current -ge $num_options ]; then
                        current=0
                    fi
                fi
                draw_menu
            fi
        elif [[ "$key" == "" ]]; then
            # Enter key
            break
        fi
    done

    # Show cursor
    tput cnorm
    trap - SIGINT
    selected_index=$current
}

add_new_server() {
    clear
    echo -e "\033[1;36m=== Add a New Server ===\033[0m"
    
    read -r -p "Alias (e.g., work-server): " alias
    if [[ -z "$alias" ]]; then
        echo -e "\033[1;31m[!] Alias cannot be empty.\033[0m"
        sleep 2
        return
    fi
    
    # Check duplicate alias
    for existing in "${aliases[@]}"; do
        if [[ "$existing" == "$alias" ]]; then
            echo -e "\033[1;31m[!] A server with alias '$alias' already exists.\033[0m"
            sleep 2
            return
        fi
    done
    
    read -r -p "IP address: " ip
    if [[ -z "$ip" ]]; then
        echo -e "\033[1;31m[!] IP address cannot be empty.\033[0m"
        sleep 2
        return
    fi
    
    read -r -p "Port [22]: " port
    port="${port:-22}"
    
    read -r -p "Username [root]: " username
    username="${username:-root}"
    
    echo -e "\n\033[1;34m[i] Setting up SSH keys...\033[0m"
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    
    if [[ ! -f "$KEY_BASE" || ! -f "$PUB_KEY_FILE" ]]; then
        echo -e "\033[1;34m[i] Generating new SSH key pair (Ed25519)...\033[0m"
        ssh-keygen -t ed25519 -f "$KEY_BASE" -N ""
    fi
    
    local pub_key_content
    pub_key_content="$(cat "$PUB_KEY_FILE")"
    
    echo -e "\033[1;34m[i] Copying public key to remote host (you may be prompted for password)...\033[0m"
    
    if ssh -p "$port" -o ConnectTimeout=10 "$username@$ip" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -qxF '$pub_key_content' ~/.ssh/authorized_keys || echo '$pub_key_content' >> ~/.ssh/authorized_keys"; then
        echo -e "\033[1;32m[+] SSH key successfully copied to remote host!\033[0m"
    else
        echo -e "\033[1;31m[!] Failed to copy SSH key to remote host.\033[0m"
        read -r -p "Do you still want to save this server configuration? (y/N): " save_anyway
        if [[ ! "$save_anyway" =~ ^[Yy]$ ]]; then
            echo -e "\033[1;33m[i] Aborted.\033[0m"
            sleep 2
            return
        fi
    fi
    
    # Write configuration
    local tmp_config
    tmp_config=$(mktemp)
    if [[ -f "$CONFIG_FILE" ]]; then
        # Remove existing alias block if any
        awk -v alias="$alias" '
            BEGIN {skip=0}
            /^[[:space:]]*Host[[:space:]]+/ {
                if ($2 == alias) {skip=1; next}
                if (skip == 1) {skip=0}
            }
            skip == 0 {print}
        ' "$CONFIG_FILE" > "$tmp_config"
    else
        touch "$tmp_config"
    fi
    
    {
        printf "\nHost %s\n" "$alias"
        printf "  HostName %s\n" "$ip"
        printf "  Port %s\n" "$port"
        printf "  User %s\n" "$username"
        printf "  IdentityFile %s\n" "$KEY_BASE"
    } >> "$tmp_config"
    
    mv "$tmp_config" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    
    echo -e "\033[1;32m[+] Server '$alias' successfully configured and saved!\033[0m"
    sleep 2
}

edit_server() {
    local index="$1"
    local original_alias="${aliases[index]}"
    local current_alias="$original_alias"
    local current_ip="${hostnames[index]}"
    local current_port="${ports[index]}"
    local current_user="${users[index]}"
    local current_identity="${identityfiles[index]:-$KEY_BASE}"

    while true; do
        clear
        select_menu "=== Edit Server: $original_alias ===" \
            "Alias: $current_alias" \
            "IP Address: $current_ip" \
            "Port: $current_port" \
            "Username: $current_user" \
            "[ Save & Back ]" \
            "[ Cancel ]"
        
        local edit_choice=$selected_index
        
        if [ "$edit_choice" -eq 0 ]; then
            # Edit Alias
            read -r -p "Enter new Alias [$current_alias]: " input
            input="${input:-$current_alias}"
            if [[ "$input" != "$original_alias" ]]; then
                local exists=0
                for existing in "${aliases[@]}"; do
                    if [[ "$existing" == "$input" ]]; then
                        exists=1
                        break
                    fi
                done
                if [ $exists -eq 1 ]; then
                    echo -e "\033[1;31m[!] A server with alias '$input' already exists.\033[0m"
                    sleep 2
                    continue
                fi
            fi
            current_alias="$input"
        elif [ "$edit_choice" -eq 1 ]; then
            # Edit IP
            read -r -p "Enter new IP address [$current_ip]: " input
            current_ip="${input:-$current_ip}"
        elif [ "$edit_choice" -eq 2 ]; then
            # Edit Port
            read -r -p "Enter new Port [$current_port]: " input
            current_port="${input:-$current_port}"
        elif [ "$edit_choice" -eq 3 ]; then
            # Edit Username
            read -r -p "Enter new Username [$current_user]: " input
            current_user="${input:-$current_user}"
        elif [ "$edit_choice" -eq 4 ]; then
            # Save & Back
            local tmp_config
            tmp_config=$(mktemp)
            if [[ -f "$CONFIG_FILE" ]]; then
                awk -v alias="$original_alias" '
                    BEGIN {skip=0}
                    /^[[:space:]]*Host[[:space:]]+/ {
                        if ($2 == alias) {skip=1; next}
                        if (skip == 1) {skip=0}
                    }
                    skip == 0 {print}
                ' "$CONFIG_FILE" > "$tmp_config"
            else
                touch "$tmp_config"
            fi

            {
                printf "\nHost %s\n" "$current_alias"
                printf "  HostName %s\n" "$current_ip"
                printf "  Port %s\n" "$current_port"
                printf "  User %s\n" "$current_user"
                printf "  IdentityFile %s\n" "$current_identity"
            } >> "$tmp_config"

            mv "$tmp_config" "$CONFIG_FILE"
            chmod 600 "$CONFIG_FILE"

            echo -e "\033[1;32m[+] Server '$current_alias' successfully updated!\033[0m"
            sleep 1.5
            break
        elif [ "$edit_choice" -eq 5 ]; then
            # Cancel
            break
        fi
    done
}

delete_server() {
    local index="$1"
    local alias="${aliases[index]}"

    clear
    echo -e "\033[1;31m=== Delete Server: $alias ===\033[0m"
    read -r -p "Are you sure you want to delete '$alias' from config? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "\033[1;33m[i] Deletion canceled.\033[0m"
        sleep 1.5
        return
    fi

    local tmp_config
    tmp_config=$(mktemp)
    if [[ -f "$CONFIG_FILE" ]]; then
        awk -v alias="$alias" '
            BEGIN {skip=0}
            /^[[:space:]]*Host[[:space:]]+/ {
                if ($2 == alias) {skip=1; next}
                if (skip == 1) {skip=0}
            }
            skip == 0 {print}
        ' "$CONFIG_FILE" > "$tmp_config"
        mv "$tmp_config" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        echo -e "\033[1;32m[+] Server '$alias' successfully removed.\033[0m"
    else
        echo -e "\033[1;31m[!] Config file not found.\033[0m"
    fi
    sleep 1.5
}

# Main Loop
while true; do
    parse_ssh_config

    # Construct menu options
    menu_options=()
    for ((i=0; i<${#aliases[@]}; i++)); do
        display_name="${aliases[i]}"
        ip="${hostnames[i]}"
        user="${users[i]}"
        port="${ports[i]}"
        
        # Build pretty info string
        info=""
        if [[ -n "$user" ]]; then
            info="$user@"
        fi
        info="${info}${ip}"
        if [[ -n "$port" && "$port" != "22" ]]; then
            info="${info}:${port}"
        fi
        
        menu_options+=("$display_name ($info)")
    done

    menu_options+=("---------------------------" "[+] Add a new server" "[x] Exit")

    clear
    select_menu "=== SSH Server Manager ===" "${menu_options[@]}"
    choice=$selected_index

    # Check which option was chosen
    num_servers=${#aliases[@]}
    
    if [ "$choice" -lt "$num_servers" ]; then
        # Selected a server, show actions sub-menu
        server_alias="${aliases[choice]}"
        server_ip="${hostnames[choice]}"
        server_user="${users[choice]}"
        server_port="${ports[choice]}"

        while true; do
            clear
            select_menu "=== Server: $server_alias ($server_user@$server_ip:$server_port) ===" "Connect" "Edit" "Delete" "Manage" "[ Back ]"
            action_choice=$selected_index

            if [ "$action_choice" -eq 0 ]; then
                # Connect
                clear
                echo -e "\033[1;32mConnecting to $server_alias...\033[0m"
                echo "----------------------------------------"
                ssh "$server_alias" || true
                echo "----------------------------------------"
                read -rsn1 -p "Connection closed. Press any key to return to menu..."
                break
            elif [ "$action_choice" -eq 1 ]; then
                # Edit
                edit_server "$choice"
                break
            elif [ "$action_choice" -eq 2 ]; then
                # Delete
                delete_server "$choice"
                break
            elif [ "$action_choice" -eq 3 ]; then
                # Manage
                while true; do
                    clear
                    echo -e "\033[1;34m[i] Loading management options...\033[0m"
                    if ssh -o ConnectTimeout=3 "$server_alias" "command -v docker >/dev/null 2>&1"; then
                        docker_item="Install Docker (Already installed)"
                        docker_installed=1
                    else
                        docker_item="Install Docker"
                        docker_installed=0
                    fi

                    clear
                    select_menu "=== Manage: $server_alias ===" "Setup Hostname" "$docker_item" "[ Back ]"
                    manage_choice=$selected_index
                    if [ "$manage_choice" -eq 0 ]; then
                        clear
                        echo -e "\033[1;36m=== Setup Hostname: $server_alias ===\033[0m"
                        read -r -p "Enter new hostname: " new_hostname
                        if [[ -n "$new_hostname" ]]; then
                            if [[ ! "$new_hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]; then
                                echo -e "\n\033[1;31m[!] Invalid hostname. Only alphanumeric characters, hyphens, and dots are allowed.\033[0m"
                                read -rsn1 -p "Press any key to return..."
                                continue
                            fi
                            echo -e "\n\033[1;34m[i] Configuring hostname on remote server...\033[0m"
                            remote_cmd="sudo hostnamectl set-hostname '$new_hostname' && \
sudo sed -i '/^[[:space:]]*127\\.0\\.1\\.1/d' /etc/hosts && \
echo '127.0.1.1 $new_hostname' | sudo tee -a /etc/hosts > /dev/null"
                            if ssh -t "$server_alias" "$remote_cmd"; then
                                echo -e "\n\033[1;32m[+] Hostname successfully updated on remote server!\033[0m"
                            else
                                echo -e "\n\033[1;31m[!] Failed to update hostname on remote server.\033[0m"
                            fi
                            read -rsn1 -p "Press any key to return..."
                        fi
                    elif [ "$manage_choice" -eq 1 ]; then
                        clear
                        echo -e "\033[1;36m=== Install Docker: $server_alias ===\033[0m"
                        if [ $docker_installed -eq 1 ]; then
                            echo -e "\033[1;33m[i] Docker is already installed on this server.\033[0m"
                            read -rsn1 -p "Press any key to return..."
                            continue
                        fi
                        read -r -p "Do you want to install Docker on $server_alias? (y/N): " confirm_docker
                        if [[ "$confirm_docker" =~ ^[Yy]$ ]]; then
                            echo -e "\n\033[1;34m[i] Installing Docker on remote server...\033[0m"
                            remote_cmd="curl -sSL https://get.docker.com | sudo sh && \
if command -v apt-get >/dev/null 2>&1; then sudo apt-get update && sudo apt-get install -y unattended-upgrades && sudo dpkg-reconfigure --priority=low unattended-upgrades; fi"
                            if ssh -t "$server_alias" "$remote_cmd"; then
                                echo -e "\n\033[1;32m[+] Docker successfully installed on remote server!\033[0m"
                            else
                                echo -e "\n\033[1;31m[!] Failed to install Docker on remote server.\033[0m"
                            fi
                            read -rsn1 -p "Press any key to return..."
                        fi
                    elif [ "$manage_choice" -eq 2 ]; then
                        break
                    fi
                done
            elif [ "$action_choice" -eq 4 ]; then
                # Back
                break
            fi
        done

    elif [ "$choice" -eq "$((num_servers + 1))" ]; then
        # Add new server
        add_new_server
    elif [ "$choice" -eq "$((num_servers + 2))" ]; then
        # Exit
        clear
        echo "Goodbye!"
        exit 0
    fi
done