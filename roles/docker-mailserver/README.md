# youtous/docker-mailserver

## How to?

1. Add the *mailserver* host in `hosts/mailserver.yml` 
2. Remember to activate `consul_external_network_enabled` in `group_vars/{{ primary_manager }}.yml` in order to retrieve certificates from consul.
3. Define `mailserver_hostname` and `mailserver_domain` in the previous file (see below example)
4. Create a mariadb account and db for `rainloop` then define : `rainloop_mysql_database`, `rainloop_mysql_user` and `rainloop_mysql_password` 
5. Register the maildomain and associated account, see `mailserver_domains` in `defaults/main.yml`
6. Register domains in DNS (see below) : dkim, spf and check DMARC section
7. Run ansible playbook (in order) *database creation*, *traefik update* then *mailserver*.
8. Test DKIM, SPF and other mailserver conf, then you can activate DMARC ; check it with https://en.internet.nl/

// todo : set recommanded mailserver_allowed_networks

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
testing.svur.org. IN  MX 10 mailserver.testing.svur.org.

; start with 
testing.svur.org. IN TXT "v=spf1 mx ~all" 

; THEN when tested, update to
; v=spf1 mx -all (-all only allow mx listed)
```

### DKIM
https://github.com/tomav/docker-mailserver/wiki/Configure-DKIM

Use generated DKIM public key (mailserver_heaven_pascal_dkim_public)

```text
; OpenDKIM
mail._domainkey.testing.svur.org.	IN	TXT	( "v=DKIM1; k=rsa; "
	  "p=AZERTYUIOPQSDFGHJKLMWXCVBN/AZERTYUIOPQSDFGHJKLMWXCVBN/AZERTYUIOPQSDFGHJKLMWXCVBN/AZERTYUIOPQSDFGHJKLMWXCVBN/AZERTYUIOPQSDFGHJKLMWXCVBN/AZERTYUIOPQSDFGHJKLMWXCVBN/AZERTYUIOPQSDFGHJKLMWXCVBN/AZERTYUIOPQSDFGHJKLMWXCVBN" )  ; ----- DKIM key mail for domain.tld

```

```text
# cloudflare format:
v=DKIM1; k=rsa; 
p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEArRlf7iVBAlgA5gL1QpD525s5IIwrg3hSTtuC9exziZAV3tNSi4QnuZoIPsAepyJikSBElkRwLxoG5a1XBzrg0p7K2bE0DHNXBPccV/Xg2/PDXLHicnMvItNOCn3TXI0cYLZh7bGeHL4pDggxgQIFmgx4RF1fxhHA+Sh+Cz34mXsGWZoAWPBb3xZnB7+PJNQ8ZIFs622DNWVk00EGY9ZnbPn5fiEU8IFRHsCAuKALgvkyxlqpAQ+NNEgAfFaBYZrbJDPLgBILvP++m+FqITZiJVcQ7ayl1CL8+sMv69uAsxfjNRRj26UE+nxPU9DOUWAn72M+r42J+QPird+DXKRFZQIDAQAB
```
### DMARC
https://serverfault.com/posts/851254/revisions


Because DMARC is herited from the parent domain, in case of subdomains: 
You can add sp=none to the parent domain's DMARC reject policy so that none of your sub domains inherit the reject policy until you are ready to implement. 
```text
_dmarc.svur.org.  IN   TXT v=DMARC1; p=reject; sp=none; fo=1; rua=mailto:dmarc_agg@auth.returnpath.net; ruf=mailto:dmarc_afrf@auth.returnpath.net
```

**/!\ THEN ONLY WHEN DKIM AND SPF ARE TESTED AND PASS TESTS**
 
```text
#  A DMARC policy is inherited by all subdomains "unless subdomain policy is explicitly described using the sp tag"
_dmarc.svur.org.  IN   TXT   "v=DMARC1; p=reject; aspf=s; adkim=s;"
```

todo : dmarc more detailed policy, ipv6