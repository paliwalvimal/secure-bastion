#!/bin/bash

# Identifying disto type
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO_IDS=$ID_LIKE
    VERSION=$VERSION_ID
    EXACT_ID=$ID
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

if [[ "${EXACT_ID}" == "ubuntu" ]]; then
    if [[ ${VERSION} =~ [14]{2}.* ]]; then
        MAIL_PKG="heirloom-mailx"
        MAIL_CMD="mailx"
    elif [[ ${VERSION} =~ [16]{2}.* || ${VERSION} =~ [18]{2}.* ]]; then
        MAIL_PKG="s-nail"
        MAIL_CMD="s-nail"
    fi
else
    MAIL_PKG="mailx"
    MAIL_CMD="mailx"
fi

function install_prerequisites() {
    if [ "${PKG_MGR}" == "yum" ]; then 
        if [ ${VERSION} =~ [6]{1}.* ]; then
            yum install https://dl.fedoraproject.org/pub/epel/epel-release-latest-6.noarch.rpm -y
        else
            yum install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm -y
        fi
    fi

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
    if [ "${PKG_MGR}" == "apt" ]; then export LC_ALL=C ; fi
    pip install awscli

    echo "================================================"
    echo "Installing mailx..."
    echo "================================================"
    ${PKG_MGR} install ${MAIL_PKG} -y
}

function setup_bastion() {
    echo "================================================"
    echo "Setting up bastion server"
    echo "================================================"
    
    local BASTION_LOG_BACKUP

    read -p "S3 Bucket Path for logs backup: " BASTION_LOG_BACKUP
    
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
    mv /home/bastion/.ssh/authorized_keys /home/bastion/.ssh/bastion.pem
    mv /home/bastion/.ssh/authorized_keys.pub /home/bastion/.ssh/authorized_keys
    chmod 700 /home/bastion/.ssh/
    chmod 600 /home/bastion/.ssh/authorized_keys
    chown -R bastion:bastion /home/bastion/
    echo "bastion ALL=(ALL)  NOPASSWD: ALL" >> /etc/sudoers

    # Printing private key of bastion user
    echo ""
    echo "Private key of bastion user"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    cat /home/bastion/.ssh/bastion.pem
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"

    rm -f /home/bastion/.ssh/bastion.pem

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
    cat > /usr/bin/bastion/shell <<'EOL'
if [[ -z $SSH_ORIGINAL_COMMAND ]]; then
    SUFFIX=`mktemp -u XXXXXXXXXX`
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
    echo "* * * * * $(which aws) s3 sync /var/log/bastion/ ${BASTION_LOG_BACKUP}" >> /tmp/tmpcron
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

        CA_FILE="/etc/ssl/certs/ca-certificates.crt"
    else
        CA_FILE="/etc/ssl/certs/ca-bundle.crt"
    fi
    ${PKG_MGR} remove sendmail -y
    ${PKG_MGR} install postfix -y
    ${PKG_MGR} install cyrus-sasl-plain -y

    awk '!/relayhost/' /etc/postfix/main.cf > temp && mv temp /etc/postfix/main.cf

    echo "
relayhost = [${EMAIL_SERVER_URL}]:${EMAIL_SERVER_PORT}
smtp_tls_note_starttls_offer = yes
smtp_tls_security_level = encrypt
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_sasl_security_options = noanonymous
smtp_sasl_auth_enable = yes
smtp_use_tls = yes
smtp_tls_CAfile = ${CA_FILE}" >> /etc/postfix/main.cf

    echo "[${EMAIL_SERVER_URL}]:${EMAIL_SERVER_PORT} ${SMTP_USERNAME}:${SMTP_PASSWORD}" > /etc/postfix/sasl_passwd
    postmap hash:/etc/postfix/sasl_passwd
    chown root:root /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.db
    chmod 0600 /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.db
    postfix stop
    postfix start
    # postfix reload

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
        if [ ${VERSION} =~ [6]{1}.* ]; then
            yum install https://dl.fedoraproject.org/pub/epel/epel-release-latest-6.noarch.rpm -y
        else
            yum install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm -y
        fi
        yum install google-authenticator -y
    fi

    awk '!/auth       substack     password-auth/' /etc/pam.d/sshd > temp && mv temp /etc/pam.d/sshd
    awk '!/@include common-auth/' /etc/pam.d/sshd > temp && mv temp /etc/pam.d/sshd
    echo "auth       required     pam_google_authenticator.so" >> /etc/pam.d/sshd

    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

    awk '!/ChallengeResponseAuthentication/' /etc/ssh/sshd_config > temp && mv temp /etc/ssh/sshd_config
    awk '!/PermitRootLogin/' /etc/ssh/sshd_config > temp && mv temp /etc/ssh/sshd_config
    awk '!/PubkeyAuthentication/' /etc/ssh/sshd_config > temp && mv temp /etc/ssh/sshd_config
    awk '!/PasswordAuthentication/' /etc/ssh/sshd_config > temp && mv temp /etc/ssh/sshd_config
    awk '!/UsePAM/' /etc/ssh/sshd_config > temp && mv temp /etc/ssh/sshd_config

    echo "ChallengeResponseAuthentication yes" >> /etc/ssh/sshd_config
    echo "PermitRootLogin no" >> /etc/ssh/sshd_config
    echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
    echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
    echo "UsePAM yes" >> /etc/ssh/sshd_config

    # Allowing admin user to login without 2FA
    cat >> /etc/ssh/sshd_config << EOL

Match User "bastion"
    AuthenticationMethods "publickey"
Match User "*,!bastion"
    AuthenticationMethods "publickey,keyboard-interactive"
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

    id ${username} &>/dev/null
    if [[ $? -eq 0 ]]; then
        echo "User already exists"
        return 1
    fi

    if [[ -z ${superuser} ]]; then superuser="n"; fi

    declare -l su=$superuser

    # Add user and create RSA Key Pair
    useradd -m -s /bin/bash ${username}
    mkdir -p /home/${username}/.ssh  
    ssh-keygen -t rsa -b 4096 -C "${email}" -N "" -f /home/${username}/.ssh/authorized_keys

    if [ "${PKG_MGR}" == "apt" ]; then
        SU_GROUP="sudo"
    else
        SU_GROUP="wheel"
    fi

    # Grant super user access
    if [ ${su} == 'y' ]; then
        usermod -aG ${SU_GROUP} $username
        echo "${username} ALL=(ALL)  NOPASSWD: ALL" >> /etc/sudoers
    fi

    # Rename the Keys
    mv /home/${username}/.ssh/authorized_keys /home/${username}/.ssh/${username}.pem
    mv /home/${username}/.ssh/authorized_keys.pub /home/${username}/.ssh/authorized_keys
    chmod 755 /home/${username}/.ssh/
    chmod 644 /home/${username}/.ssh/authorized_keys
    chown -R ${username}:${username} /home/${username}/

    # Setup Google Authenticator
    su ${username} -c "google-authenticator -t -d -f -r 3 -R 30 -w 3 >> ~/.google-authenticator-qr-code"
    
    # Send email
    local qrcode=`cat /home/${username}/.google-authenticator-qr-code | grep 'google.com'`
    rm -f /home/${username}/.google-authenticator-qr-code

    local BASTION_PUBLIC_IP=$(curl -s ifconfig.me)
    echo "Hey ${username},

User account has been created for you from bastion.  
Please find the details below: 
BASTION IP ADDRESS: ${BASTION_PUBLIC_IP}
User Name: ${username}
Home Directory: /home/${username}
Authentication Method: Key Based(see the attachment)
Super User: `if [ ${su} == "y" ]; then echo 'YES'; else echo 'NO'; fi`
MFA Enabled: Yes
MFA QR Code: ${qrcode}


This is an auto generated email
Contact: vimal@coditas.com in case of any issue" | ${MAIL_CMD} -r "Vimal<vimal@coditas.com>" -a /home/${username}/.ssh/${username}.pem -s "Bastion User Created: ${username}" ${email}

    rm -f /home/${username}/.ssh/${username}.pem
    
    echo "================================================"
    echo "User ${username} created successfully"
    echo "================================================"
}

