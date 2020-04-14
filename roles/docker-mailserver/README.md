# youtous/docker-mailserver

Remember to activate `consul_external_network_enabled` in order to retrieve certificates from consul.

## DNS Entries

```text

# mailserver config
mail.{{ hostname }}                                      CNAME {{ hostname }} # rainloop domain
{{ mailserver_hostname }}.{{ mailserver_domain }}        CNAME {{ hostname }} # required for traefik

# for each domain attached to the mailserver
autodiscover.{{ mailserver.domain }}                     CNAME {{ hostname }}
autoconfig.{{ mailserver.domain }}                       CNAME {{ hostname }}


```