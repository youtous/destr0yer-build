# youtous/docker_elastic

Provide an elastic stack using docker.
You can use it as a complete stack or as a forwarder (`elastic_use_as_forwarder: true`).

Remember to set a `elastic_cluster_name` for identifying the cluster data.

## Certificates x509

The elastic cluster is managed using x509 certificates.
A common scheme is to use :
- a root certificate for mananing the cluster (use `generate-x509.rb`) (e.g. `elastic.domain.tld`)
- a common certificate for all **beats** agents on the **same node**. (e.g. `node.elastic.domain.tld`)
- dedicated certificate per docker service such as **logstash** or eventually logspout. (e.g. `logstash.elastic.domain.tld`)

**IMPORTANT :** the FQDN of certificates must match with the `hostname` (krug.svur.org for instance).

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

### Import kibana dashboard

Use elastic-importer from the docker-compose.
Simply mount the volume and the `kibana_index.ndjson` in.

-or-

You can use the import/export function in kibana.

Important change due to OpenSearch migration:
Beats dashboards imports must be performed manually;
https://www.electricbrain.com.au/pages/analytics/opensearch-vs-elasticsearch.php



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
subject: '[ElastAlert] {{ctx.monitor.name}} >>> {{ctx.trigger.name}} <<<'
---
Monitor {{ctx.monitor.name}} just entered alert status. Please investigate the issue.
- Trigger: {{ctx.trigger.name}}
- Severity: {{ctx.trigger.severity}}
- Period start: {{ctx.periodStart}}
- Period end: {{ctx.periodEnd}}
```

### IML (deprecated)

1. Add the policies in kibana exported)
2. _(eventually update the template)_ first `GET` the template, add the policy id using `PUT`

```

PUT _template/metricbeat-
{
    "order" : 1,
    "index_patterns" : [
      "metricbeat-*"
    ],
    "settings" : {
      "opendistro.index_state_management.policy_id": "metricbeat_policy_workflow",
      "opendistro.index_state_management.rollover_alias": "metricbeat_rollover",
```

Update existing **indices** using :
```http request
PUT metricbeat*/_settings
{
        "opendistro.index_state_management.policy_id": "metricbeat_policy_workflow",
        "opendistro.index_state_management.rollover_alias": "metricbeat_rollover"
}
```

See https://discuss.opendistrocommunity.dev/t/can-you-automatically-manage-indices/2034

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
