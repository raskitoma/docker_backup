# Docker Backup

## Introduction

A simple, you can call it primitive(maybe) but useful, backup system for your docker container's data. It's based on the idea of having a cron job that stops the container, makes a backup of the data, and then starts the container again. It also has the ability to make differential and incremental backups, without stopping the container.

> This script only backups the persistent data folders, not the container itself or its configuration. You need to backup any configuration (docker-compose.yml, etc.) separately.
{.is-warning}

## Installation

1. Pull the repo
2. Create the config file and folders using the guide below

## Standards

> This guide assumes you are using `/docker_data` as the storage path for docker container data.
> This guide also assumes you are using `/home/ubuntu` as the installation path.
> This guide assumes you are using `/mnt/docker_data_backup` as the mount path to store the backup files.
> We assume you have access to the `root` user, since you need it to access and store the data properly.
{.is-warning}

## Checklist

- [ ] User with privileges
- [ ] Access to container source path
- [ ] Access to backup destination path. This needs to be a mounted path, since the script checks if the path exists and next if the path is a mounted device. It's suggested to use some kind of remote path via sshfs. More information on how to do this, [here](https://www.digitalocean.com/community/tutorials/how-to-use-sshfs-to-mount-remote-file-systems-over-ssh).
- [ ] We need the destination path to be unique, that means, if we have a remote storage with a unique folder for all container backups like `/mnt/usb/backup/containers` inside this folder we need to create a folder for the current machine, something like `vm100` or `host-apps-01` inside it.
- [ ] Based on the last point, the destination path on the machine should be mounted locally as `/mnt/docker_data_backup`(on vm100) to `/mnt/usb/backup/containers/vm100` on the remote machine
- [ ] a Slack notification channel for alerts and its properly configured link
{.grid-list}

## The config file

We need to call it `config.ini` and it needs to be placed next to the script, you can copy the provided `config.sample.ini` file with `cp config.sample.ini config.ini` and then edit it.

> The script will check if the config file exists, if not, it will exit with an error message. Also, remove any comments from the file, since the script is not prepared to handle them.
{.is-warning}

### Config file details

```ini
[[master_params]]
source_path=/docker_data
destination_path=/mnt/docker_data_backup
destination_mountpoint=/mnt
log_path=/home/ubunt/docker_backup/logs
notification_path=/home/ubuntu/docker_backup/slack
snapshot_path=/home/ubuntu/docker_backup/snapshot_track
notification_base_name=slack_
log_retention_days=7

[[slack]]
slack_webhook=https://hooks.slack.com/services/XXXXXXXXX/XXXXXXXXXXX/XXXXXXXXXXXXXXXXXXXXXXXX
slack_channel=#sysalerts

[[containers]]

[container1_name]
stop=0 7 1 * * # Stop container1 and do a full backup at 7:00 AM on the 1st of every month
stop_diff=0 */4 * * * # Stop container1 and do a differential backup every 4 hours
stop_incr=
no_stop=
no_stop_diff=
no_stop_incr=0 6 * * * # Without stopping the container do a incremental backup of container1 at 6:00 AM every day
path=container1 # Path to the container data inside the source path
comment=Backup of Container 1

[container2_name]
stop=0 11,18 * * * # Stop container2 and do a full backup at 11:00 AM and 6:00 PM every day
stop_diff=
stop_incr=0 5 * * 1,3,5 # Stop container2 and do a incremental backup at 5:00 AM on Monday, Wednesday and Friday
no_stop=
no_stop_diff=0 10 * * 2,4,7 # Without stopping the container do a differential backup of container2 at 10:00 AM on Tuesday, Thursday and Sunday
no_stop_incr=0 6,12 * * * # Without stopping the container do a incremental backup of container2 at 6:00 AM and 12:00 PM every day
path=container2 # Path to the container data inside the source path
comment=Backup of Container 2
```

#### Config ini explanation

##### [[masterparams]]

Handles the master parameters:

- `source_path`: The path were all containers store its data (each on one subfolder).
- `destination_path`: The full destination path were we want to store our files, it could be the same as `destination_mountpoint` or it could be also a child inside it.
- `destination_mountpoint`: The base path for the `destination_path`. It's the actual path that the script will check if it's properly mounted.
- `log_path`: base path to store log data information.
- `notification_path`: path used by the script to store a tag to prevent multiple unnecesary notifications to Slack.
- `snapshot_path`: path used by the script to store snapshot information to permit the script work with Full, Differential and Incremental backups efficiently.
- `notification_base_name`: A string used by the script to start the notification slack file. The idea is, in the future, to have multiple notification services and tag them.
- `log_retention_days`: Controls how many days the logs are mantained.

##### [[containers]]

Here you need to setup a section for each docker service you have set in your system (or the ones you want to backup):

- `[container_name]`: Here goes the name of the cotainer (or its `id`). This is fundamental to allow proper start/stop operations
- `stop`: Using cron configuration(see below). Sets **FULL backup** schedule, **stopping** `container_name`. Leave it blank to disable it.**(optional)**.
- `stop_diff`:  Using cron configuration(see below). Sets **DIFFERENTIAL backup** schedule, **stopping** `container_name`. Leave it blank to disable it.**(optional)**.
- `stop_incr`:  Using cron configuration(see below). Sets **INCREMENTAL backup** schedule, **stopping** `container_name`. Leave it blank to disable it.**(optional)**.
- `no_stop`:  Using cron configuration(see below). Sets **FULL backup** schedule, **without stopping** `container_name`. Leave it blank to disable it.**(optional)**.
- `no_stop_diff`:  Using cron configuration(see below). Sets **DIFFERENTIAL backup** schedule, **without stopping** `container_name`. Leave it blank to disable it.**(optional)**.
- `no_stop_incr`:  Using cron configuration(see below). Sets **INCREMENTAL backup** schedule, **without stopping** `container_name`. Leave it blank to disable it.**(optional)**.
- `path`: the subfolder name inside the `source_path` folder. This can be the same as the `container_name`, but it could be different and it depends on each container configuration. **i.e.**: if the source files are at `/docker_data/container_data` this variable must be set as `container_data` **(required)**.
- `comment`: A description for the current config **(optional)**.

> even if stated that we're using cron config, the minute part of cron is not used, but it must be set as 0. 
{.is-warning}

> When an option is stated as **optional** means that you have to actually set it as "null".  i.e. `stop=` with no value set.
{.is-info}

> If you have multiple "source_paths", you need to actually clone the project to another folder.  The script is set to use only one main source
{.is-danger}

## Setting up the service

The service must be run by a user who has privileges, and must set via cron to run once every hour, so it can check the services against their configurations and then run/execute them if the conditions are met.

Just add to the cron using crontab as `0 * * * * * /home/ubuntu/docker_backup/docker_backup.sh`.

To check the status, just check the log folder.

## Contributions

Feel free to contribute to this project, it's a simple one, but it can be improved in many ways.
