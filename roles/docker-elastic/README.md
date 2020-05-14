# youtous/docker-elastic

Provide an elastic stack using docker.
You can use it as a complete stack or as a forwarder (`elastic_use_as_forwarder: true`).

Remember to set a `elastic_cluster_name` for identifying the cluster data.

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

### 

### Heartbeat monitor

Check url availability using `elastic_heartbeat_urls: [""https://google.com"]`