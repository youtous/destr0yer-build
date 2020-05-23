# youtous/docker-elastic

Provide an elastic stack using docker.
You can use it as a complete stack or as a forwarder (`elastic_use_as_forwarder: true`).

Remember to set a `elastic_cluster_name` for identifying the cluster data.

### Use it with a VPN
Use a VPN for `receiver <<----[VPN]--- forwarder`

### Define index-patterns

_delete can be done in settings > saved objects > filter by pattern_
In elastic console, add: 
```http request
# delete existing indices
DELETE /docker-*

# ensure no mapping exists
GET /docker-*/_mapping/field/source.geo

# define new mapping
PUT _template/docker-
{
  "index_patterns": ["docker-*"],
  "mappings": {
    "properties": {
      "host.name": {
        "type": "keyword"
      },
      "host.hostname": {
        "type": "keyword"
      },
      "cluster.name": {
        "type": "keyword"
      },
      "source.geo": {
          "dynamic": true,
          "properties" : {
            "ip": { "type": "ip" },
            "location" : { "type" : "geo_point" },
            "latitude" : { "type" : "half_float" },
            "longitude" : { "type" : "half_float" }
          }
      },
      "fail2ban_bgp": {
          "dynamic": true,
          "properties" : {
            "ip": { "type": "ip" },
            "location" : { "type" : "geo_point" },
            "latitude" : { "type" : "half_float" },
            "longitude" : { "type" : "half_float" }
          }
      },
      "geoip": {
         "dynamic": true,
          "properties" : {
            "ip": { "type": "ip" },
            "location" : { "type" : "geo_point" },
            "latitude" : { "type" : "half_float" },
            "longitude" : { "type" : "half_float" }
          }
        }
      }
    }
  }
}
```
2. Create the pattern using the interface
-  `docker-*`, `id=f7f65d60-9946-11ea-ad57-f9074afbf2d7`
-  `journalbeat-*`, `id=f152ec60-9948-11ea-ad57-f9074afbf2d7`
-  `metricbeat-*`, `id=metricbeat-*`
-  `heartbeat-*`, `id=fca68d10-9948-11ea-ad57-f9074afbf2d7`
-  `filebeat-*`, `id=filebeat-*`

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

###  Index

Refresh index mapping for enabling keywords etc

### SSL Monitoring

Add all ports to monitoring
```bash
docker run --rm -ti --network=host drwetter/testssl.sh:3.1dev localhost:5000
```

## Elastic objects

Kibana objects to imports are located in `elastic-objects`

- Heartbeat from https://github.com/elastic/uptime-contrib/blob/master/dashboards/http_dashboard.json

### Heartbeat monitor

Check url availability using `elastic_heartbeat_urls: [""https://google.com"]`