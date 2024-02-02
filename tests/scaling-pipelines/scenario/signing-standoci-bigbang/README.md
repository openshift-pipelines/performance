# "signing-standoci-bigbang" scenario

This scenario is supposed to stress Chains controller, pushing to standalone container registry it installs.

It uses same workflow as "signing-bigbang" scenario.

This scenario runs on downstream only.

Files in the `certs/` directory were created with these commaneds:

    $ openssl req   -newkey rsa:4096 -nodes -sha256 -keyout certs/registry.key -addext "subjectAltName = DNS:registry.utils.svc.cluster.local" -subj "/C=CZ/ST=Czech Republic/L=Brno/O=Red Hat Test/OU=OpenShift Pipelines/CN=registry.utils.svc.cluster.local/emailAddress=jhutar@redhat.com"  -x509 -days 3650 -out certs/registry.crt
    $ podman run --rm --entrypoint htpasswd quay.io/fedora/httpd-24-micro -Bbn test test > certs/htpasswd