function resync_2fa() {
    local username
    read -p "User Name: " username
    read -p "Email Address: " email

    id ${username} &>/dev/null
    if [[ $? -eq 1 ]]; then
        echo "User not found"
        return 1
    fi
    # Setup Google Authenticator
    su ${username} -c "google-authenticator -t -d -f -r 3 -R 30 -w 3 >> ~/.google-authenticator-qr-code"
    
    # Send email
    local qrcode=`cat /home/${username}/.google-authenticator-qr-code | grep 'google.com'`
    rm -f /home/${username}/.google-authenticator-qr-code

    echo "Hey ${username},

2FA for your account has been reset. Please scan the below QR Code to re-sync your device.
MFA QR Code: ${qrcode}


This is an auto generated email
Contact: vimal@coditas.com in case of any issue" | ${MAIL_CMD} -r "Vimal<vimal@coditas.com>" -s "Bastion User Created: ${username}" ${email}

    echo "================================================"
    echo "2FA for ${username} was reset successfully"
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
        echo "6. Re-Sync 2FA"
        echo "0. Quit"
        read -p "Select an option: " SPLASH_OPTION

        case "$SPLASH_OPTION" in
            1)
                local INSTALL_OPTION
                read -p "This will install python-pip, aws-cli and mailx. Continue(Y/n): " INSTALL_OPTION
                if [[ "${INSTALL_OPTION}" == "n" || "${INSTALL_OPTION}" == "N" ]]; then
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
            6)
                resync_2fa
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
