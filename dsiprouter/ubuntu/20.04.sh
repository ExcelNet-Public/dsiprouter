#!/usr/bin/env bash

# Debug this script if in debug mode
(( $DEBUG == 1 )) && set -x

# Import dsip_lib utility / shared functions if not already
if [[ "$DSIP_LIB_IMPORTED" != "1" ]]; then
    . ${DSIP_PROJECT_DIR}/dsiprouter/dsip_lib.sh
fi

function install {
    # Install dependencies for dSIPRouter
    apt-get install -y build-essential curl python3 python3-pip python-dev libmariadbclient-dev libpq-dev \
        firewalld logrotate rsyslog perl libev-dev uuid-runtime libpq-dev libmariadb-dev nginx

    # reset python cmd in case it was just installed
    setPythonCmd

    # create dsiprouter and nginx user and group
    # sometimes locks aren't properly removed (this seems to happen often on VM's)
    rm -f /etc/passwd.lock /etc/shadow.lock /etc/group.lock /etc/gshadow.lock
    useradd --system --user-group --shell /bin/false --comment "nginx HTTP Service Provider" nginx

    # make sure the nginx user has access to dsiprouter directories
    usermod -a -G dsiprouter nginx
    # make dsiprouter user has access to kamailio files
    usermod -a -G kamailio dsiprouter

    # setup runtime directorys for dsiprouter and nginx
    mkdir -p /var/run/dsiprouter /var/run/nginx
    chown dsiprouter:dsiprouter /var/run/dsiprouter
    chown nginx:nginx /var/run/nginx

    # Enable and start firewalld if not already running
    systemctl enable firewalld
    systemctl start firewalld

    # Setup Firewall for DSIP_PORT
    firewall-cmd --zone=public --add-port=${DSIP_PORT}/tcp --permanent
    firewall-cmd --reload

    cat ${DSIP_PROJECT_DIR}/gui/requirements.txt | xargs -n 1 ${PYTHON_CMD} -m pip install
    if [ $? -eq 1 ]; then
        printerr "dSIPRouter install failed: Couldn't install required libraries"
        exit 1
    fi

    # Configure nginx
    # determine available TLS protocols (try using highest available)
    OPENSSL_VER=$(openssl version 2>/dev/null | awk '{print $2}' | perl -pe 's%([0-9])\.([0-9]).([0-9]).*%\1\2\3%')
    if (( ${OPENSSL_VER} < 101 )); then
        TLS_PROTOCOLS="TLSv1"
    elif (( ${OPENSSL_VER} < 111 )); then
        TLS_PROTOCOLS="TLSv1.1 TLSv1.2"
    else
        TLS_PROTOCOLS="TLSv1.2 TLSv1.3"
    fi
    mkdir -p /etc/nginx/sites-enabled /etc/nginx/sites-available /etc/nginx/nginx.conf.d/
    # remove the defaults
    rm -f /etc/nginx/sites-enabled/* /etc/nginx/sites-available/* /etc/nginx/nginx.conf.d/*
    # setup our own nginx configs
    perl -e "\$tls_protocols='${TLS_PROTOCOLS}';" \
        -pe 's%TLS_PROTOCOLS%${tls_protocols}%g;' \
        ${DSIP_PROJECT_DIR}/resources/nginx/nginx.conf >/etc/nginx/nginx.conf
    perl -e "\$dsip_port='${DSIP_PORT}'; \$dsip_unix_sock='${DSIP_UNIX_SOCK}'; \$dsip_ssl_cert='${DSIP_SSL_CERT}'; \$dsip_ssl_key='${DSIP_SSL_KEY}';" \
        -pe 's%DSIP_UNIX_SOCK%${dsip_unix_sock}%g; s%DSIP_PORT%${dsip_port}%g; s%DSIP_SSL_CERT%${dsip_ssl_cert}%g; s%DSIP_SSL_KEY%${dsip_ssl_key}%g;' \
        ${DSIP_PROJECT_DIR}/resources/nginx/dsiprouter.conf >/etc/nginx/sites-available/dsiprouter.conf
    ln -sf /etc/nginx/sites-available/dsiprouter.conf /etc/nginx/sites-enabled/dsiprouter.conf
    systemctl enable nginx
    systemctl restart nginx

    # Configure rsyslog defaults
    if ! grep -q 'dSIPRouter rsyslog.conf' /etc/rsyslog.conf 2>/dev/null; then
        cp -f ${DSIP_PROJECT_DIR}/resources/syslog/rsyslog.conf /etc/rsyslog.conf
    fi

    # Setup dSIPRouter Logging
    cp -f ${DSIP_PROJECT_DIR}/resources/syslog/dsiprouter.conf /etc/rsyslog.d/dsiprouter.conf
    touch /var/log/dsiprouter.log
    systemctl restart rsyslog

    # Setup logrotate
    cp -f ${DSIP_PROJECT_DIR}/resources/logrotate/dsiprouter /etc/logrotate.d/dsiprouter

    # Install dSIPRouter as a service
    perl -p \
        -e "s|'DSIP_RUN_DIR\=.*'|'DSIP_RUN_DIR=$DSIP_RUN_DIR'|;" \
        -e "s|'DSIP_PROJECT_DIR\=.*'|'DSIP_PROJECT_DIR=$DSIP_PROJECT_DIR'|;" \
        -e "s|'DSIP_SYSTEM_CONFIG_DIR\=.*'|'DSIP_SYSTEM_CONFIG_DIR=$DSIP_SYSTEM_CONFIG_DIR'|;" \
        -e "s|ExecStart\=.*|ExecStart=${PYTHON_CMD} "'\${DSIP_PROJECT_DIR}'"/gui/dsiprouter.py|;" \
        ${DSIP_PROJECT_DIR}/dsiprouter/dsiprouter.service > /etc/systemd/system/dsiprouter.service
    chmod 644 /etc/systemd/system/dsiprouter.service
    systemctl daemon-reload
    systemctl enable dsiprouter
}

function uninstall {
    # Uninstall dependencies for dSIPRouter
    PIP_CMD="pip"

    cat ${DSIP_PROJECT_DIR}/gui/requirements.txt | xargs -n 1 $PYTHON_CMD -m ${PIP_CMD} uninstall --yes
    if [ $? -eq 1 ]; then
        printerr "dSIPRouter uninstall failed or the libraries are already uninstalled"
        exit 1
    else
        printdbg "DSIPRouter uninstall was successful"
        exit 0
    fi

    apt-get remove -y build-essential curl python3 python3-pip python-dev libmariadbclient-dev libmariadb-client-lgpl-dev libpq-dev firewalld

    # Remove Firewall for DSIP_PORT
    firewall-cmd --zone=public --remove-port=${DSIP_PORT}/tcp --permanent
    firewall-cmd --reload

    # Remove dSIPRouter Logging
    rm -f /etc/rsyslog.d/dsiprouter.conf

    # Remove logrotate settings
    rm -f /etc/logrotate.d/dsiprouter

    # Remove dSIProuter as a service
    systemctl disable dsiprouter.service
    rm -f /etc/systemd/system/dsiprouter.service
    systemctl daemon-reload
}

case "$1" in
    uninstall|remove)
        uninstall
        ;;
    install)
        install
        ;;
    *)
        printerr "usage $0 [install | uninstall]"
        ;;
esac
