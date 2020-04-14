# youtous/docker-mailserver

Remember to activate `consul_external_network_enabled` in order to retrieve certificates from consul.

## DNS Entries

```text

target_mailserver = target_fqdn (mailserver.youtous.me)

mailserver_domain = testing.svur.org
mailserver_hostname = mailserver
hostname = krug.svur.org # addr of the server

# mailserver config only, choose ONE DOMAIN
mail.{{ target_mailserver }}                         IN     CNAME {{ hostname }} # rainloop domain

# for each domain attached to the mailserver
autodiscover.{{ mailserver.domain }}                 IN     CNAME {{ hostname }}
autoconfig.{{ mailserver.domain }}                   IN     CNAME {{ hostname }}
{{ mailserver_hostname }}.{{ mailserver_domain }}    IN     CNAME {{ target_mailserver }} # the mailserver addr


{{ mailserver_domain }}                              IN      CNAME  {{ hostname }}
imap.{{ mailserver_domain }}                         IN      CNAME  {{ mailserver_domain }}
stmp.{{ mailserver_domain }}                         IN      CNAME  {{ mailserver_domain }}
{{ mailserver_domain }}                              IN      MX 10  {{ mailserver_hostname }}.{{ mailserver_domain }}
{{ mailserver_domain }}                              IN      TXT    "mailconf=https://autoconfig.{{ mailserver_domain }}/mail/config-v1.1.xml"
_imaps._tcp.{{ mailserver_domain }}                  IN      SRV    0 0 993 imap.{{ mailserver_domain }}
_submission._tcp.{{ mailserver_domain }}             IN      SRV    0 0 587 smtp.{{ mailserver_domain }}
_autodiscover._tcp.{{ mailserver_domain }}           IN      SRV    0 0 443 autodiscover.{{ mailserver_domain }}.
```

### Example 
```text

;; CNAME Records
testing.svur.org.			1	IN	CNAME	krug.svur.org.
mail.testing.svur.org.			1	IN	CNAME	krug.svur.org.
autoconfig.testing.svur.org.		1	IN	CNAME	krug.svur.org.
autodiscover.testing.svur.org.		1	IN	CNAME	krug.svur.org.
mailserver.testing.svur.org.		1	IN	CNAME	krug.svur.org.
imap.testing.svur.org.			1	IN	CNAME	mailserver.testing.svur.org.
stmp.testing.svur.org.			1	IN	CNAME	mailserver.testing.svur.org.


;; MX Records
testing.svur.org.			1	IN	MX	10 mailserver.testing.svur.org.

;; SRV Records
_autodiscover._tcp.testing.svur.org.	1	IN	SRV	0 0 443 autodiscover.testing.
_imaps._tcp.testing.svur.org.		1	IN	SRV	0 0 993 imap.testing.svur.org.
_submission._tcp.testing.svur.org.	1	IN	SRV	0 0 587 smtp.testing.svur.org.

;; TXT Records
testing.svur.org.			1	IN	TXT	"mailconf=https://autoconfig.testing.svur.org/mail/config-v1.1.xml"
```

### SPF
https://github.com/tomav/docker-mailserver/wiki/Configure-SPF

```text
; Check that MX is declared
domain.com. IN  MX 1 mail.domain.com.

; start with 
domain.com. IN TXT "v=spf1 mx ~all" 

; THEN when tested, update to
; v=spf1 mx -all (-all only allow mx listed)
```

### DKIM
https://github.com/tomav/docker-mailserver/wiki/Configure-DKIM

Use generated DKIM public key (mailserver_heaven_pascal_dkim_public)

```text
; OpenDKIM
mail._domainkey	IN	TXT	( "v=DKIM1; k=rsa; "
	  "p=AZERTYUIOPQSDFGHJKLMWXCVBN/AZERTYUIOPQSDFGHJKLMWXCVBN/AZERTYUIOPQSDFGHJKLMWXCVBN/AZERTYUIOPQSDFGHJKLMWXCVBN/AZERTYUIOPQSDFGHJKLMWXCVBN/AZERTYUIOPQSDFGHJKLMWXCVBN/AZERTYUIOPQSDFGHJKLMWXCVBN/AZERTYUIOPQSDFGHJKLMWXCVBN" )  ; ----- DKIM key mail for domain.tld

```

### DMARC

todo : spf, dkim, dmarc, ipv6