# youtous/ansible-ufw-smart-rules
[![pipeline status](https://gitlab.com/youtous/ansible-ufw-smart-rules/badges/main/pipeline.svg)](https://gitlab.com/youtous/ansible-ufw-smart-rules/-/commits/master)
[![pre-commit](https://img.shields.io/badge/pre--commit-enabled-brightgreen?logo=pre-commit&logoColor=white)](https://github.com/pre-commit/pre-commit)
[![GitHub Repo stars](https://img.shields.io/github/stars/youtous/ansible-ufw-smart-rules?label=✨%20youtous%2Fansible-ufw-smart-rules&style=social)](https://github.com/youtous/ansible-ufw-smart-rules/)
[![Gitlab Repo](https://img.shields.io/badge/gitlab.com%2Fyoutous%2Fansible--ufw--smart--rules?label=✨%20youtous%2Fansible-ufw-smart-rules&style=social&logo=gitlab)](https://gitlab.com/youtous/ansible-ufw-smart-rules/)
[![Licence](https://img.shields.io/github/license/youtous/ansible-ufw-smart-rules)](https://github.com/youtous/ansible-ufw-smart-rules/blob/master/LICENSE)

Manage **ufw** firewall using a single target state and reconcile the existing one.

It works by:
  - scanning the **current state** of the rules for a given desired set of rules,
  - remove the existing rules not matching the **target state**,
  - add the rules not already present in the **current state**.

This way of managing the firewall using UFW through a **target state** reduces the complexity of the firewall management by implementing a single desired state without dealing with the existing rules.

This role supports either looping on:
  - **Incoming** connections filter (`from_ips`)
    set `ufw_rules_criteria: from_ips` then list the allowed sources using `ufw_rule_from_ips: []`
  - **Outgoing** connections filter (`to_ips`)
    set `ufw_rules_criteria: to_ips` then list the allowed destinations using `ufw_rule_to_ips: []`

You can combine, incoming and outgoing filters by including this role twice.

### Requirements

- ansible-core 2.11+
- [community.general](https://galaxy.ansible.com/community/general) collection
- [jc](https://github.com/kellyjonbrazil/jc) on YOUR system: `pip3 install jc`
- [jmespath](https://github.com/jmespath/jmespath.py) on YOUR system: `pip3 install jmespath`
- [netaddr](https://pypi.org/project/netaddr/) on YOUR system: `pip3 install netaddr`
- Packages that must be present on the target system:
  - ufw

### Usage

Installation from [ansible galaxy](https://galaxy.ansible.com/youtous/ufw_smart_rules): `ansible-galaxy install youtous.ufw_smart_rules`

- Incoming filter:
```yaml
- name: Implement an incoming filter on port 80, ensure only allowed ips can reach the service
  ansible.builtin.include_role:
    name: youtous.ufw_smart_rules
  vars:
    ufw_rule_parameters:
      to_port: "80"
      rule: "allow"
    ufw_rules_criteria: from_ips
    ufw_rule_from_ips: [127.0.0.2, 127.0.0.3] # ufw module implementation of from_ip
```

- Outgoing filter:
```yaml
- name: Implement an outgoing filter on port 80, ensure only allowed ips can be reached
  ansible.builtin.include_role:
    name: youtous.ufw_smart_rules
  vars:
    ufw_rule_parameters:
      to_port: "80"
      rule: "allow"
      direction: out
    ufw_rules_criteria: to_ips
    ufw_rule_to_ips: [10.1.3.63, 10.2.35.21] # ufw module implementation of to_ip
```

**Notice :** if you are implementing a rule with a comment, this role does not handle replacing the others rules matching the same ip with the new commented rule. Test case "test-with-existing-rule-in-comment-no-delete" describes the scenario.

### License

MIT
