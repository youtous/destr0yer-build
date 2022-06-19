# youtous/docker-mailserver

# References for crypto
https://bettercrypto.org/#_tls_usage_in_mail_server_protocols

## How to?

1. Add the *mailserver* host in `hosts/mailserver.yml` and add the docker network in `mailserver_allowed_ips` if you want access smtps server from others host containers.
2. Remember to activate `consul_external_network_enabled` in `group_vars/{{ primary_manager }}.yml` in order to retrieve certificates from consul.
3. Define `mailserver_hostname` and `mailserver_domain` in the previous file (see below example)
4. Create a mariadb account and db for `rainloop` then define : `rainloop_mysql_database`, `rainloop_mysql_user` and `rainloop_mysql_password`
5. Register the maildomain and associated account, see `mailserver_domains` in `defaults/main.yml`
6. Register domains in DNS (see below) : dkim, spf and check DMARC section
7. Eventually, redefine `rainloop_domain` and `mailserver_default_mailbox_limit_mb`
8. Run ansible playbook (in order) *database creation*, *traefik update* then *mailserver*.
9. Test DKIM, SPF and other mailserver conf, then you can activate DMARC ; check it with https://en.internet.nl/
10. _(rainloop enabled)_ see Rainloop section
11. Wait a week for checking then set `DMARC` and `MTA-STS` policies to enforce

// todo ipv6 policy

_A complete reference to keep this guide updated: https://mecsa.jrc.ec.europa.eu/en/postfix_<br/>
_In case of doubt about a paramater, use https://ssl-config.mozilla.org/._<br/>
_Reference for testing https://github.com/drwetter/testssl.sh._<br/>
_**mailserver_allowed_networks** should be left empty, otherwise an open relay could be enabled with others containers_<br/>
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


{{ mailserver_domain }}                              IN      A  {{ hostname_ipv4 }} # /!\ NEVER USE CNAME on MX domains
{{ mailserver_domain }}                              IN      AAAA  {{ hostname_ipv6 }} # (eventually)
{{ mailserver_domain }}                              IN      MX 10  {{ mailserver_hostname }}.{{ mailserver_domain }}
{{ mailserver_domain }}                              IN      TXT    "mailconf=https://autoconfig.{{ mailserver_domain }}/mail/config-v1.1.xml"
_imaps._tcp.{{ mailserver_domain }}                  IN      SRV    0 0 993 {{ mailserver_hostname }}.{{ mailserver_domain }}
_submission._tcp.{{ mailserver_domain }}             IN      SRV    0 0 465 {{ mailserver_hostname }}.{{ mailserver_domain }}
_autodiscover._tcp.{{ mailserver_domain }}           IN      SRV    0 0 443 autodiscover.{{ mailserver_domain }}.
```

### Example
```text

;; CNAME Records
testing.svur.org.			1	IN	CNAME	krug.svur.org.
mail.testing.svur.org.			1	IN	CNAME	krug.svur.org.
autoconfig.testing.svur.org.		1	IN	CNAME	krug.svur.org.
autodiscover.testing.svur.org.		1	IN	CNAME	krug.svur.org.
mailserver.testing.svur.org.		1	IN	A	192.168.1.202

;; MX Records
testing.svur.org.			1	IN	MX	10 mailserver.testing.svur.org.

;; SRV Records
_autodiscover._tcp.testing.svur.org.	1	IN	SRV	0 0 443 autodiscover.testing.
_imaps._tcp.testing.svur.org.		1	IN	SRV	0 0 993 mailserver.testing.svur.org.
_submission._tcp.testing.svur.org.	1	IN	SRV	0 0 465 mailserver.testing.svur.org.

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
(better) https://github.com/internetstandards/toolbox-wiki
https://github.com/tomav/docker-mailserver/wiki/Configure-DKIM

Use generated DKIM public key (mailserver_heaven_pascal_dkim_public)

```text
; OpenDKIM
mail._domainkey.testing.svur.org.	IN	TXT	"v=DKIM1; k=rsa; "
	  "p=AZERTYUIOPQSDFGHJKLMWXCVBN/AZERTYUIOPQSDFGHJKLMWXCVBN/AZERTYUIOPQSDFGHJKLMWXCVBN/AZERTYUIOPQSDFGHJKLMWXCVBN/AZERTYUIOPQSDFGHJKLMWXCVBN/AZERTYUIOPQSDFGHJKLMWXCVBN/AZERTYUIOPQSDFGHJKLMWXCVBN/AZERTYUIOPQSDFGHJKLMWXCVBN"

_adsp._domainkey.testing.svur.org. IN TXT "dkim=all"
```

