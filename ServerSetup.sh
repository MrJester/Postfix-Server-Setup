#!/bin/bash

if [[ $EUID -ne 0 ]]; then
	echo "Please run this script as root" 1>&2
	exit 1
fi

### Functions ###

initialize() {
	apt-get -qq update > /dev/null 2>&1
	apt-get -qq -y upgrade > /dev/null 2>&1
	apt-get install -qq -y nmap > /dev/null 2>&1
	apt-get install -qq -y git > /dev/null 2>&1
	apt-get remove -qq -y exim4 exim4-base exim4-config exim4-daemon-light > /dev/null 2>&1
	rm -r /var/log/exim4/ > /dev/null 2>&1

	update-rc.d nfs-common disable > /dev/null 2>&1
	update-rc.d rpcbind disable > /dev/null 2>&1

	echo "IPv6 Disabled"

	cat <<-EOF >> /etc/sysctl.conf
	net.ipv6.conf.all.disable_ipv6 = 1
	net.ipv6.conf.default.disable_ipv6 = 1
	net.ipv6.conf.lo.disable_ipv6 = 1
	net.ipv6.conf.eth0.disable_ipv6 = 1
	net.ipv6.conf.eth1.disable_ipv6 = 1
	net.ipv6.conf.ppp0.disable_ipv6 = 1
	net.ipv6.conf.tun0.disable_ipv6 = 1
	EOF

	sysctl -p > /dev/null 2>&1

	echo "Changing Hostname"

	read -p "Enter your hostname: " -r primary_domain

	cat <<-EOF > /etc/hosts
	127.0.1.1 $primary_domain $primary_domain
	127.0.0.1 localhost
	EOF

	cat <<-EOF > /etc/hostname
	$primary_domain
	EOF

	echo "The System will now reboot!"
	reboot
}

reset_firewall() {
	apt-get install iptables-persistent -q -y > /dev/null 2>&1

	iptables -F
	echo "Current iptables rules flushed"
	cat <<-ENDOFRULES > /etc/iptables/rules.v4
	*filter

	# Allow all loopback (lo) traffic and reject anything to localhost that does not originate from lo.
	-A INPUT -i lo -j ACCEPT
	-A INPUT ! -i lo -s 127.0.0.0/8 -j REJECT
	-A OUTPUT -o lo -j ACCEPT

	# Allow ping and ICMP error returns.
	-A INPUT -p icmp -m state --state NEW --icmp-type 8 -j ACCEPT
	-A INPUT -p icmp -m state --state ESTABLISHED,RELATED -j ACCEPT
	-A OUTPUT -p icmp -j ACCEPT

	# Allow SSH.
	-A INPUT -i  eth0 -p tcp -m state --state NEW,ESTABLISHED --dport 22 -j ACCEPT
	-A OUTPUT -o eth0 -p tcp -m state --state NEW,ESTABLISHED --sport 22 -j ACCEPT

	# Allow DNS resolution and limited HTTP/S on eth0.
	# Necessary for updating the server and keeping time.
	-A INPUT  -p udp -m state --state NEW,ESTABLISHED --sport 53 -j ACCEPT
	-A OUTPUT  -p udp -m state --state NEW,ESTABLISHED --dport 53 -j ACCEPT
	-A INPUT  -p tcp -m state --state ESTABLISHED --sport 80 -j ACCEPT
	-A INPUT  -p tcp -m state --state ESTABLISHED --sport 443 -j ACCEPT
	-A OUTPUT  -p tcp -m state --state NEW,ESTABLISHED --dport 80 -j ACCEPT
	-A OUTPUT  -p tcp -m state --state NEW,ESTABLISHED --dport 443 -j ACCEPT

	# Allow Mail Server Traffic outbound
	-A OUTPUT  -p tcp -m state --state NEW,ESTABLISHED --dport 143 -j ACCEPT
	-A OUTPUT  -p tcp -m state --state NEW,ESTABLISHED --dport 587 -j ACCEPT
	-A OUTPUT  -p tcp -m state --state NEW,ESTABLISHED --dport 993 -j ACCEPT
	-A OUTPUT  -p tcp -m state --state NEW,ESTABLISHED --dport 25 -j ACCEPT

	# Allow Mail Server Traffic inbound
	-A INPUT  -p tcp -m state --state NEW,ESTABLISHED --sport 143 -j ACCEPT
	-A INPUT  -p tcp -m state --state NEW,ESTABLISHED --sport 587 -j ACCEPT
	-A INPUT  -p tcp -m state --state NEW,ESTABLISHED --sport 993 -j ACCEPT
	-A INPUT  -p tcp -m state --state NEW,ESTABLISHED --sport 25 -j ACCEPT

	COMMIT
	ENDOFRULES

	iptables -P INPUT DROP
	iptables -P FORWARD DROP
	iptables -P OUTPUT DROP

	cat <<-ENDOFRULES > /etc/iptables/rules.v6
	*filter

	-A INPUT -j DROP
	-A FORWARD -j DROP
	-A OUTPUT -j DROP

	COMMIT
	ENDOFRULES

	echo "Loading new firewall rules"
	iptables-restore /etc/iptables/rules.v4
	ip6tables-restore /etc/iptables/rules.v6
}

