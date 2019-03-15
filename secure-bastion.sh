#!/bin/bash

function install_prerequisites() {
    # Identifying disto type
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        local DISTRO_IDS=$ID_LIKE
    else
        echo "ERROR: Unable to read /etc/os-release file. Exiting."
        exit 1
    fi

    PKG_MGR="apt"
    for DISTRO_ID in $DISTRO_IDS
    do
        if [ "${DISTRO_ID}" = "centos" ] || [ "${DISTRO_ID}" = "rhel" ] || [ "${DISTRO_ID}" = "fedora" ]; then
            PKG_MGR="yum"
        fi
    done

    echo "================================================"
    echo "Updating ${PKG_MGR} package..."
    echo "================================================"
    ${PKG_MGR} update -y

    echo "================================================"
    echo "Installing pip..."
    echo "================================================"
    ${PKG_MGR} install python-pip -y

    echo "================================================"
    echo "Installing awscli..."
    echo "================================================"
    if [ "${PKG_MGR}" == "apt" ]; then export LC_ALL=C; fi
    pip install awscli
}

function setup_bastion() {
    echo "================================================"
    echo "Setting up bastion server"
    echo "================================================"
    # Creating directory for session log
    mkdir /var/log/bastion

    if [ "${PKG_MGR}" = "apt" ]; then
        SU_GROUP="sudo"
    else
        SU_GROUP="wheel"
    fi

    # Creating owner of bastion log files
    useradd -G ${SU_GROUP} -m -s /bin/bash bastion
    chown bastion:bastion /var/log/bastion
    chmod -R 770 /var/log/bastion

    # Creating RSA Key Pair
    mkdir /home/bastion/.ssh
    ssh-keygen -t rsa -b 4096 -C "bastion" -N "" -f /home/bastion/.ssh/authorized_keys
    mv /home/bastion/.ssh/authorized_keys /home/bastion/bastion.pem
    mv /home/bastion/.ssh/authorized_keys.pub /home/bastion/.ssh/authorized_keys
    chmod 700 /home/bastion/.ssh/
    chmod 600 /home/bastion/.ssh/authorized_keys
    chown -R bastion:bastion /home/bastion/
    echo "bastion ALL=(ALL)  NOPASSWD: ALL" >> /etc/sudoers

    # Printing private key of bastion user
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "Private key of bastion user is saved at /home/bastion/bastion.pem"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"

    # Forcing custom script execution on SSH login
    echo -e "\nForceCommand /usr/bin/bastion/shell" >> /etc/ssh/sshd_config

    # Removing features from SSH
    # awk filters content of file ignoring line starting with text provided within the quotes. Default action of awk command is to print
    awk '!/AllowTcpForwarding/' /etc/ssh/sshd_config > temp && mv temp /etc/ssh/sshd_config
    awk '!/X11Forwarding/' /etc/ssh/sshd_config > temp && mv temp /etc/ssh/sshd_config
    echo "AllowTcpForwarding no" >> /etc/ssh/sshd_config
    echo "X11Forwarding no" >> /etc/ssh/sshd_config

    # Creating script to record user's session
    mkdir /usr/bin/bastion
    cat > /usr/bin/bastion/shell <<EOL
if [[ -z $SSH_ORIGINAL_COMMAND ]]; then
    SUFFIX="`mktemp -u XXXXXXXXXX`"
    LOG_FILE="`date --date="today" "+%Y-%m-%d_%H-%M-%S"`_`whoami`_${SUFFIX}"
    LOG_DIR="/var/log/bastion/"
    echo ""
    echo "======================================="
    echo "NOTE: This SSH session will be recorded"
    echo "======================================="
    echo ""
    script -qf --timing=${LOG_DIR}${LOG_FILE}.time ${LOG_DIR}${LOG_FILE}.data --command=/bin/bash
else
    echo "This bastion supports interactive sessions only. Do not supply a command"
    exit 1
fi
EOL

    chmod a+x /usr/bin/bastion/shell
    chown root:bastion /usr/bin/script
    chmod g+s /usr/bin/script

    # Preventing bastion users to view other users processes
    mount -o remount,rw,hidepid=2 /proc
    awk '!/proc/' /etc/fstab > temp && mv temp /etc/fstab
    echo "proc /proc proc defaults,hidepid=2 0 0" >> /etc/fstab

    # Restart SSH service
    service sshd restart

    # Sync audit files to S3
    crontab -l > /tmp/tmpcron
    echo "* * * * * $(which aws) s3 sync /var/log/bastion/ s3://genome-bastion-logs --region us-east-1" >> /tmp/tmpcron
    crontab /tmp/tmpcron
    rm -f /tmp/tmpcron

    echo "================================================"
    echo "Bastion server setup completed successfully"
    echo "================================================"
}

