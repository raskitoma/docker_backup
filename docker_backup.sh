#!/bin/bash

# Get the directory where the script is located
script_dir=$(dirname "$0")
echo "Script directory: $script_dir"

# Define the path to the INI file relative to the script's directory
config_ini_file="$script_dir/config.ini"
echo "INI file: $config_ini_file"

# Get the hostname
hostname=$(hostname)
echo "Hostname: $hostname"

# Check if the INI file exists
if [ ! -f "$config_ini_file" ]; then
    echo "Error: The INI file does not exist."
    exit 1
fi

# set new process event
new_process_event=true

# variable declaration
declare -A error_message=""
declare -A process_success=true
declare -A current_section=""
declare -A in_containers_section=false
declare -A container_processed=true
declare -a containers_process=()
declare -A containers_params
declare -a containers_config=()
declare -A error_log_file=""
declare -A backup_log_file=""
declare -a backed_up_containers=()
declare -A backed_up_containers_qty=0
declare -a not_backed_containers=()
declare -A not_backed_containers_qty=0

# Function to parse the variables
declare_variable() {
    local key=$(echo "$1" | cut -d'=' -f1)
    local value=$(echo "$1" | cut -d'=' -f2)
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        # If numeric, assign directly without quotes
        declare -gi "$key=$value"
    else
        # If not numeric, assign with quotes
        declare -g "$key=$value"
    fi
}

# Function to parse the sections
parse_section() {
    local container_name
    case "$1" in
        \[\[*\]\])
            current_section="${1//[[]/}"  # Remove the leading "[[" and trailing "]]"
            current_section="${current_section//]]/}"
            echo "Parsing section: [[$current_section]]"
            ;;
        \[*\])
            if [[ "$current_section" == "containers" ]]; then
                if [ "$in_containers_section" == false ]; then
                    echo "  - Entering containers section config: Storing to vars..."
                    in_containers_section=true
                fi
                echo "  - Setting container: $1"
                container_name="${1/\[/}"
                container_name="${container_name/\]/}"
                containers_process+=("$container_name")
                containers_config+=("$1")
            fi
            ;;
        *)
            if [[ "$in_containers_section" == false ]]; then
                declare_variable "$1"
            else
                containers_config+=("$1")
                echo "     - Parsing container config data: $1"
            fi
            ;;
    esac
}

# Function to parse the containers section
parse_containers() {
    local container_name
    for container_config in "${containers_config[@]}"; do
        if [[ "$container_config" == \[*\] ]]; then
            container_name="${container_config#[}"
            container_name="${container_name%]}"
        else
            container_params=$(echo "$container_config" | cut -d'=' -f1)
            value=$(echo "$container_config" | cut -d'=' -f2-)
            containers_params["$container_name/$container_params"]="$value"
        fi
    done
}

