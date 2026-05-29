# ADR-019: Home Assistant — IoT hub for home clusters

**Status**: Done

**Context**: For clusters deployed in a home environment, Home Assistant provides
IoT device management, automation, and monitoring. It integrates with hundreds of
smart home protocols (Zigbee, Z-Wave, Matter, MQTT, etc.).

**Decision**: Deploy Home Assistant in K3S as an optional service for home-based
clusters. It runs on bare-metal only (privacy critical — home sensor data, cameras,
door locks must never leave the local network).

**Architecture**:
```
IoT devices (Zigbee, WiFi, MQTT)
         │
         ▼
   Home Assistant (K3S pod on bare-metal)
         │
         ├── Local dashboard (via Headscale mesh, never exposed publicly)
         ├── Automations (lights, heating, alerts)
         ├── Prometheus metrics (via HA integration)
         └── Grafana dashboards (via HA → Prometheus)
```

**Key design decisions**:
- **Never exposed via the relay node** — home data stays strictly local.
  Access only via Headscale mesh (Tailscale client on phone/laptop).
- **Persistent storage** via OpenEBS hostpath (sensor history, config, DB).
- **Auth** via Authelia SSO (forward auth) for web UI, or HA's built-in auth
  as fallback (HA has its own user system that works well for home use).
- **hostNetwork: true** may be needed for mDNS/SSDP device discovery.
  Evaluate Cilium host networking mode vs dedicated network namespace.
- **USB devices** (Zigbee sticks, etc.): mount via `nodeSelector` + device plugin
  to pin the pod to the node with the USB hardware.

**Implementation**:
1. Create role `k3s_homeassistant` deploying HA via Helm (official chart)
2. Configure OpenEBS PVC for HA data
3. Configure Cilium NetworkPolicy: allow LAN access for device discovery,
   deny internet egress (HA should not phone home)
4. Optional: deploy Mosquitto MQTT broker as a sidecar or separate pod
5. Optional: deploy Zigbee2MQTT if using Zigbee devices

**Playbook**: Add to a new `07-home.yml` (optional, only for home clusters).

**Not deployed on non-home clusters** — this role is opt-in based on inventory
group membership (e.g., `home_clusters` group).