function setup_mail_service() {
    echo ""
    echo "================================================"
    echo "Setting up mail server"
    echo "================================================"
    read -p "Email server URL: " EMAIL_SERVER_URL
    read -p "Email server Port: " EMAIL_SERVER_PORT
    read -p "SMTP Username: " SMTP_USERNAME
    read -p "SMTP Password: " SMTP_PASSWORD

    if [ "${PKG_MGR}" = "apt" ]; then
        echo "postfix postfix/mailname string $(hostname)" | debconf-set-selections
        echo "postfix postfix/main_mailer_type string 'Internet Site'" | debconf-set-selections
        echo "postfix postfix/relayhost string ${EMAIL_SERVER_URL}:${EMAIL_SERVER_PORT}" | debconf-set-selections

        CA_FILE="/etc/ssl/certs/ca-certificates.crt"
    else
        CA_FILE="/etc/ssl/certs/ca-bundle.crt"
    fi
    ${PKG_MGR} remove sendmail -y
    ${PKG_MGR} install postfix -y
    ${PKG_MGR} install cyrus-sasl-plain -y
    # alternatives --set mta /usr/sbin/postfix

    echo "smtp_tls_note_starttls_offer = yes
    smtp_tls_security_level = encrypt
    smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
    smtp_sasl_security_options = noanonymous
    smtp_sasl_auth_enable = yes
    smtp_use_tls = yes
    smtp_tls_CAfile = ${CA_FILE}
    " >> /etc/postfix/main.cf

    echo "${EMAIL_SERVER_URL}:${EMAIL_SERVER_PORT} ${SMTP_USERNAME}:${SMTP_PASSWORD}" > /etc/postfix/sasl_passwd
    postmap hash:/etc/postfix/sasl_passwd
    chown root:root /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.db
    chmod 0600 /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.db
    postfix start
    postfix reload

    echo "================================================"
    echo "Email server setup completed successfully"
    echo "================================================"
}

function setup_2FA() {
    echo ""
    echo "================================================"
    echo "Setting up 2FA"
    echo "================================================"
    if [ "${PKG_MGR}" = "apt" ]; then
        apt install libpam-google-authenticator -y
    else
        yum install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm -y
        yum install google-authenticator -y
    fi

    awk '!/auth       substack     password-auth/' /etc/pam.d/sshd > temp && mv temp /etc/pam.d/sshd
    echo "auth       required     pam_google_authenticator.so" >> /etc/pam.d/sshd

    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    echo "Port 46285" >> /etc/ssh/sshd_config
    echo "PermitRootLogin no" >> /etc/ssh/sshd_config
    echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
    echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
    echo "UsePAM yes" >> /etc/ssh/sshd_config

    # Allowing admin user to login without 2FA
    cat >> /etc/ssh/sshd_config << EOL
Match User "$(whoami),bastion"
    AuthenticationMethods "publickey"
Match User "*,!$(whoami),!bastion"
    AuthenticationMethods "keyboard-interactive,publickey"
EOL

    # Restart SSH service
    service sshd restart

    echo "================================================"
    echo "2FA setup completed successfully"
    echo "================================================"
}

function create_bastion_user() {
    local username ; local email ; local superuser
    read -p "User Name: " username
    read -p "Email Address: " email
    read -p "Super User Access[y/N]: " superuser

    declare -l su=$superuser

    # Add user and create RSA Key Pair
    useradd -m -s /bin/bash ${username}
    mkdir -p /home/${username}/.ssh  
    ssh-keygen -t rsa -b 4096 -C "${email}" -N "" -f /home/${username}/.ssh/authorized_keys

    if [ "${PKG_MGR}" = "apt" ]; then
        SU_GROUP="sudo"
    else
        SU_GROUP="wheel"
    fi

    # Grant super user access
    if [ ${su} == "[yY]" ]; then
        usermod -aG ${SU_GROUP} $username
        echo "${username} ALL=(ALL)  NOPASSWD: ALL" >> /etc/sudoers
    fi

    # Rename the Keys
    mv /home/${username}/.ssh/authorized_keys /home/${username}/.ssh/${username}.pem
    mv /home/${username}/.ssh/authorized_keys.pub /home/${username}/.ssh/authorized_keys
    chmod 700 /home/${username}/.ssh/
    chmod 644 /home/${username}/.ssh/authorized_keys
    chown -R ${username}:${username} /home/${username}/

    # Setup Google Authendicator
    yes y | su  ${username} -c "google-authenticator  >> ~/.google-authendicator-qr-code"

    # Installing mailx
    ${PKG_MGR} install mailx -y
    
    # send email
    local qrcode=`cat /home/${username}/.google-authendicator-qr-code | grep 'google.com'`
    echo "Hey ${username},

    User account has been created for you from bastion.  
    Please find the details below: 
    BASTION IP ADDRESS: $(dig +short myip.opendns.com @resolver1.opendns.com) (IP address)
    SSH PORT: 46285
    User Name: ${username}
    Home Directory: /home/${username}
    Authentication Method: Key Based(see the attachment)
    Super User:`if [ ${su} == 'y' ]; then echo 'YES'; else echo 'NO'; fi`
    MFA Enabled: Yes
    MFA QR Code: ${qrcode}


    This is auto generated email
    Contact: cloud-team@coditas.com in case of any issue" | mailx -r "mantis@coditas.com (Bastion Admin)" -a /home/${username}/.ssh/${username}.pem -s "Bastion User Created: ${username}" ${email}

    echo "================================================"
    echo "User ${username} created successfully"
    echo "================================================"
}

function print_splash() {
    local SPLASH_OPTION
    while true
    do
        echo ""
        echo "1. Install Prerequisites"
        echo "2. Setup Bastion Server"
        echo "3. Setup Mail Server"
        echo "4. Setup 2FA"
        echo "5. Create User"
        echo "0. Quit"
        read -p "Select an option: " SPLASH_OPTION

        case "$SPLASH_OPTION" in
            1)
                local INSTALL_OPTION="y"
                read -p "This will install python-pip and aws-cli. Continue(Y/n):" INSTALL_OPTION
                if [[ "${INSTALL_OPTION}" == [nN] ]]; then
                    echo "Exited without installing prerequisites."
                else
                    install_prerequisites
                fi
                ;;
            2)
                setup_bastion
                ;;
            3)
                setup_mail_service
                ;;
            4)
                setup_2FA
                ;;
            5)
                create_bastion_user
                ;;
            0)
                exit 0
                ;;
            *)
                echo "Invalid option"
                ;;
        esac
    done 
}

print_splash
