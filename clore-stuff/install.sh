#!/bin/bash

CLORE_HOSTING_DIRECTORY="/opt/clore-hosting"

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi
if [ "$(uname -m)" != "x86_64" ]
  then echo "Your system type needs to be x86_64"
  exit
fi
if [ "$(awk -F= '/^NAME/{print $2}' /etc/os-release)" != '"Ubuntu"' ]
  then echo "Only ubuntu is supported distro"
  exit
fi
WORKARG="false"
for arg in "$@"; do
  if [ "$arg" = "-nq" ]; then
    WORKARG="true"
  fi
done
export DEBIAN_FRONTEND=noninteractive
AUTH_FILE=/opt/clore-hosting/client/auth

usage() {
    echo "Usage: $0 [--init-token <initialization token>]"
    exit 1
}

# Check if the NVIDIA driver is present
if ! command -v nvidia-smi &> /dev/null
then
    echo "NVIDIA driver not found. Exiting."
    exit 1
fi

REMOVED_AUTH=false
INIT_TOKEN=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --init-token)
            if [ -n "$2" ]; then
                INIT_TOKEN="$2"
                shift
            else
                echo "Error: --init-token requires a value."
                usage
            fi
            ;;
        *)
            echo "Error: Invalid argument $1"
            usage
            ;;
    esac
    shift
done

if [ -n "$INIT_TOKEN" ]; then
    TOKEN_LENGTH=${#INIT_TOKEN}

    if [ "$TOKEN_LENGTH" -eq 48 ]; then
        # Check if the auth file exists
        if [ -f "$AUTH_FILE" ]; then
            echo "The machine is already authorized."
            read -p "Do you want to use the new token and remove the existing login? The old authorization cannot be recovered. (y/N): " CONFIRM
            case $CONFIRM in
                [Yy]* | [Yy][Ee][Ss])
                    # Remove the auth file
                    rm -f $AUTH_FILE
                    if [ $? -eq 0 ]; then
                        echo "Existing login removed. New token will be used."
                        REMOVED_AUTH=true
                    else
                        echo "Error: Failed to remove the existing login file."
                        exit 1
                    fi
                    ;;
                *)
                    echo "Operation cancelled. Existing login retained."
                    exit 0
                    ;;
            esac
        fi
    else
        echo "Error: Invalid Token"
        exit 1
    fi
fi

if [ -f "/usr/sbin/iptables-legacy" ]; then
    update-alternatives --set iptables /usr/sbin/iptables-legacy
fi

if [ -x "$(command -v docker)" ]; then
  apt update -y
  if test -f "$AUTH_FILE"; then
    echo '...'
  else
    apt upgrade -y
  fi
else
    apt update -y
    apt install ca-certificates curl gnupg lsb-release git tar speedtest-cli ufw gnupg2 -y
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    chmod a+r /etc/apt/keyrings/docker.gpg
    apt update -y
    apt install docker-ce docker-ce-cli containerd.io docker-compose-plugin -y
fi
if [ -x "$(command -v docker)" ]; then
  docker network create   --driver=bridge   --subnet=172.18.0.0/16   --ip-range=172.18.0.0/16   --gateway=172.18.0.1   clore-br0 &>/dev/null
  docker pull cloreai/jupyter:ubuntu24.04-v2
  docker pull cloreai/openvpn-proxy:0.1
else
  echo "docker instalation failure" && exit
fi
kernel_version=$(uname -r)
hive_str='hiveos'
distribution=$(. /etc/os-release;echo $ID$VERSION_ID) \
      && curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
      && curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
            sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
            sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt update
apt install -y nvidia-docker2
apt remove nodejs -y
#curl -sL https://deb.nodesource.com/setup_16.x | sudo bash -
#apt install nodejs -y
if [ "$WORKARG" = "true" ]; then
  if test -f "$AUTH_FILE"; then
    echo ''
  else
    mkdir /opt/clore-hosting/ &>/dev/null
    echo '{
    "runtimes": {
        "nvidia": {
            "path": "/usr/bin/nvidia-container-runtime",
            "runtimeArgs": []
        }
    }
}' | sudo tee /etc/docker/daemon.json > /dev/null
    systemctl restart docker.service
  fi
elif [ -f "$AUTH_FILE" ] || [ "$REMOVED_AUTH" = true ]; then
    read -p "You have already installed clore hosting software, do you want to upgrade to current version? (yes/no) " yn

    case $yn in 
    	yes ) echo ok, we will proceed;;
      y ) echo ok, we will proceed;;
    	no ) echo exiting...;
    		exit;;
      n ) echo exiting...;
    		exit;;
    	* ) echo invalid response;
    		exit 1;;
    esac
else
  mkdir /opt/clore-hosting/ &>/dev/null
  echo '{
    "runtimes": {
        "nvidia": {
            "path": "/usr/bin/nvidia-container-runtime",
            "runtimeArgs": []
        }
    }
}' | sudo tee /etc/docker/daemon.json > /dev/null
    systemctl restart docker.service
fi
mkdir /opt/clore-hosting/startup_scripts &>/dev/null
mkdir /opt/clore-hosting/wireguard &>/dev/null
mkdir /opt/clore-hosting/wireguard/configs &>/dev/null
mkdir /opt/clore-hosting/client &>/dev/null

folder_exists() {
    if [ -d "$1" ]; then
        return 0  # True
    else
        return 1  # False
    fi
}

# Function to check if a file exists
file_exists() {
    if [ -f "$1" ]; then
        return 0  # True
    else
        return 1  # False
    fi
}