add_firewall_port(){
	read -p "Enter the port you would like opened: " -r port
	iptables -A INPUT -p tcp --dport ${port} -j ACCEPT
	iptables -A OUTPUT -p tcp --sport ${port} -j ACCEPT
	iptables-save
}


install_ssl_Cert() {
	git clone https://github.com/certbot/certbot.git /opt/letsencrypt > /dev/null 2>&1

	cd /opt/letsencrypt
	read -p "Enter your server's domain: " -r domain
	./certbot-auto certonly --standalone -d "${domain}" -n --register-unsafely-without-email --agree-tos
}

install_postfix_dovecot() {
	echo "Installing Dependicies"
	apt-get install -qq -y dovecot-imapd dovecot-lmtpd
	apt-get install -qq -y postfix postgrey postfix-policyd-spf-python
	apt-get install -qq -y opendkim opendkim-tools
	apt-get install -qq -y opendmarc
	apt-get install -qq -y mailutils

	read -p "Enter your mail server's domain: " -r primary_domain
	read -p "Enter IP's to allow Relay (if none just hit enter): " -r relay_ip
	echo "Configuring Postfix"

	cat <<-EOF > /etc/postfix/main.cf
	smtpd_banner = \$myhostname ESMTP \$mail_name (Debian/GNU)
	biff = no
	append_dot_mydomain = no
	readme_directory = no
	smtpd_tls_cert_file=/etc/letsencrypt/live/${primary_domain}/fullchain.pem
	smtpd_tls_key_file=/etc/letsencrypt/live/${primary_domain}/privkey.pem
	smtpd_tls_security_level = may
	smtp_tls_security_level = encrypt
	smtpd_tls_session_cache_database = btree:\${data_directory}/smtpd_scache
	smtp_tls_session_cache_database = btree:\${data_directory}/smtp_scache
	smtpd_relay_restrictions = permit_mynetworks permit_sasl_authenticated defer_unauth_destination
	myhostname = ${primary_domain}
	alias_maps = hash:/etc/aliases
	alias_database = hash:/etc/aliases
	myorigin = /etc/mailname
	mydestination = ${primary_domain}, localhost.com, , localhost
	relayhost =
	mynetworks = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128 ${relay_ip}
	mailbox_command = procmail -a "\$EXTENSION"
	mailbox_size_limit = 0
	recipient_delimiter = +
	inet_interfaces = all
	inet_protocols = ipv4
	milter_default_action = accept
	milter_protocol = 6
	smtpd_milters = inet:12301,inet:localhost:54321
	non_smtpd_milters = inet:12301,inet:localhost:54321
	EOF

	cat <<-EOF >> /etc/postfix/master.cf
	submission inet n       -       -       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_wrappermode=no
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_recipient_restrictions=permit_mynetworks,permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
  -o smtpd_sasl_type=dovecot
  -o smtpd_sasl_path=private/auth
	EOF

	echo "Configuring Opendkim"

	mkdir -p "/etc/opendkim/keys/${primary_domain}"
	cp /etc/opendkim.conf /etc/opendkim.conf.orig

	cat <<-EOF > /etc/opendkim.conf
	domain								*
	AutoRestart						Yes
	AutoRestartRate				10/1h
	Umask									0002
	Syslog								Yes
	SyslogSuccess					Yes
	LogWhy								Yes
	Canonicalization			relaxed/simple
	ExternalIgnoreList		refile:/etc/opendkim/TrustedHosts
	InternalHosts					refile:/etc/opendkim/TrustedHosts
	KeyFile								/etc/opendkim/keys/${primary_domain}/mail.private
	Selector							mail
	Mode									sv
	PidFile								/var/run/opendkim/opendkim.pid
	SignatureAlgorithm		rsa-sha256
	UserID								opendkim:opendkim
	Socket								inet:12301@localhost
	EOF

	cat <<-EOF > /etc/opendkim/TrustedHosts
	127.0.0.1
	localhost
	${primary_domain}
	${relay_ip}
	EOF

	cd "/etc/opendkim/keys/${primary_domain}" || exit
	opendkim-genkey -s mail -d "${primary_domain}"
	echo 'SOCKET="inet:12301"' >> /etc/default/opendkim
	chown -R opendkim:opendkim /etc/opendkim

	echo "Configuring opendmarc"

	cat <<-EOF > /etc/opendmarc.conf
	AuthservID ${primary_domain}
	PidFile /var/run/opendmarc.pid
	RejectFailures false
	Syslog true
	TrustedAuthservIDs ${primary_domain}
	Socket  inet:54321@localhost
	UMask 0002
	UserID opendmarc:opendmarc
	IgnoreHosts /etc/opendmarc/ignore.hosts
	HistoryFile /var/run/opendmarc/opendmarc.dat
	EOF

	mkdir "/etc/opendmarc/"
	echo "localhost" > /etc/opendmarc/ignore.hosts
	chown -R opendmarc:opendmarc /etc/opendmarc

	echo 'SOCKET="inet:54321"' >> /etc/default/opendmarc

	echo "Configuring Dovecot"

	cat <<-EOF > /etc/dovecot/dovecot.conf
	disable_plaintext_auth = no
	mail_privileged_group = mail
	mail_location = mbox:~/mail:INBOX=/var/mail/%u

	userdb {
	  driver = passwd
	}

	passdb {
	  args = %s
	  driver = pam
	}

	protocols = " imap"

	protocol imap {
	  mail_plugins = " autocreate"
	}

	plugin {
	  autocreate = Trash
	  autocreate2 = Sent
	  autosubscribe = Trash
	  autosubscribe2 = Sent
	}

	service imap-login {
	  inet_listener imap {
	    port = 0
	  }
	  inet_listener imaps {
	    port = 993
	  }
	}

	service auth {
	  unix_listener /var/spool/postfix/private/auth {
	    group = postfix
	    mode = 0660
	    user = postfix
	  }
	}

	ssl=required
	ssl_cert = </etc/letsencrypt/live/${primary_domain}/fullchain.pem
	ssl_key = </etc/letsencrypt/live/${primary_domain}/privkey.pem
	EOF

	echo "Restarting Services"
	service postfix restart
	service opendkim restart
	service opendmarc restart
	service dovecot restart

	echo "Checking Service Status"
	service postfix status
	service opendkim status
	service opendmarc status
	service dovecot status
}

