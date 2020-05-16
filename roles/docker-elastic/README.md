# youtous/docker-elastic

Provide an elastic stack using docker.
You can use it as a complete stack or as a forwarder (`elastic_use_as_forwarder: true`).

Remember to set a `elastic_cluster_name` for identifying the cluster data.

### Use it with a VPN
Use a VPN for `receiver <<----[VPN]--- forwarder`

### Alerts email

1. Add the webhook:

```
POST _opendistro/_alerting/destinations
{
  "name": "smtp",
  "type": "custom_webhook",
  "custom_webhook": {
    "url": "http://alerts-smtp-forwarder:8080/email"
  }
}
``` 

2. Generate a monitor and alert triggers.

Format of alert smtp:
```
to: ['monitoring@youtous.me']
subject: 'Optional subject param'
---
Monitor {{ctx.monitor.name}} just entered alert status. Please investigate the issue.
- Trigger: {{ctx.trigger.name}}
- Severity: {{ctx.trigger.severity}}
- Period start: {{ctx.periodStart}}
- Period end: {{ctx.periodEnd}}
```

### 

### SSL Monitoring

Add all ports to monitoring
```bash
docker run --rm -ti --network=host drwetter/testssl.sh:3.1dev localhost:5000
```

### Heartbeat monitor

Check url availability using `elastic_heartbeat_urls: [""https://google.com"]`