```text
# cloudflare format:
v=DKIM1; k=rsa;
p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEArRlf7iVBAlgA5gL1QpD525s5IIwrg3hSTtuC9exziZAV3tNSi4QnuZoIPsAepyJikSBElkRwLxoG5a1XBzrg0p7K2bE0DHNXBPccV/Xg2/PDXLHicnMvItNOCn3TXI0cYLZh7bGeHL4pDggxgQIFmgx4RF1fxhHA+Sh+Cz34mXsGWZoAWPBb3xZnB7+PJNQ8ZIFs622DNWVk00EGY9ZnbPn5fiEU8IFRHsCAuKALgvkyxlqpAQ+NNEgAfFaBYZrbJDPLgBILvP++m+FqITZiJVcQ7ayl1CL8+sMv69uAsxfjNRRj26UE+nxPU9DOUWAn72M+r42J+QPird+DXKRFZQIDAQAB
```

### DMARC
https://serverfault.com/posts/851254/revisions
https://github.com/internetstandards/toolbox-wiki/blob/master/DMARC-how-to.md

Because DMARC is herited from the parent domain, in case of subdomains:
You can add sp=none to the parent domain's DMARC reject policy so that none of your sub domains inherit the reject policy until you are ready to implement.

Nevertheless, it's a good choice to define a dmarc policy for each domain or subdomain.

**/!\ THEN ACTIVATE DMARC ONLY WHEN DKIM AND SPF ARE TESTED AND PASS TESTS**

```text
_dmarc.testing.svur.org. IN TXT v=DMARC1; p=quarantine; rf=afrf; sp=reject; fo=1; rua=mailto:postmaster+dmarcreports@svur.org;  ruf=mailto:postmaster+dmarcfails@svur.org; adkim=s; aspf=s; pct=100
```

**After a week of testing, policy can be enforced:**

```text
_dmarc.testing.svur.org. IN TXT v=DMARC1; p=reject; rf=afrf; sp=reject; fo=1; rua=mailto:postmaster+dmarcreports@svur.org;  ruf=mailto:postmaster+dmarcfails@svur.org; adkim=s; aspf=s; pct=100
```

### MTA ?
https://www.digitalocean.com/community/tutorials/how-to-configure-mta-sts-and-tls-reporting-for-your-domain-using-apache-on-ubuntu-18-04

Add the following DNS records:
```text
mta-sts.testing.svur.org.		1	IN	CNAME	mailserver.testing.svur.org.

_mta-sts.testing.svur.org. IN TXT "v=STSv1; id=date +%s" # <---- set it to "date +%s" => increment the id at every change (use the date)
_smtp._tls.testing.svur.org. IN TXT "v=TLSRPTv1; rua=mailto:postmaster+tls-reports@testing.svur.org"
```

MTA requires to list mx domains. Use `mta_sts` for mta configuration.
Start with the following parameters:

```yaml
max_age: 86401
mode: testing
mx_entries:
    - mailserver.testing.svur.org # list each MX DNS entry
```

Then test with https://www.mailhardener.com/tools/mta-sts-validator.

Wait a month upon configuration has been validated (read reports), then edit the `mta_sts`:
**/!\\** Don't forget to increment `_mta-sts.testing.svur.org.` with the new date using `date +%s`.
```yaml
max_age: 604800 # one week
mode: enforce
mx_entries:
    - mailserver.testing.svur.org # list each MX DNS entry
```

### Rainloop
Go to https://rainloop/?admin and configure the db and the mailserver :

 - mysql : `mysql_server` for hostname, and the db-user/db-name of you choice.
 - sieve, smtp : `mailserver` STARTTLS:587 _(465 does not work when same host)_
 - imap : `mailserver` SSL/TLS:993

Disable certificate verification (it runs inside the stack only).

### Tests

For sending emails, use `swaks`, in a debian container.
For instance: `swaks -f noreply@svur.org -t contact@svur.org --server mailserver.svur.org:465 -tlsc -a LOGIN`

free:
- https://github.com/drwetter/testssl.sh
- https://en.internet.nl/
- https://www.mail-tester.com
- https://mecsa.jrc.ec.europa.eu
- https://www.mailhardener.com/tools/mta-sts-validator
- https://aykevl.nl/apps/mta-sts/

commercials:
- https://www.hardenize.com/
- https://www.immuniweb.com/ssl/