function add_alias(){
	read -p "What user would you like to assign to recieve email for Root: " -r user_name
	echo "${user_name}: root" >> /etc/aliases
	echo "Root email assigned to ${user_name}"

	read -p "What email address do you want to assign: " -r email_address
	read -p "What user do you want to assign to that email address: " -r user
	echo "${email_address}: ${user}" >> /etc/aliases
	newaliases
	echo "${email_address} assigned to ${user}"
}

function get_dns_entries(){
	extip=$(ifconfig|grep 'Link encap\|inet '|awk '!/Loopback|:127./'|tr -s ' '|grep 'inet'|tr ':' ' '|cut -d" " -f4)
	domain=$(ls /etc/opendkim/keys/ | head -1)
	fields=$(echo "${domain}" | tr '.' '\n' | wc -l)
	dkimrecord=$(cut -d '"' -f 2 "/etc/opendkim/keys/${domain}/mail.txt" | tr -d "[:space:]")

	if [[ $fields -eq 2 ]]; then
		cat <<-EOF > dnsentries.txt
		DNS Entries for ${domain}:

		====================================================================
		Namecheap - Enter under Advanced DNS

		Record Type: A
		Host: @
		Value: ${extip}
		TTL: 5 min

		Record Type: TXT
		Host: @
		Value: v=spf1 +mx +a -all
		TTL: 5 min

		Record Type: TXT
		Host: mail._domainkey
		Value: ${dkimrecord}
		TTL: 5 min

		Record Type: TXT
		Host: ._dmarc
		Value: v=DMARC1; p=reject
		TTL: 5 min

		Change Mail Settings to Custom MX and Add New Record
		Record Type: MX
		Host: @
		Value: ${domain}
		Priority: 10
		TTL: 5 min
		EOF
		cat dnsentries.txt
	else
		prefix=$(echo "${domain}" | rev | cut -d '.' -f 3- | rev)
		cat <<-EOF > dnsentries.txt
		DNS Entries for ${domain}:

		====================================================================
		Namecheap - Enter under Advanced DNS

		Record Type: A
		Host: ${prefix}
		Value: ${extip}
		TTL: 5 min

		Record Type: TXT
		Host: ${prefix}
		Value: v=spf1 +mx +a -all
		TTL: 5 min

		Record Type: TXT
		Host: mail._domainkey.${prefix}
		Value: ${dkimrecord}
		TTL: 5 min

		Record Type: TXT
		Host: ._dmarc
		Value: v=DMARC1; p=reject
		TTL: 5 min

		Change Mail Settings to Custom MX and Add New Record
		Record Type: MX
		Host: ${prefix}
		Value: ${domain}
		Priority: 10
		TTL: 5 min
		EOF
		cat dnsentries.txt
	fi

}