# Function that handles the backup process for the containers
backup_containers() {
    local stop_docker=false
    local execute_backup=false
    local docker_stopped=false
    local snapshot_option=""
    local execution_message=""
    local current_hour=$(date +%k | tr -d ' ')
    local current_dow=$(date +%u)
    local current_dom=$(date +%e)

    for current_container in "${containers_process[@]}"; do
        stop_docker=false
        execute_backup=false
        docker_stopped=false
        container_processed=true
        echo "[$(date +"%Y-%m-%d %T")] | [ $current_container ] | [ CONTAINER ] Processing container [$current_container]." 2>&1 | tee -a "$backup_log_file"
        for container_key in "${!containers_params[@]}"; do
            var_container_name="${container_key%%/*}"
            container_param="${container_key#*/}"
            container_param="${container_param##/}"
            container_value="${containers_params[$container_key]}"
            if [ "$var_container_name" == "$current_container" ]; then
                declare_variable "$container_param=$container_value"
            fi
        done

        # Check if the destination path exists for the container
        check_store_path "$current_container" "$destination_path" "$log_path"

        if [[ "$process_success" == true ]]; then
            # destination path exists, let's check the hours
            # based on cron like variables stop and no_stop

            # first let's check stopping cron
            if [ -n "$stop" ]; then
                # get the stop hours
                IFS=' ' read -ra cron_var <<< "$stop"
                # Let's check if the current hour, current day of the week, and current day
                if [[ "${cron_var[1]}" == "*" || "${cron_var[1]}" == "$current_hour" || "${cron_var[1]}" =~ (^|,)"$current_hour"($|,) ]] && \
                [[ "${cron_var[4]}" == "*" || "${cron_var[4]}" == "$current_dow" || "${cron_var[4]}" =~ (^|,)"$current_dow"($|,) ]] && \
                [[ "${cron_var[2]}" == "*" || "${cron_var[2]}" == "$current_dom" || "${cron_var[2]}" =~ (^|,)"$current_dom"($|,) ]]; then
                    execute_backup=true
                    stop_docker=true
                    backup_kind="FULL"
                fi
            fi

            if [ -n "$stop_diff" ]; then
                # get the stop hours
                IFS=' ' read -ra cron_var <<< "$stop_diff"
                # Let's check if the current hour, current day of the week, and current day
                if [[ "${cron_var[1]}" == "*" || "${cron_var[1]}" == "$current_hour" || "${cron_var[1]}" =~ (^|,)"$current_hour"($|,) ]] && \
                [[ "${cron_var[4]}" == "*" || "${cron_var[4]}" == "$current_dow" || "${cron_var[4]}" =~ (^|,)"$current_dow"($|,) ]] && \
                [[ "${cron_var[2]}" == "*" || "${cron_var[2]}" == "$current_dom" || "${cron_var[2]}" =~ (^|,)"$current_dom"($|,) ]]; then
                    execute_backup=true
                    stop_docker=true
                    backup_kind="DIFFERENTIAL"
                fi
            fi

            if [ -n "$stop_incr" ]; then
                # get the stop hours
                IFS=' ' read -ra cron_var <<< "$stop_incr"
                # Let's check if the current hour, current day of the week, and current day
                if [[ "${cron_var[1]}" == "*" || "${cron_var[1]}" == "$current_hour" || "${cron_var[1]}" =~ (^|,)"$current_hour"($|,) ]] && \
                [[ "${cron_var[4]}" == "*" || "${cron_var[4]}" == "$current_dow" || "${cron_var[4]}" =~ (^|,)"$current_dow"($|,) ]] && \
                [[ "${cron_var[2]}" == "*" || "${cron_var[2]}" == "$current_dom" || "${cron_var[2]}" =~ (^|,)"$current_dom"($|,) ]]; then
                    execute_backup=true
                    stop_docker=true
                    backup_kind="INCREMENTAL"
                fi
            fi

            # next, check non-stopping cron
            if [ -n "$no_stop" ]; then
                # get the hours
                IFS=' ' read -ra cron_var <<< "$no_stop"
                # Let's check if the current hour, current day of the week, and current day
                if [[ "${cron_var[1]}" == "*" || "${cron_var[1]}" == "$current_hour" || "${cron_var[1]}" =~ (^|,)"$current_hour"($|,) ]] && \
                [[ "${cron_var[4]}" == "*" || "${cron_var[4]}" == "$current_dow" || "${cron_var[4]}" =~ (^|,)"$current_dow"($|,) ]] && \
                [[ "${cron_var[2]}" == "*" || "${cron_var[2]}" == "$current_dom" || "${cron_var[2]}" =~ (^|,)"$current_dom"($|,) ]]; then
                    execute_backup=true
                    stop_docker=false
                    backup_kind="FULL"
                fi
            fi

            # next, check non-stopping cron
            if [ -n "$no_stop_diff" ]; then
                # get the hours
                IFS=' ' read -ra cron_var <<< "$no_stop_diff"
                # Let's check if the current hour, current day of the week, and current day
                if [[ "${cron_var[1]}" == "*" || "${cron_var[1]}" == "$current_hour" || "${cron_var[1]}" =~ (^|,)"$current_hour"($|,) ]] && \
                [[ "${cron_var[4]}" == "*" || "${cron_var[4]}" == "$current_dow" || "${cron_var[4]}" =~ (^|,)"$current_dow"($|,) ]] && \
                [[ "${cron_var[2]}" == "*" || "${cron_var[2]}" == "$current_dom" || "${cron_var[2]}" =~ (^|,)"$current_dom"($|,) ]]; then
                    execute_backup=true
                    stop_docker=false
                    backup_kind="DIFFERENTIAL"
                fi
            fi

            # next, check non-stopping cron
            if [ -n "$no_stop_incr" ]; then
                # get the hours
                IFS=' ' read -ra cron_var <<< "$no_stop_incr"
                # Let's check if the current hour, current day of the week, and current day
                if [[ "${cron_var[1]}" == "*" || "${cron_var[1]}" == "$current_hour" || "${cron_var[1]}" =~ (^|,)"$current_hour"($|,) ]] && \
                [[ "${cron_var[4]}" == "*" || "${cron_var[4]}" == "$current_dow" || "${cron_var[4]}" =~ (^|,)"$current_dow"($|,) ]] && \
                [[ "${cron_var[2]}" == "*" || "${cron_var[2]}" == "$current_dom" || "${cron_var[2]}" =~ (^|,)"$current_dom"($|,) ]]; then
                    execute_backup=true
                    stop_docker=false
                    backup_kind="INCREMENTAL"
                fi
            fi

            # if the execution should be done, let's do it
            if [[ "$execute_backup" == true ]]; then
                # if the container should be stopped, let's stop it
                if [ "$stop_docker" = true ]; then
                    echo "[$(date +"%Y-%m-%d %T")] | [ $current_container ] | Stopping container $current_container" 2>&1 | tee -a "$backup_log_file"
                    docker stop "$current_container" 2>&1
                    docker_exit_code=$?
                    if [ $docker_exit_code -ne 0 ]; then
                        echo "[$(date +"%Y-%m-%d %T")] | [ $current_container ] | -- Error stopping container $current_container: $(docker stop "$current_container" 2>&1)" 2>&1 | tee -a "$backup_log_file" >> "$error_log_file"
                        error_message="$error_message\nError stopping container $current_container: $(docker stop "$current_container" 2>&1)"
                        process_success=false
                        container_processed=false
                    else
                        echo "[$(date +"%Y-%m-%d %T")] | [ $current_container ] | -- Docker container $current_container stopped successfully" 2>&1 | tee -a "$backup_log_file"
                        docker_stopped=true
                    fi
                else
                    echo "[$(date +"%Y-%m-%d %T")] | [ $current_container ] | Configuration mandates that container $current_container should not be stopped." 2>&1 | tee -a "$backup_log_file"
                fi

                # Create backup of data from source to destination
                backup_date=$(date +%Y%m%d-%H)

                # Handling the snapshot file
                if [ "$backup_kind" = "FULL" ]; then
                    file_name_start="full"
                fi
                if [ "$backup_kind" = "DIFFERENTIAL" ]; then
                    file_name_start="diff"
                    cp "$snapshot_path/$current_container-full.file" "$snapshot_path/$current_container-diff.file"
                fi
                if [ "$backup_kind" = "INCREMENTAL" ]; then
                    file_name_start="incr"
                fi

                # Setting the snapshot option
                snapshot_option="--listed-incremental=$snapshot_path/$current_container-$backup_kind.file"

                # Backup the container
                echo "[$(date +"%Y-%m-%d %T")] | [ $current_container ] | Getting ---$backup_kind--- Backup of container $current_container" 2>&1 | tee -a "$backup_log_file"
                tar -czpf "$destination_path/$current_container/$file_name_start-$current_container-$backup_date.tar.gz" $snapshot_option "$source_path/$path" 2>&1
                tar_exit_code=$?
                if [ $tar_exit_code -ne 0 ]; then
                    tar_error=$(tar -czpf "$destination_path/$current_container/$file_name_start-$current_container-$backup_date.tar.gz" $snapshot_option "$source_path/$path" 2>&1)
                    echo "[$(date +"%Y-%m-%d %T")] | [ $current_container ] | -- Error compressing container $container_path: $tar_error" 2>&1 | tee -a "$backup_log_file" >> "$error_log_file"
                    error_message="$error_message\nError compressing container $container_path: $tar_error"
                    process_success=false
                    container_processed=false
                else
                    echo "[$(date +"%Y-%m-%d %T")] | [ $current_container ] | -- Backup of container $container_path completed successfully" 2>&1 | tee -a "$backup_log_file"
                fi

                # if we did a diff or incr backup, let's check if we have at least one full backup file
                if [ "$backup_kind" = "DIFFERENTIAL" ] || [ "$backup_kind" = "INCREMENTAL" ]; then
                    echo "================  test ---------------- $destination_path/$current_container/full-$current_container-"
                    local full_backup_files=("$destination_path/$current_container/full-$current_container-"*.tar.gz)
                    if [ ${#full_backup_files[@]} -eq 0 ]; then
                        echo "Full backup not found."
                        echo "[$(date +"%Y-%m-%d %T")] | [ $current_container ] | -- Error: Full backup not found, using current $backup_kind to create a full backup." 2>&1 | tee -a "$backup_log_file" >> "$error_log_file"
                        # copy the file as the first full backup
                        cp "$destination_path/$current_container/$file_name_start-$current_container-$backup_date.tar.gz" "$destination_path/$current_container/full-$current_container-$backup_date.tar.gz"
                        # duplicate the last snapshot file
                        cp "$snapshot_path/$current_container-$backup_kind.file" "$snapshot_path/$current_container-FULL.file"
                        echo "[$(date +"%Y-%m-%d %T")] | [ $current_container ] | -- Full backup created: $destination_path/$current_container/full-$current_container-$backup_date.tar.gz" 2>&1 | tee -a "$backup_log_file"
                    else
                        echo "Full backup found: ${full_backup_files[0]}"
                    fi
                fi

                # Start container if it was stopped
                if [[ "$docker_stopped" == true ]]; then
                    echo "[$(date +"%Y-%m-%d %T")] | [ $current_container ] | Starting container $current_container" 2>&1 | tee -a "$backup_log_file"
                    docker start "$current_container" 2>&1
                    docker_exit_code=$?
                    if [ $docker_exit_code -ne 0 ]; then
                        echo "[$(date +"%Y-%m-%d %T")] | [ $current_container ] | -- Error starting container $current_container: $(docker start "$current_container" 2>&1)" 2>&1 | tee -a "$backup_log_file" >> "$error_log_file"
                        error_message="$error_message\nError starting container $current_container: $(docker start "$current_container" 2>&1)"
                        process_success=false
                        container_processed=false
                    else
                        echo "[$(date +"%Y-%m-%d %T")] | [ $current_container ] | -- Docker container $current_container started successfully" 2>&1 | tee -a "$backup_log_file"
                    fi
                fi

            else
                container_processed=false
                echo "[$(date +"%Y-%m-%d %T")] | [ $current_container ] | Warning: Skipping, current cron settings(stop=$stop, no_stop=$no_stop) does not have a match" 2>&1 | tee -a "$backup_log_file" >> "$error_log_file"
                echo "[$(date +"%Y-%m-%d %T")] | [ $current_container ] | with current time(hour=$current_hour, DoM=$current_dom, DoW=$current_dow)." 2>&1 | tee -a "$backup_log_file" >> "$error_log_file"
            fi
        else
            container_processed=false
        fi

        if [[ "$container_processed" == true ]]; then
            backed_up_containers+=("$current_container")
            backed_up_containers_qty=$((backed_up_containers_qty+1))
            echo "[$(date +"%Y-%m-%d %T")] | [ $current_container ] | -- Success backing-up container." 2>&1 | tee -a "$backup_log_file"
        else
            not_backed_containers+=("$current_container")
            not_backed_containers_qty=$((not_backed_containers_qty+1))
            echo "[$(date +"%Y-%m-%d %T")] | [ $current_container ] | -- Error or condition prevented backup of container. Check logs." 2>&1 | tee -a "$backup_log_file" >> "$error_log_file"
        fi
    done
}

# Function to check if the destination mount point is available
check_mountpoint() {
    response=""
    if [ ! -d "$destination_mountpoint" ] || ! mountpoint -q "$destination_mountpoint"; then
        echo "[$(date +"%Y-%m-%d %T")] | [ $hostname ] | [ CRITICAL ] Error: $destination_mountpoint does not exist or is not a mount point." 2>&1 | tee -a "$backup_log_file" >> "$error_log_file"
        response="Error: $destination_mountpoint does not exist or is not a mount point."
    fi
    echo "$response"
}

# Function to check if the destination path exists for the container
check_store_path() {
    local container_name="$1"
    local destination_path="$2"
    local log_path="$3"
    if [ ! -d "$destination_path/$container_name" ]; then
        echo "[$(date +"%Y-%m-%d %T")] | [ $container_name ] | -- Warning: The destination path does not exist for container $container_name, creating folder..." 2>&1 | tee -a "$backup_log_file" >> "$error_log_file"
        mkdir -p "$destination_path/$container_name" 2>&1
        if [ $? -eq 0 ]; then
            echo "[$(date +"%Y-%m-%d %T")] | [ $container_name ] | -- Success: The destination path for container $container_name was created." 2>&1 | tee -a "$backup_log_file"
        else
            echo "[$(date +"%Y-%m-%d %T")] | [ $container_name ] | -- Error: The destination path cannot be created for container $container_name! $(mkdir -p "$destination_path/$container_name" 2>&1)" 2>&1 | tee -a "$backup_log_file" >> "$error_log_file"
            error_message="$error_message\nFailed to create destination path for container $container_name. $(mkdir -p "$destination_path/$container_name" 2>&1)"
            process_success=false
        fi
    fi
}

# Function to send notification to Slack
send_to_slack() {
    # Check if we already sent a notification for today:
    if [ ! -f "$notification_path/last_notification_date.txt" ] || [ "$(date +%Y-%m-%d)" != "$(cat "$notification_path/last_notification_date.txt")" ]; then
        # Check if slack_webhook variable is set
        if [ -z "$slack_webhook" ]; then
            echo "Error: Slack webhook URL is not provided."
        else
            # Define the Slack webhook URL
            webhook_url="$slack_webhook"

            # Send the message to Slack
            message="$1"
            if command -v curl &> /dev/null; then
                curl -X POST -H 'Content-type: application/json' --data "{\"channel\":\"$slack_channel\",\"text\":\"$message\"}" "$webhook_url"
            elif command -v wget &> /dev/null; then
                wget --quiet --method=POST --header 'Content-type: application/json' --body-data "{\"channel\":\"$slack_channel\",\"text\":\"$message\"}" "$webhook_url" -O /dev/null
            else
                echo "Error: Neither curl nor wget is available."
            fi
        fi
        echo "$(date +%Y-%m-%d)" > "$notification_path/last_notification_date.txt"
    fi
}


# ############################################################
# The actual script starts here
# Read the config file line by line
echo "Starting parsing of config file..."
while IFS= read -r line; do
    # Skip empty lines and comments
    if [ -n "$line" ] && [[ "$line" != \#* ]]; then
        parse_section "$line"
    fi
done < "$config_ini_file"

# Settig up log files
error_log_file="$log_path/$(date +"%Y-%m-%d")_error.log"
backup_log_file="$log_path/$(date +"%Y-%m-%d")_backup.log"

# Parse the containers section
echo "Finishing parsing config file, parsing containers..."
parse_containers

# Run process
echo ""
echo "Starting backup process for $hostname"
echo "[$(date +"%Y-%m-%d %T")] | [ $hostname ] | " 2>&1 | tee -a "$backup_log_file" >> "$error_log_file"
echo "[$(date +"%Y-%m-%d %T")] | [ $hostname ] | [ START ] === [ START ] === [ START ] === [ START ] === [ START ] " 2>&1 | tee -a "$backup_log_file" >> "$error_log_file"
echo "[$(date +"%Y-%m-%d %T")] | [ $hostname ] | Docker Container Backup process for $hostname started..." 2>&1 | tee -a "$backup_log_file" >> "$error_log_file"

# Check if the destination mount point is available
echo ""
if [[ "$check_the_mountpoint" == "1" ]]; then
    echo "Checking mountpoint: $destination_mountpoint"
    error_message=$(check_mountpoint)
else
    echo "Skipping mountpoint check."
fi

if [ -n "$error_message" ]; then
    echo "Error: $error_message"
    process_success=false
else
    # Run backup for containers
    echo ""
    echo "***** Running backup for containers <<<<<"
    backup_containers
    echo "***** Ending backup for containers >>>>>"
fi

# MAINTENANCE: Delete log files older than or equal to log_retention_days
# filenames are as 2024-02-09_backup.log and 2024-02-09_error.log
# The retention date policy should delete the files if the date in the filename is older than the retention date
# retention date is calculated as current date - log_retention_days. You should include the possibility of 0 days retention.
if [ "$log_retention_days" -eq 0 ]; then
    retention_date=$(date +"%Y-%m-%d")
else
    retention_date=$(date -d "$log_retention_days days ago" +"%Y-%m-%d")
fi

# Log deletion operation
echo "[$(date +"%Y-%m-%d %T")] | [ $hostname ] | Deleting log files older than $retention_date" 2>&1 | tee -a "$backup_log_file"

# Delete log files older than retention date
if [ -d "$log_path" ]; then
    find "$log_path" -name "*_backup.log" -type f \( -mtime +"$((log_retention_days+1))" -o -mtime "$log_retention_days" \) -delete
    find "$log_path" -name "*_error.log" -type f \( -mtime +"$((log_retention_days+1))" -o -mtime "$log_retention_days" \) -delete
else
    echo "Log directory not found: $log_path" 2>&1 | tee -a "$backup_log_file" >> "$error_log_file"
fi

# write report of the process
echo "[$(date +"%Y-%m-%d %T")] | [ $hostname ] | - Backup process report:" 2>&1 | tee -a "$backup_log_file"
echo "[$(date +"%Y-%m-%d %T")] | [ $hostname ] |   - Backed up containers: ${backed_up_containers[@]}" 2>&1 | tee -a "$backup_log_file"
echo "[$(date +"%Y-%m-%d %T")] | [ $hostname ] |   - Containers not proccessed: ${not_backed_containers[@]}" 2>&1 | tee -a "$backup_log_file"
echo "[$(date +"%Y-%m-%d %T")] | [ $hostname ] |   - Total backed up containers: $backed_up_containers_qty ($not_backed_containers_qty not processed)" 2>&1 | tee -a "$backup_log_file"

# Send notification to Slack if there are errors
if [[ "$process_success" == false ]]; then
    send_to_slack "$error_message"
    echo "[$(date +"%Y-%m-%d %T")] | [ $hostname ] | [ ERROR ] Backup process unsuccessfull for $hostname" 2>&1 | tee -a "$backup_log_file" >> "$error_log_file"
else
    echo "[$(date +"%Y-%m-%d %T")] | [ $hostname ] | [ SUCCESS ] Backup process completed successfully for $hostname" 2>&1 | tee -a "$backup_log_file"
    # reset notification date
    echo "" > "$notification_path/last_notification_date.txt"
fi

echo "[$(date +"%Y-%m-%d %T")] | [ $hostname ] | [  END  ] === [  END  ] === [  END  ] === [  END  ] === [  END  ] " 2>&1 | tee -a "$backup_log_file" >> "$error_log_file"