if ! file_exists "$CLORE_HOSTING_DIRECTORY/.miniconda/bin/conda"; then
    cd $CLORE_HOSTING_DIRECTORY
    if file_exists "$CLORE_HOSTING_DIRECTORY/Miniconda3-latest-Linux-x86_64.sh"; then
        rm Miniconda3-latest-Linux-x86_64.sh
    fi
    if curl -sSf https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -o Miniconda3-latest-Linux-x86_64.sh; then
        echo "Miniconda downloaded"
    else
        echo "Failed downloading miniconda"
        exit 1
    fi
    chmod +x Miniconda3-latest-Linux-x86_64.sh
    bash Miniconda3-latest-Linux-x86_64.sh -b -p /opt/clore-hosting/.miniconda && rm Miniconda3-latest-Linux-x86_64.sh
    if [ $? -ne 0 ]; then
        echo "Failed installing miniconda"
        exit 1
    fi
fi

if ! file_exists "$CLORE_HOSTING_DIRECTORY/.miniconda/bin/conda"; then
    echo "Failed to locate miniconda"
    exit 1
else
    if ! folder_exists "$CLORE_HOSTING_DIRECTORY/.miniconda-env"; then
        # ─── Ensure conda-anaconda-tos plugin is installed ─────────────────────────
        /opt/clore-hosting/.miniconda/bin/conda install -y -c anaconda conda-anaconda-tos
        # ─── Auto-accept any future TOS without prompting ──────────────────────────
        export CONDA_PLUGINS_AUTO_ACCEPT_TOS=true
        /opt/clore-hosting/.miniconda/bin/conda create -y -k --prefix /opt/clore-hosting/.miniconda-env python=3.12.1 -y
        if [ $? -ne 0 ]; then
            if folder_exists "$CLORE_HOSTING_DIRECTORY/.miniconda-env"; then
                rm /opt/clore-hosting/.miniconda-env
            fi
            echo "Failed creating python environment"
            exit 1
        fi
    fi
fi

cd $CLORE_HOSTING_DIRECTORY

if folder_exists "$CLORE_HOSTING_DIRECTORY/hosting"; then
    rm -rf "$CLORE_HOSTING_DIRECTORY/hosting"
fi
git clone https://git.clore.ai/clore/hosting.git
if [ $? -ne 0 ]; then
    echo "cloning https://git.clore.ai/clore/hosting.git failed. Exiting the script."
    exit 1
fi

cd hosting

source /opt/clore-hosting/.miniconda/etc/profile.d/conda.sh && conda activate /opt/clore-hosting/.miniconda-env && pip install -r requirements.txt

if [ $? -ne 0 ]; then
    echo "Failed installing requirements"
    exit 1
fi

if file_exists "/opt/clore-hosting/clore.sh"; then
    rm /opt/clore-hosting/clore.sh
fi

tee /opt/clore-hosting/clore.sh > /dev/null <<'EOT'
#!/bin/bash
source /opt/clore-hosting/.miniconda/etc/profile.d/conda.sh && conda activate /opt/clore-hosting/.miniconda-env
cd /opt/clore-hosting/hosting
python3 hosting.py "\$@"
EOT
chmod +x /opt/clore-hosting/clore.sh
if file_exists "/opt/clore-hosting/service.sh"; then
    rm /opt/clore-hosting/service.sh
fi
tee /opt/clore-hosting/service.sh > /dev/null <<'EOT'
#!/bin/bash
source /opt/clore-hosting/.miniconda/etc/profile.d/conda.sh && conda activate /opt/clore-hosting/.miniconda-env
CLIENT_DIR=/opt/clore-hosting/hosting
cd $CLIENT_DIR
counter=0

while true
do
    if test -f "/opt/clore-hosting/client/auth"; then
        # Run pip install on the first iteration and every 15th iteration thereafter
        if [ $((counter % 15)) -eq 0 ]; then
            echo "Installing dependencies..."
            pip install -r requirements.txt
        fi
        
        # Run the hosting software
        python3 hosting.py --service
    fi
    counter=$((counter + 1))
    sleep 5
done
EOT

if file_exists "/etc/systemd/system/clore-hosting.service"; then
    rm /etc/systemd/system/clore-hosting.service
fi
tee -a /etc/systemd/system/clore-hosting.service > /dev/null <<EOT
[Unit]
Description=CLORE.AI Hosting service

[Service]
User=root
ExecStart=/opt/clore-hosting/service.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOT

chmod +x /opt/clore-hosting/service.sh
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
systemctl enable clore-hosting.service
systemctl enable docker.service
systemctl enable docker.socket

if [ -n "$INIT_TOKEN" ]; then
  source /opt/clore-hosting/.miniconda/etc/profile.d/conda.sh && conda activate /opt/clore-hosting/.miniconda-env
  cd /opt/clore-hosting/hosting
  pip install -r requirements.txt
  /opt/clore-hosting/clore.sh --init-token "$INIT_TOKEN"
  systemctl restart clore-hosting.service
elif test -f "$AUTH_FILE"; then
  source /opt/clore-hosting/.miniconda/etc/profile.d/conda.sh && conda activate /opt/clore-hosting/.miniconda-env
  cd /opt/clore-hosting/hosting
  pip install -r requirements.txt
  systemctl restart clore-hosting.service
  echo "Your machine is updated to latest hosting software (v6.0.0)"
else
  source /opt/clore-hosting/.miniconda/etc/profile.d/conda.sh && conda activate /opt/clore-hosting/.miniconda-env
  cd /opt/clore-hosting/hosting
  pip install -r requirements.txt
  echo "------INSTALATION COMPLETE------"
  echo "For connection to clore ai use /opt/clore-hosting/clore.sh --init-token <token>"
  echo "and then reboot"
fi