setupSSH(){
	apt-get -qq -y install sudo > /dev/null 2>&1
	apt-get -qq -y install fail2ban > /dev/null 2>&1

	echo "Create a User to ssh into this system securely"

	read -p "Enter your user name: " -r user_name

	adduser $user_name

	usermod -aG sudo $user_name

	cat <<-EOF > /etc/ssh/sshd_config
	Port 22
	Protocol 2
	HostKey /etc/ssh/ssh_host_rsa_key
	HostKey /etc/ssh/ssh_host_dsa_key
	HostKey /etc/ssh/ssh_host_ecdsa_key
	#Privilege Separation is turned on for security
	UsePrivilegeSeparation yes
	KeyRegenerationInterval 3600
	ServerKeyBits 1024
	SyslogFacility AUTH
	LogLevel INFO
	LoginGraceTime 120
	PermitRootLogin no
	StrictModes yes
	RSAAuthentication yes
	PubkeyAuthentication yes
	IgnoreRhosts yes
	RhostsRSAAuthentication no
	HostbasedAuthentication no
	PermitEmptyPasswords no
	ChallengeResponseAuthentication no
	PasswordAuthentication yes
	X11Forwarding yes
	X11DisplayOffset 10
	PrintMotd no
	PrintLastLog yes
	TCPKeepAlive yes
	Banner no
	AcceptEnv LANG LC_*
	Subsystem sftp /usr/lib/openssh/sftp-server
	UsePAM yes
	EOF

	echo "AllowUsers ${user_name}" > /etc/ssh/sshd_config

	cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local

	cd /home/$user_name
	runuser -l $user_name -c "mkdir '.ssh'"
	runuser -l $user_name -c "chmod 700 ~/.ssh"

	service ssh restart

}

PS3="Server Setup Script - Pick an option: "
options=("Setup SSH" "Debian Prep" "Install SSL", "Install Mail Server", "Add Aliases", "Get DNS Entries")
select opt in "${options[@]}" "Quit"; do

    case "$REPLY" in

    #Prep
    1) setupSSH;;

		2) initialize;;

		3) install_ssl_Cert;;

		4) install_postfix_dovecot;;

		5) add_alias;;

		6) get_dns_entries;;

    $(( ${#options[@]}+1 )) ) echo "Goodbye!"; break;;
    *) echo "Invalid option. Try another one.";continue;;

    esac

done
