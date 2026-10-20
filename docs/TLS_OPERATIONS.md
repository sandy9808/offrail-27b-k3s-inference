# Self-signed TLS operations

## Live endpoints

| Service | URL |
|---|---|
| Odysseus | https://odysseus.offrail.test |
| Offrail OpenAI-compatible API | https://offrail-api.offrail.test |
| Legacy internal model URL | http://127.0.0.1:8899 |

The self-signed certificate is generated only on the target at
/etc/offrail/tls/offrail.crt. Its private key is
/etc/offrail/tls/offrail.key, owned by root and mode 0600. Neither file is
included in Git.

## Client name resolution and trust

The target hosts file contains these mappings:

    192.168.1.148 odysseus.offrail.test
    192.168.1.148 offrail-api.offrail.test

Every client device that needs browser access must add the same entries to its
own hosts file. On macOS, edit /etc/hosts with sudo; on Windows, edit the hosts
file as Administrator. Then import the target certificate into the client trust
store if the browser should stop displaying its self-signed certificate warning.

For a temporary command-line test without importing the certificate:

    curl -k https://odysseus.offrail.test/api/health
    curl -k https://offrail-api.offrail.test/health

## Automation

Run the following from the project root to make the Nginx, hosts-file, and
certificate state converge:

    ansible-playbook playbooks/configure_https.yml \
      --ask-pass --ask-become-pass

The certificate uses DNS SANs for both names and an IP SAN for 192.168.1.148.
It has a validity period configured by tls_valid_days in group_vars/all.yml.
Delete the certificate and key on the target before running the playbook if a
new certificate is required.

## K3s interaction

Nginx owns host ports 80 and 443. The model pod uses host port 8899 instead, so
the K3s migration does not conflict with TLS. Do not enable a K3s Traefik
Ingress on ports 80/443 unless this Nginx proxy is removed or the ports are
redesigned.

